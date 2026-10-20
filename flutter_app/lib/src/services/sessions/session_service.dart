import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../models/account.dart';
import '../../models/chat_session.dart';
import '../../util/app_paths.dart';
import '../desktop/desktop_client.dart';
import 'trae_chat_db.dart';
import 'vscdb_reader.dart';

/// 一次本机会话扫描的结果。
class SessionScanResult {
  const SessionScanResult({
    required this.sessions,
    this.workbuddyWorkspaces = 0,
    this.workbuddyMetaRows = 0,
    this.workbuddyCliSessions = 0,
    this.traeRoots = const [],
    this.traeDatabases = 0,
  });

  final List<ChatSession> sessions;

  /// 扫到的工作区索引数量（桌面端）。
  final int workbuddyWorkspaces;

  /// 桌面端元数据（`codebuddy-sessions.vscdb`）条数。
  final int workbuddyMetaRows;

  /// CLI 会话数量。
  final int workbuddyCliSessions;

  /// 命中的 Trae 配置目录。
  final List<String> traeRoots;

  /// 读取的 Trae 状态库数量。
  final int traeDatabases;

  static const SessionScanResult empty = SessionScanResult(sessions: []);

  int countOf(SessionSource source) =>
      sessions.where((s) => s.source == source).length;

  int get workbuddyCount =>
      sessions.where((s) => s.provider == PlatformKind.workbuddy).length;

  int get traeCount =>
      sessions.where((s) => s.provider == PlatformKind.trae).length;
}

/// 本地 AI 会话的读取与跨账号复制。
///
/// 会话分散在客户端的多处本地文件里，这里按会话 id 合并成一张表：
///
/// WorkBuddy / CodeBuddy
/// 1. 桌面端：`<Data>/<账号>/CodeBuddyIDE/<账号>/history/<工作区>/index.json`
/// 2. 桌面端元数据：`~/.config/CodeBuddy CN/codebuddy-sessions.vscdb` 的 `session:<id>`
/// 3. CLI：`~/.codebuddy/projects/<项目>/<会话>.jsonl`
///
/// Trae
/// 1. `User/globalStorage/state.vscdb` 与各工作区 `state.vscdb` 里的会话键
/// 2. `ModularData/ai-agent/snapshot/<id>`、`sandbox/<id>.json`
/// 3. `logs/<日期>/<窗口>/renderer.log` 里的 `session_updated` 事件（标题）
///
/// Trae 的正文在 SQLCipher 加密库 `ModularData/ai-agent/database.db` 里，
/// 由 [TraeChatDb] 抓 key 后按页解密成临时明文库再读出（只读，不改动原库）。
class SessionService {
  const SessionService({this.traeReader});

  /// 仅测试使用：替换 Trae 正文读取，避免依赖本机装没装 Trae。
  final Future<List<ChatMessage>> Function(ChatSession session)? traeReader;

  static const List<String> _sideDirs = ['file-tree', 'plan-task'];
  static const String _untitled = '未命名会话';
  static const List<String> _traeVariants = [
    'Trae CN',
    'TRAE SOLO CN',
    'Trae',
    'TRAE SOLO',
  ];

  static final RegExp _traeId = RegExp(r'^[0-9a-f]{16,}$');
  static final RegExp _traeCompletion = RegExp(
    r'^ai-chat[.]chatQueryCompletion[.]v([0-9])[.]([0-9a-f]{16,})$',
  );
  static final RegExp _traeDraft = RegExp(
    r'^([0-9]+):draft:session:([0-9a-f]{16,}):code$',
  );
  static final RegExp _workspaceLog = RegExp(r'^(.*)__([0-9a-f]{32})[.]log$');

  static String get _home => AppPaths.home;
  static String get _appData => Platform.environment['APPDATA'] ?? '';
  static String get _localAppData => Platform.environment['LOCALAPPDATA'] ?? '';

  /// 该平台是否支持读取本地会话。移动端没有这些客户端目录，直接隐藏入口。
  static bool supports(PlatformKind provider) => DesktopClient.supported;

  // ---------------------------------------------------------------------------
  // 目录探测
  // ---------------------------------------------------------------------------

  static List<String> workbuddyDataRoots() {
    final candidates = <String>[];
    if (Platform.isWindows) {
      for (final base in [_appData, _localAppData]) {
        if (base.isEmpty) continue;
        candidates.add(p.join(base, 'CodeBuddyExtension', 'Data'));
      }
    } else if (Platform.isMacOS) {
      candidates.add(
        p.join(
          _home,
          'Library',
          'Application Support',
          'CodeBuddyExtension',
          'Data',
        ),
      );
    } else {
      candidates
        ..add(p.join(_home, '.local', 'share', 'CodeBuddyExtension', 'Data'))
        ..add(p.join(_home, '.config', 'CodeBuddyExtension', 'Data'));
    }
    // 登录态文件一定能定位到真实的 Data 目录，作为兜底。
    for (final auth in DesktopClient.workbuddyAuthFiles()) {
      candidates.add(p.dirname(p.dirname(p.dirname(auth))));
    }
    return _existingDirs(candidates);
  }

  static String? workbuddyDataRoot() {
    final roots = workbuddyDataRoots();
    return roots.isEmpty ? null : roots.first;
  }

  static String accountRoot(String dataRoot, String uid) =>
      p.join(dataRoot, uid, 'CodeBuddyIDE', uid);

  static List<String> workbuddySessionDatabases() {
    final candidates = <String>[];
    for (final name in const ['CodeBuddy CN', 'CodeBuddy']) {
      if (Platform.isWindows) {
        for (final base in [_appData, _localAppData]) {
          if (base.isEmpty) continue;
          candidates.add(p.join(base, name, 'codebuddy-sessions.vscdb'));
        }
      } else if (Platform.isMacOS) {
        candidates.add(
          p.join(
            _home,
            'Library',
            'Application Support',
            name,
            'codebuddy-sessions.vscdb',
          ),
        );
      } else {
        candidates.add(
          p.join(_home, '.config', name, 'codebuddy-sessions.vscdb'),
        );
      }
    }
    return _existingFiles(candidates);
  }

  static String? codebuddyCliRoot() {
    final dir = p.join(_home, '.codebuddy', 'projects');
    return Directory(dir).existsSync() ? dir : null;
  }

  static List<String> traeConfigRoots() {
    final bases = <String>[];
    if (Platform.isWindows) {
      if (_appData.isNotEmpty) bases.add(_appData);
      if (_localAppData.isNotEmpty) bases.add(_localAppData);
    } else if (Platform.isMacOS) {
      bases.add(p.join(_home, 'Library', 'Application Support'));
    } else {
      bases.add(p.join(_home, '.config'));
    }
    final candidates = <String>[];
    for (final base in bases) {
      for (final name in _traeVariants) {
        candidates.add(p.join(base, name));
      }
    }
    return _existingDirs(candidates);
  }

  static String? traeConfigRoot() {
    final roots = traeConfigRoots();
    return roots.isEmpty ? null : roots.first;
  }

  // ---------------------------------------------------------------------------
  // 扫描入口
  // ---------------------------------------------------------------------------

  /// 扫描本机所有会话。参数用于测试注入临时目录；不传则自动探测。
  Future<SessionScanResult> scan({
    List<String>? workbuddyRoots,
    List<String>? codebuddyVscdbs,
    String? cliRoot,
    List<String>? traeRoots,
  }) async {
    if (!DesktopClient.supported) return SessionScanResult.empty;

    final roots = workbuddyRoots ?? workbuddyDataRoots();
    final vscdbs = codebuddyVscdbs ?? workbuddySessionDatabases();
    final cli = cliRoot ?? codebuddyCliRoot();
    final trae = traeRoots ?? traeConfigRoots();

    final byId = <String, ChatSession>{};
    var workspaces = 0;
    for (final root in roots) {
      final result = await _scanDesktopRoot(root);
      workspaces += result.workspaces;
      for (final session in result.sessions) {
        // 同一个会话可能被多个 Data 目录（例如 default 与真实账号）收录。
        byId.putIfAbsent(session.sessionId, () => session);
      }
    }

    var metaRows = 0;
    for (final db in vscdbs) {
      metaRows += await _applyDesktopMeta(db, byId);
    }

    final cliCount = cli == null ? 0 : await _scanCli(cli, byId);

    final traeScan = await _scanTrae(trae);

    final sessions = [...byId.values, ...traeScan.sessions]
      ..sort((a, b) {
        final left = a.updatedAt?.millisecondsSinceEpoch ?? 0;
        final right = b.updatedAt?.millisecondsSinceEpoch ?? 0;
        return right.compareTo(left);
      });

    return SessionScanResult(
      sessions: sessions,
      workbuddyWorkspaces: workspaces,
      workbuddyMetaRows: metaRows,
      workbuddyCliSessions: cliCount,
      traeRoots: traeScan.roots,
      traeDatabases: traeScan.databases,
    );
  }

  /// 只读取某个账号的桌面端会话（复制流程与单元测试使用）。
  Future<List<ChatSession>> listSessions(
    PlatformKind provider,
    String uid, {
    String? dataRoot,
  }) async {
    if (!DesktopClient.supported || provider != PlatformKind.workbuddy) {
      return const [];
    }
    final root = dataRoot ?? workbuddyDataRoot();
    if (root == null) return const [];
    final result = await _scanDesktopRoot(root, onlyUid: uid);
    return result.sessions;
  }

  // ---------------------------------------------------------------------------
  // WorkBuddy：桌面端目录
  // ---------------------------------------------------------------------------

  Future<_DesktopScan> _scanDesktopRoot(
    String dataRoot, {
    String? onlyUid,
  }) async {
    final labels = await _workspaceLabels(dataRoot);
    final sessions = <ChatSession>[];
    var workspaces = 0;

    for (final account in await _directoryNames(dataRoot)) {
      if (onlyUid != null && account != onlyUid) continue;
      final ideDir = Directory(p.join(dataRoot, account, 'CodeBuddyIDE'));
      if (!await ideDir.exists()) continue;

      for (final profile in await _directoryNames(ideDir.path)) {
        final historyDir = Directory(p.join(ideDir.path, profile, 'history'));
        if (!await historyDir.exists()) continue;

        for (final workspaceId in await _directoryNames(historyDir.path)) {
          final indexFile = File(
            p.join(historyDir.path, workspaceId, 'index.json'),
          );
          if (!await indexFile.exists()) continue;
          final index = await _readJson(indexFile.path);
          final conversations = index['conversations'];
          if (conversations is! List) continue;
          workspaces++;

          final project =
              labels[workspaceId] ??
              _decodeProfile(profile, account) ??
              _shortId(workspaceId);

          for (final raw in conversations) {
            if (raw is! Map) continue;
            final id = raw['id']?.toString() ?? '';
            if (id.isEmpty) continue;
            final dir = Directory(p.join(historyDir.path, workspaceId, id));
            if (!await dir.exists()) continue;

            final sessionIndex = await _readJson(
              p.join(dir.path, 'index.json'),
            );
            final count = await _countMessages(dir, sessionIndex);
            final name = raw['name']?.toString().trim() ?? '';
            // 客户端自己登记的占位会话（无消息且无标题）不进列表，其余照实展示。
            if (count == 0 && (name.isEmpty || name == _untitled)) continue;

            final created = raw['createdAt']?.toString() ?? '';
            var last = raw['lastMessageAt']?.toString() ?? created;
            if (last.isEmpty) {
              last = await _modifiedIso(File(p.join(dir.path, 'index.json')));
            }
            var title = name;
            if (title.isEmpty) title = await _fallbackTitle(dir, sessionIndex);
            if (title.isEmpty) title = _timeTitle(last, id);

            sessions.add(
              ChatSession(
                provider: PlatformKind.workbuddy,
                accountUid: account,
                workspaceId: workspaceId,
                sessionId: id,
                title: title,
                createdAt: created,
                lastMessageAt: last,
                messageCount: count,
                source: SessionSource.workbuddyDesktop,
                project: project,
                path: dir.path,
              ),
            );
          }
        }
      }
    }

    return _DesktopScan(workspaces: workspaces, sessions: sessions);
  }

  /// 工作区 id -> 项目名：日志文件名形如 `<项目名>__<32位工作区id>.log`。
  Future<Map<String, String>> _workspaceLabels(String dataRoot) async {
    final labels = <String, String>{};
    final logs = Directory(p.join(p.dirname(dataRoot), 'Logs', 'CodeBuddyIDE'));
    if (!await logs.exists()) return labels;

    for (final day in await _directoryNames(logs.path)) {
      List<FileSystemEntity> entries;
      try {
        entries = await Directory(
          p.join(logs.path, day),
        ).list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        final match = _workspaceLog.firstMatch(p.basename(entry.path));
        if (match == null) continue;
        labels.putIfAbsent(match.group(2)!, () => match.group(1)!);
      }
    }
    return labels;
  }

  /// `default` 账号下的 profile 目录是项目路径的 base64。
  static String? _decodeProfile(String profile, String account) {
    if (profile == account) return null;
    try {
      final decoded = utf8.decode(
        base64.decode(base64.normalize(profile)),
        allowMalformed: true,
      );
      if (decoded.contains('/') &&
          decoded.codeUnits.every((unit) => unit >= 0x20)) {
        return decoded;
      }
    } catch (_) {
      // 不是 base64 就退回工作区 id
    }
    return null;
  }

  static String _shortId(String value) =>
      value.length <= 8 ? value : value.substring(0, 8);

  // ---------------------------------------------------------------------------
  // WorkBuddy：桌面端元数据（vscdb）
  // ---------------------------------------------------------------------------

  Future<int> _applyDesktopMeta(
    String dbPath,
    Map<String, ChatSession> byId,
  ) async {
    final rows = await VscdbReader.readItemTable(
      dbPath,
      where: 'key LIKE ?',
      whereArgs: const ['session:%'],
    );
    for (final row in rows) {
      final key = row['key']?.toString() ?? '';
      if (!key.startsWith('session:')) continue;
      final meta = _tryJson(row['value']?.toString() ?? '');
      if (meta == null) continue;

      final id =
          meta['conversationId']?.toString() ??
          key.substring('session:'.length);
      if (id.isEmpty) continue;

      final title = meta['title']?.toString().trim() ?? '';
      final cwd = meta['cwd']?.toString() ?? '';
      final status = meta['status']?.toString() ?? '';
      final created = _isoFrom(meta['createdAt']);
      final updated = _isoFrom(meta['updatedAt']);

      final existing = byId[id];
      if (existing == null) {
        byId[id] = ChatSession(
          provider: PlatformKind.workbuddy,
          accountUid: '',
          workspaceId: '',
          sessionId: id,
          title: title.isNotEmpty
              ? title
              : _timeTitle(updated ?? created ?? '', id),
          createdAt: created ?? '',
          lastMessageAt: updated ?? created ?? '',
          messageCount: 0,
          source: SessionSource.workbuddyDesktop,
          project: cwd,
          cwd: cwd,
          status: status,
        );
        continue;
      }

      byId[id] = existing.copyWith(
        title: title.isNotEmpty ? title : null,
        project: cwd.isNotEmpty ? cwd : null,
        cwd: cwd.isNotEmpty ? cwd : null,
        status: status.isNotEmpty ? status : null,
        createdAt: (created != null && created.isNotEmpty) ? created : null,
        lastMessageAt: _later(existing.lastMessageAt, updated),
      );
    }
    return rows.length;
  }

  // ---------------------------------------------------------------------------
  // WorkBuddy：CLI 会话
  // ---------------------------------------------------------------------------

  Future<int> _scanCli(String root, Map<String, ChatSession> byId) async {
    var count = 0;
    for (final project in await _directoryNames(root)) {
      List<FileSystemEntity> entries;
      try {
        entries = await Directory(
          p.join(root, project),
        ).list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File || !entry.path.endsWith('.jsonl')) continue;
        final id = p.basenameWithoutExtension(entry.path);
        if (id.isEmpty || byId.containsKey(id)) continue; // 桌面端已有同一会话时不重复
        final session = await _readCliFile(entry);
        if (session == null) continue;
        byId[id] = session;
        count++;
      }
    }
    return count;
  }

  Future<ChatSession?> _readCliFile(File file) async {
    String text;
    FileStat stat;
    try {
      text = await file.readAsString();
      stat = await file.stat();
    } catch (_) {
      return null;
    }

    var events = 0;
    var firstUser = '';
    var cwd = '';
    String? first;
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      events++;
      final event = _tryJson(line);
      if (event == null) continue;
      if (cwd.isEmpty) {
        final value = event['cwd']?.toString() ?? '';
        if (value.isNotEmpty) cwd = value;
      }
      first ??= _isoFrom(event['timestamp']);
      if (firstUser.isEmpty &&
          event['type'] == 'message' &&
          event['role'] == 'user') {
        final content = event['content'];
        if (content is List) {
          for (final part in content) {
            if (part is! Map) continue;
            final type = part['type']?.toString() ?? '';
            if (type != 'input_text' && type != 'text') continue;
            final value = part['text']?.toString().trim() ?? '';
            if (value.isEmpty || value.startsWith('/')) continue;
            firstUser = value;
            break;
          }
        }
      }
    }
    if (events == 0) return null;

    final id = p.basenameWithoutExtension(file.path);
    final last = stat.modified.toUtc().toIso8601String();
    final title = _cleanTitle(firstUser);
    return ChatSession(
      provider: PlatformKind.workbuddy,
      accountUid: '',
      workspaceId: '',
      sessionId: id,
      title: title.isEmpty ? _timeTitle(last, id) : _clip(title, 80),
      createdAt: first ?? stat.modified.toUtc().toIso8601String(),
      lastMessageAt: last,
      messageCount: events,
      source: SessionSource.workbuddyCli,
      project: cwd.isNotEmpty ? cwd : p.basename(p.dirname(file.path)),
      cwd: cwd,
      path: file.path,
    );
  }

  // ---------------------------------------------------------------------------
  // Trae：状态库 + 快照/沙箱 + 日志
  // ---------------------------------------------------------------------------

  Future<_TraeScan> _scanTrae(List<String> roots) async {
    final slots = <String, _TraeSlot>{};
    var databases = 0;

    for (final root in roots) {
      for (final dbPath in await _traeStateDatabases(root)) {
        databases++;
        await _readTraeStateDb(dbPath, slots);
      }
      await _scanTraeAgentDir(root, slots);
      await _scanTraeLogs(root, slots);
    }

    return _TraeScan(
      sessions: slots.values.map((slot) => slot.toSession()).toList(),
      roots: roots,
      databases: databases,
    );
  }

  Future<List<String>> _traeStateDatabases(String root) async {
    final candidates = <String>[
      p.join(root, 'User', 'globalStorage', 'state.vscdb'),
    ];
    for (final workspace in await _directoryNames(
      p.join(root, 'User', 'workspaceStorage'),
    )) {
      candidates.add(
        p.join(root, 'User', 'workspaceStorage', workspace, 'state.vscdb'),
      );
    }
    return _existingFiles(candidates);
  }

  Future<void> _readTraeStateDb(
    String dbPath,
    Map<String, _TraeSlot> slots,
  ) async {
    final rows = await VscdbReader.readItemTable(
      dbPath,
      where: 'key LIKE ? OR key LIKE ? OR key = ?',
      whereArgs: const [
        'ai-chat.chatQueryCompletion.%',
        '%:draft:session:%',
        'icube_session_agent_map',
      ],
    );

    for (final row in rows) {
      final key = row['key']?.toString() ?? '';
      final value = row['value']?.toString() ?? '';

      var match = _traeCompletion.firstMatch(key);
      if (match != null) {
        final id = match.group(2)!;
        final slot = slots.putIfAbsent(id, () => _TraeSlot(id));
        slot.from.add('vscdb');
        final json = _tryJson(value);
        if (json == null) continue;

        final savedAt = _intOf(json['savedAt']);
        if (savedAt != null && savedAt > slot.at) slot.at = savedAt;
        final length = _intOf(json['messagesLength']);
        if (length != null && slot.messages == null) slot.messages = length;

        final response = json['response'];
        final top = response is Map ? response : const {};
        final topModel = top['modelName']?.toString() ?? '';
        if (topModel.isNotEmpty && slot.model.isEmpty) slot.model = topModel;
        final resp = top['resp'] is Map ? top['resp'] as Map : top;
        final respModel = resp['modelName']?.toString() ?? '';
        if (respModel.isNotEmpty && slot.model.isEmpty) slot.model = respModel;

        final list = resp['result'];
        if (list is List && list.isNotEmpty) {
          final last = list.last;
          if (last is Map) {
            final text = last['text']?.toString() ?? '';
            if (text.isNotEmpty) slot.preview = _clip(text, 60);
          }
        }
        continue;
      }

      match = _traeDraft.firstMatch(key);
      if (match != null) {
        final id = match.group(2)!;
        final slot = slots.putIfAbsent(id, () => _TraeSlot(id));
        slot.from.add('vscdb');
        if (slot.userId.isEmpty) slot.userId = match.group(1)!;
        final json = _tryJson(value);
        final updated = _intOf(json?['updatedAt']);
        if (updated != null && updated > slot.at) slot.at = updated;
        continue;
      }

      if (key == 'icube_session_agent_map') {
        final json = _tryJson(value);
        if (json == null) continue;
        for (final entry in json.entries) {
          final id = entry.key.toString();
          if (!_traeId.hasMatch(id)) continue;
          final slot = slots.putIfAbsent(id, () => _TraeSlot(id));
          slot.from.add('vscdb');
          if (slot.agent.isEmpty) slot.agent = entry.value?.toString() ?? '';
        }
      }
    }
  }

  Future<void> _scanTraeAgentDir(
    String root,
    Map<String, _TraeSlot> slots,
  ) async {
    final base = p.join(root, 'ModularData', 'ai-agent');

    final snapshot = Directory(p.join(base, 'snapshot'));
    if (await snapshot.exists()) {
      for (final id in await _directoryNames(snapshot.path)) {
        if (!_traeId.hasMatch(id)) continue;
        final slot = slots.putIfAbsent(id, () => _TraeSlot(id));
        slot.from.add('snapshot');
        try {
          final time = (await Directory(
            p.join(snapshot.path, id),
          ).stat()).modified;
          final ms = time.millisecondsSinceEpoch;
          if (ms > slot.at) slot.at = ms;
        } catch (_) {
          // 目录刚被清理时忽略
        }
      }
    }

    final sandbox = Directory(p.join(base, 'sandbox'));
    if (await sandbox.exists()) {
      List<FileSystemEntity> entries;
      try {
        entries = await sandbox.list(followLinks: false).toList();
      } catch (_) {
        entries = const [];
      }
      for (final entry in entries) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final id = p.basenameWithoutExtension(entry.path);
        if (!_traeId.hasMatch(id)) continue;
        slots.putIfAbsent(id, () => _TraeSlot(id)).from.add('sandbox');
      }
    }
  }

  Future<void> _scanTraeLogs(String root, Map<String, _TraeSlot> slots) async {
    final logs = Directory(p.join(root, 'logs'));
    if (!await logs.exists()) return;
    const marker = 'session_updated ';

    for (final day in await _directoryNames(logs.path)) {
      for (final window in await _directoryNames(p.join(logs.path, day))) {
        final file = File(p.join(logs.path, day, window, 'renderer.log'));
        if (!await file.exists()) continue;
        try {
          final stat = await file.stat();
          if (stat.size > 8 * 1024 * 1024) continue;
          final text = await file.readAsString();
          var cursor = 0;
          while (true) {
            final index = text.indexOf(marker, cursor);
            if (index < 0) break;
            final start = index + marker.length;
            final lineEnd = text.indexOf('\n', start);
            var payload = text
                .substring(start, lineEnd < 0 ? text.length : lineEnd)
                .trim();
            cursor = start + 1;
            if (!payload.startsWith('{')) continue;
            final close = payload.lastIndexOf('}');
            if (close < 0) continue;
            payload = payload.substring(0, close + 1);
            final json = _tryJson(payload);
            if (json == null) continue;
            final id = json['chat_session_id']?.toString() ?? '';
            if (!_traeId.hasMatch(id)) continue;
            final slot = slots.putIfAbsent(id, () => _TraeSlot(id));
            slot.from.add('log');
            final title = json['title']?.toString().trim() ?? '';
            if (title.isNotEmpty) slot.title = title;
            if (slot.userId.isEmpty) {
              slot.userId = json['user_id']?.toString() ?? '';
            }
            final updated = _intOf(json['updated_at']);
            if (updated != null && updated > slot.at) slot.at = updated;
          }
        } catch (_) {
          continue;
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 会话正文
  // ---------------------------------------------------------------------------

  Future<List<ChatMessage>> readMessages(
    ChatSession session, {
    String? dataRoot,
  }) async {
    switch (session.source) {
      case SessionSource.workbuddyCli:
        return _readCliMessages(session);
      case SessionSource.trae:
        return _readTraeMessages(session);
      case SessionSource.workbuddyDesktop:
        break;
    }
    if (session.provider != PlatformKind.workbuddy) return const [];

    Directory dir;
    if (session.path.isNotEmpty) {
      dir = Directory(session.path);
    } else {
      dataRoot ??= workbuddyDataRoot();
      if (dataRoot == null) return const [];
      dir = Directory(
        p.join(
          accountRoot(dataRoot, session.accountUid),
          'history',
          session.workspaceId,
          session.sessionId,
        ),
      );
    }
    if (!await dir.exists()) return const [];

    final index = await _readJson(p.join(dir.path, 'index.json'));
    final ids = await _messageIds(dir, index);
    final result = <ChatMessage>[];
    for (final id in ids) {
      try {
        final file = File(p.join(dir.path, 'messages', '$id.json'));
        if (!await file.exists()) continue;
        final decoded = await _readJson(file.path);
        if (decoded.isEmpty) continue;
        final role = decoded['role']?.toString() ?? '';
        if (role == 'tool' || role == 'system') continue;
        final text = _extractText(decoded['message']).trim();
        if (text.isEmpty) continue;
        result.add(
          ChatMessage(
            role: role,
            text: text,
            createdAt: DateTime.tryParse(
              decoded['createdAt']?.toString() ?? '',
            ),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  /// Trae 的正文要从加密库里解密后读；密钥拿不到时降级成只有 preview。
  Future<List<ChatMessage>> _readTraeMessages(ChatSession session) async {
    if (traeReader != null) return traeReader!(session);
    if (session.sessionId.isEmpty || !DesktopLike.supported) return const [];
    try {
      final db = await TraeChatDb.open();
      return await db.messages(session.sessionId);
    } catch (_) {
      // 客户端未运行 / 拿不到密钥 / 快照撕裂：界面上仍有 preview 兜底。
      return const [];
    }
  }

  Future<List<ChatMessage>> _readCliMessages(ChatSession session) async {
    if (session.path.isEmpty) return const [];
    String text;
    try {
      text = await File(session.path).readAsString();
    } catch (_) {
      return const [];
    }

    final result = <ChatMessage>[];
    for (final line in const LineSplitter().convert(text)) {
      final event = _tryJson(line);
      if (event == null || event['type'] != 'message') continue;
      final role = event['role']?.toString() ?? '';
      if (role != 'user' && role != 'assistant') continue;

      final parts = <String>[];
      final content = event['content'];
      if (content is List) {
        for (final part in content) {
          if (part is! Map) continue;
          final type = part['type']?.toString() ?? '';
          if (type != 'input_text' && type != 'output_text' && type != 'text') {
            continue;
          }
          final value = part['text']?.toString() ?? '';
          if (value.trim().isNotEmpty) parts.add(value);
        }
      } else if (content is String && content.trim().isNotEmpty) {
        parts.add(content);
      }
      if (parts.isEmpty) continue;

      result.add(
        ChatMessage(
          role: role,
          text: parts.join('\n'),
          createdAt: DateTime.tryParse(_isoFrom(event['timestamp']) ?? ''),
        ),
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 复制
  // ---------------------------------------------------------------------------

  /// 把选中的 WorkBuddy 会话搬到目标账号；返回成功条数。
  ///
  /// 桌面端会话整目录复制（[ChatSession.copyable]），CLI 会话先解析 jsonl
  /// 再按桌面端的目录结构写进目标账号。
  Future<int> copySessions({
    required List<ChatSession> sessions,
    required String targetUid,
    String? dataRoot,
  }) async {
    if (sessions.isEmpty) return 0;
    if (sessions.any((item) => !item.accountMigratable)) {
      throw StateError('只有 WorkBuddy 会话可以迁移到其他账号');
    }

    // 桌面端会话必须来自同一个账号；CLI 会话没有账号归属，不参与这条校验。
    final sourceUids = sessions
        .where((item) => item.accountUid.isNotEmpty)
        .map((item) => item.accountUid)
        .toSet();
    if (sourceUids.length > 1) {
      throw StateError('一次只能同步同一个账号的会话');
    }
    final sourceUid = sourceUids.isEmpty ? '' : sourceUids.first;
    if (sourceUid == targetUid) throw StateError('目标账号与来源账号相同');

    dataRoot ??= workbuddyDataRoot();
    if (dataRoot == null) throw StateError('未找到 WorkBuddy 数据目录');
    final sourceRoot = accountRoot(dataRoot, sourceUid);
    final targetRoot = accountRoot(dataRoot, targetUid);
    await Directory(targetRoot).create(recursive: true);
    final labels = await _workspaceLabels(dataRoot);

    var copied = 0;
    for (final session in sessions) {
      if (session.source == SessionSource.workbuddyCli) {
        if (await _importCliSession(
          targetRoot: targetRoot,
          session: session,
          labels: labels,
        )) {
          copied++;
        }
        continue;
      }

      final sourceDir = Directory(
        p.join(sourceRoot, 'history', session.workspaceId, session.sessionId),
      );
      if (!await sourceDir.exists()) continue;

      final newId = _randomHex(32);
      final targetDir = Directory(
        p.join(targetRoot, 'history', session.workspaceId, newId),
      );
      await _copyDirectory(sourceDir, targetDir);

      for (final kind in _sideDirs) {
        final sideSource = Directory(
          p.join(sourceRoot, kind, session.workspaceId, session.sessionId),
        );
        if (await sideSource.exists()) {
          await _copyDirectory(
            sideSource,
            Directory(p.join(targetRoot, kind, session.workspaceId, newId)),
          );
        }
      }

      await _registerSession(
        targetRoot: targetRoot,
        workspaceId: session.workspaceId,
        newId: newId,
        session: session,
      );
      copied++;
    }
    return copied;
  }

  Future<void> _registerSession({
    required String targetRoot,
    required String workspaceId,
    required String newId,
    required ChatSession session,
  }) async {
    final folder = Directory(p.join(targetRoot, 'history', workspaceId));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, 'index.json'));

    Map<String, dynamic> index = <String, dynamic>{
      'conversations': <dynamic>[],
      'current': null,
    };
    try {
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) index = decoded.cast<String, dynamic>();
      }
    } catch (_) {
      // 索引损坏时重建
    }

    final conversations = index['conversations'] is List
        ? List<dynamic>.from(index['conversations'] as List)
        : <dynamic>[];
    final now = DateTime.now().toUtc().toIso8601String();
    conversations.insert(0, {
      'id': newId,
      'type': 'chat',
      'name': session.title,
      'createdAt': session.createdAt.isEmpty ? now : session.createdAt,
      'lastMessageAt': session.lastMessageAt.isEmpty
          ? now
          : session.lastMessageAt,
    });
    index['conversations'] = conversations;
    if (index['current'] == null) index['current'] = newId;

    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(index));
  }

  /// 把一个 CLI 会话（jsonl）写成目标账号的桌面端会话目录。
  Future<bool> _importCliSession({
    required String targetRoot,
    required ChatSession session,
    required Map<String, String> labels,
  }) async {
    final messages = await _readCliMessages(session);
    if (messages.isEmpty) return false;

    final project = session.cwd.isNotEmpty ? session.cwd : session.project;
    final workspaceId =
        _workspaceForProject(labels, project) ?? _randomHex(32);
    final newId = _randomHex(32);
    final dir = p.join(targetRoot, 'history', workspaceId, newId);
    await Directory(p.join(dir, 'messages')).create(recursive: true);

    final now = DateTime.now().toUtc();
    final entries = <Map<String, Object?>>[];
    for (final message in messages) {
      final messageId = _randomHex(32);
      final createdAt = (message.createdAt ?? now).toUtc().toIso8601String();
      await File(p.join(dir, 'messages', '$messageId.json')).writeAsString(
        jsonEncode({
          'role': message.role,
          'message': jsonEncode({
            'role': message.role,
            'content': message.text,
          }),
          'id': messageId,
          'extra': '{}',
          'createdAt': createdAt,
        }),
      );
      entries.add({
        'id': messageId,
        'type': 'text',
        'role': message.role,
        'isComplete': true,
      });
    }

    await File(p.join(dir, 'index.json')).writeAsString(
      jsonEncode({'messages': entries, 'requests': <dynamic>[]}),
    );

    await _registerSession(
      targetRoot: targetRoot,
      workspaceId: workspaceId,
      newId: newId,
      session: session,
    );
    return true;
  }

  /// 目标账号里已有同项目的工作区时复用它，避免每次迁移都新建一个工作区。
  static String? _workspaceForProject(
    Map<String, String> labels,
    String project,
  ) {
    if (project.isEmpty) return null;
    for (final entry in labels.entries) {
      if (entry.value == project) return entry.key;
    }
    return null;
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  static String _randomHex(int length) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  // ---------------------------------------------------------------------------
  // 小工具
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _readJson(String path) async {
    try {
      final decoded = jsonDecode(await File(path).readAsString());
      return decoded is Map ? decoded.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  static Map<String, dynamic>? _tryJson(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static int? _intOf(Object? raw) {
    if (raw is num) return raw.round();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static String? _isoFrom(Object? raw) {
    if (raw == null) return null;
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        raw.round(),
        isUtc: true,
      ).toIso8601String();
    }
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    final number = int.tryParse(text);
    if (number != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        number,
        isUtc: true,
      ).toIso8601String();
    }
    return DateTime.tryParse(text)?.toUtc().toIso8601String();
  }

  static String? _later(String current, String? candidate) {
    if (candidate == null || candidate.isEmpty) return null;
    final left = DateTime.tryParse(current);
    final right = DateTime.tryParse(candidate);
    if (right == null) return null;
    if (left == null) return candidate;
    return right.isAfter(left) ? candidate : null;
  }

  static Future<String> _modifiedIso(File file) async {
    try {
      return (await file.lastModified()).toUtc().toIso8601String();
    } catch (_) {
      return '';
    }
  }

  static Future<List<String>> _directoryNames(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    try {
      final entries = await dir.list(followLinks: false).toList();
      final names = <String>[];
      for (final entry in entries) {
        if (entry is Directory) names.add(p.basename(entry.path));
      }
      names.sort();
      return names;
    } catch (_) {
      return const [];
    }
  }

  static List<String> _existingDirs(List<String> candidates) {
    final result = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (candidate.isEmpty || !seen.add(candidate)) continue;
      if (Directory(candidate).existsSync()) result.add(candidate);
    }
    return result;
  }

  static List<String> _existingFiles(List<String> candidates) {
    final result = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      if (candidate.isEmpty || !seen.add(candidate)) continue;
      if (File(candidate).existsSync()) result.add(candidate);
    }
    return result;
  }

  Future<List<String>> _messageIds(
    Directory dir,
    Map<String, dynamic> index,
  ) async {
    final messages = index['messages'];
    if (messages is List) {
      final ids = <String>[];
      for (final item in messages) {
        if (item is Map && item['id'] != null) ids.add(item['id'].toString());
      }
      if (ids.isNotEmpty) return ids;
    }
    final folder = Directory(p.join(dir.path, 'messages'));
    if (!await folder.exists()) return const [];
    final files = await folder.list().where((item) => item is File).toList();
    final entries = <({String id, DateTime time})>[];
    for (final item in files) {
      final stat = await item.stat();
      entries.add((
        id: p.basenameWithoutExtension(item.path),
        time: stat.modified,
      ));
    }
    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries.map((entry) => entry.id).toList();
  }

  /// 只统计用户与 AI 的消息（工具消息不算），用于列表展示与过滤空会话。
  Future<int> _countMessages(Directory dir, Map<String, dynamic> index) async {
    final messages = index['messages'];
    if (messages is List && messages.isNotEmpty) {
      var count = 0;
      for (final item in messages) {
        if (item is! Map) continue;
        final role = item['role']?.toString();
        if (role == null || role == 'user' || role == 'assistant') count++;
      }
      return count;
    }
    return (await _messageIds(dir, index)).length;
  }

  Future<String> _fallbackTitle(
    Directory dir,
    Map<String, dynamic> index,
  ) async {
    try {
      final ids = await _messageIds(dir, index);
      for (final id in ids.take(12)) {
        final file = File(p.join(dir.path, 'messages', '$id.json'));
        if (!await file.exists()) continue;
        final decoded = await _readJson(file.path);
        if (decoded.isEmpty || decoded['role'] != 'user') continue;
        final text = _cleanTitle(_extractText(decoded['message']));
        if (text.isEmpty) continue;
        return _clip(text, 40);
      }
    } catch (_) {
      // 忽略：标题只是展示用
    }
    return '';
  }

  /// 实在没有可用的首条提问时，用时间兜底，避免出现「未命名会话」。
  static String _timeTitle(String iso, String sessionId) {
    final time = DateTime.tryParse(iso)?.toLocal();
    if (time == null) {
      return sessionId.length > 6 ? '会话 · ${sessionId.substring(0, 6)}' : '会话';
    }
    String two(int value) => value.toString().padLeft(2, '0');
    return '会话 · ${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
  }

  /// 会话没有标题时，用第一条用户消息生成：先去掉 `<user_info>` 这类环境信息块与标签，
  /// 再跳过 `OS Version: ...` 这种键值行，避免标题变成一段系统提示。
  static String _cleanTitle(String text) {
    if (text.trim().isEmpty) return '';
    var value = text.replaceAll(
      RegExp(r'<[a-zA-Z_][^>]{0,60}>[\s\S]*?</[a-zA-Z_][^>]{0,60}>'),
      ' ',
    );
    value = value.replaceAll(RegExp(r'<[^>]{0,60}>'), ' ');
    final lines = value
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    for (final line in lines) {
      final lower = line.toLowerCase();
      const prefixes = [
        'os version',
        'shell',
        'workspace',
        'current',
        'date',
        'time',
        'system',
      ];
      if (prefixes.any(
        (prefix) => lower.startsWith(prefix) && line.contains(':'),
      )) {
        continue;
      }
      return line;
    }
    return '';
  }

  /// 压平空白并截断，用于标题 / 预览。
  static String _clip(String text, int limit) {
    var value = text
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll('\t', ' ')
        .trim();
    while (value.contains('  ')) {
      value = value.replaceAll('  ', ' ');
    }
    return value.length <= limit ? value : '${value.substring(0, limit)}…';
  }

  /// 消息体既可能是纯文本，也可能是 JSON 字符串（含 content 分片）。
  static String _extractText(Object? message) {
    if (message == null) return '';
    if (message is String) {
      final trimmed = message.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          return _extractText(jsonDecode(trimmed));
        } catch (_) {
          return message;
        }
      }
      return message;
    }
    if (message is List) {
      return message
          .map(_extractText)
          .where((text) => text.isNotEmpty)
          .join('\n');
    }
    if (message is Map) {
      final content = message['content'];
      if (content != null) {
        final text = _extractText(content);
        if (text.isNotEmpty) return text;
      }
      if (message['text'] is String) return message['text'] as String;
      final result = message['result'];
      if (result is Map && result['stdout'] is String) {
        return result['stdout'] as String;
      }
    }
    return '';
  }
}

class _DesktopScan {
  const _DesktopScan({required this.workspaces, required this.sessions});

  final int workspaces;
  final List<ChatSession> sessions;
}

class _TraeScan {
  const _TraeScan({
    required this.sessions,
    required this.roots,
    required this.databases,
  });

  final List<ChatSession> sessions;
  final List<String> roots;
  final int databases;
}

/// Trae 会话在合并过程中的临时槽位。
class _TraeSlot {
  _TraeSlot(this.id);

  final String id;
  String agent = '';
  String userId = '';
  String model = '';
  String title = '';
  String preview = '';
  int? messages;
  int at = 0;
  final Set<String> from = {};

  ChatSession toSession() {
    final iso = at > 0
        ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true).toIso8601String()
        : '';
    final label = title.isNotEmpty
        ? title
        : (preview.isNotEmpty ? preview : SessionService._timeTitle(iso, id));
    return ChatSession(
      provider: PlatformKind.trae,
      accountUid: userId,
      workspaceId: '',
      sessionId: id,
      title: label,
      createdAt: iso,
      lastMessageAt: iso,
      messageCount: messages ?? 0,
      source: SessionSource.trae,
      agent: agent,
      model: model,
      preview: preview,
      origin: from.toList(),
    );
  }
}
