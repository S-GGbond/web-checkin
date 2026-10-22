import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/account.dart';
import '../../models/chat_session.dart';
import 'session_service.dart';
import 'trae_db_cipher.dart';
import 'trae_db_key.dart';
import '../desktop/desktop_client.dart';
import 'vscdb_reader.dart';

/// Trae 会话库读取失败（找不到库 / 拿不到密钥 / 解密校验不过）。
class TraeChatException implements Exception {
  const TraeChatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Trae 会话库里的一行索引：会话归属哪个账号、属于哪个项目。
class TraeSessionInfo {
  const TraeSessionInfo({
    required this.sessionId,
    required this.projectId,
    required this.userId,
    required this.title,
    required this.projectPath,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  final String sessionId;
  final String projectId;

  /// `project.user_id`：Trae 的会话归属就记在项目上。
  final String userId;
  final String title;
  final String projectPath;

  /// 秒级时间戳。
  final int createdAt;
  final int updatedAt;
  final int messages;
}

/// Trae 桌面端的 AI 会话正文库 ModularData/ai-agent/database.db。
///
/// 该库是 SQLCipher v4（AES-256-CBC，页大小 4096，每页 IV 在偏移 4016，
/// 前 16 字节是 salt 而不是 SQLite magic）。这里按页解密出一份明文的临时库，
/// 只读查询，不写、也不改动客户端原库。
///
/// key 由 [TraeDbKey] 从进程内存抓取；解密结果按源库 mtime/大小缓存，
/// 同一次运行里反复打开同一会话不会重复解密。
class TraeChatDb {
  TraeChatDb._(this._db, this._snapshot);

  final Database _db;
  final Directory _snapshot;

  static const int pageSize = TraeDbCipher.pageSize;

  static bool _ffiReady = false;
  static TraeChatDb? _cached;
  static String? _cachedStamp;

  /// 本机 Trae 配置目录下的加密库路径；没装客户端时返回 null。
  static String? defaultDatabasePath() {
    for (final root in SessionService.traeConfigRoots()) {
      final path = p.join(root, 'ModularData', 'ai-agent', 'database.db');
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// 打开（或复用）解密后的只读库。
  ///
  /// [dbPath] / [key] 用于测试与手动指定，正常调用不传。
  static Future<TraeChatDb> open({
    String? dbPath,
    String? key,
    void Function(String message)? log,
  }) async {
    final path = dbPath ?? defaultDatabasePath();
    if (path == null) {
      throw const TraeChatException('没有找到 Trae 客户端的会话数据库');
    }
    if (!DesktopLike.supported) {
      throw const TraeChatException('Trae 会话正文只在桌面端可读');
    }
    if (!await File(path).exists()) {
      throw TraeChatException('会话数据库不存在：$path');
    }

    final stamp = _stamp(path);
    if (_cached != null && _cachedStamp == stamp) return _cached!;
    await _cached?.close();
    _cached = null;

    final secret = await TraeDbKey.resolve(
      dbPath: path,
      manual: key,
      validate: (candidate) => TraeDbCipher.validateKey(candidate, path),
      log: log,
    );
    if (secret == null) {
      throw const TraeChatException(
        '未能取得 Trae 会话库密钥（客户端未运行；也可用 TRAE_DB_KEY 手动指定）',
      );
    }

    // 客户端运行时会持续写 WAL，快照偶尔会撕裂，重试三次。
    Object? failure;
    for (var attempt = 0; attempt < 3; attempt++) {
      final snapshot = await Directory.systemTemp.createTemp('checkin-hub-trae-');
      try {
        final plainPath = await decryptToPlain(secret, path, snapshot);
        final db = await openPlain(plainPath);
        final check = await db.rawQuery('PRAGMA quick_check');
        final verdict = check.isEmpty
            ? ''
            : check.first.values.first?.toString() ?? '';
        if (verdict == 'ok') {
          _cached = TraeChatDb._(db, snapshot);
          _cachedStamp = stamp;
          return _cached!;
        }
        await db.close();
        failure = TraeChatException('解密校验失败：$verdict');
      } catch (error) {
        failure = error;
      }
      try {
        await snapshot.delete(recursive: true);
      } catch (_) {
        // 忽略。
      }
      log?.call('第 ${attempt + 1} 次读取快照失败，重试');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw TraeChatException('读取 Trae 会话库失败：$failure');
  }

  /// 列出会话 → 项目、归属账号、标题、消息数与最近更新时间（不解正文）。
  ///
  /// 会话库里没有账号列，归属记在 chat_session.project_id → project.user_id 上；
  /// 状态库的 draft 键只覆盖最近打开过的少量会话，不能当账号来源。
  Future<List<TraeSessionInfo>> index() async {
    String sql(bool archived) {
      final filter = archived ? ' AND m.is_archived = 0' : '';
      return 'SELECT s.session_id AS sid, s.project_id AS pid, '
          's.session_title AS title, s.created_at AS cat, s.updated_at AS uat, '
          'p.user_id AS uid, p.absolute_path AS path, '
          '(SELECT count(*) FROM chat_message m WHERE m.session_id = s.session_id '
          'AND m.deleted_at = 0$filter) AS n '
          'FROM chat_session s LEFT JOIN project p ON p.project_id = s.project_id '
          'WHERE s.deleted_at = 0';
    }

    List<Map<String, Object?>> rows;
    try {
      rows = await _db.rawQuery(sql(true));
    } catch (_) {
      // 老版本库没有 is_archived 列。
      rows = await _db.rawQuery(sql(false));
    }
    return [
      for (final row in rows)
        if ((row['sid']?.toString() ?? '').isNotEmpty)
          TraeSessionInfo(
            sessionId: row['sid']!.toString(),
            projectId: row['pid']?.toString() ?? '',
            userId: row['uid']?.toString() ?? '',
            title: row['title']?.toString() ?? '',
            projectPath: row['path']?.toString() ?? '',
            createdAt: _intOf(row['cat']),
            updatedAt: _intOf(row['uat']),
            messages: _intOf(row['n']),
          ),
    ];
  }

  /// 扫描列表时用的轻量打开：没有缓存的密钥、客户端也没在跑时返回 null，
  /// 避免为了列个会话去拉起一个隔离的 Trae 实例抓 key。
  static Future<TraeChatDb?> tryOpenCached() async {
    final hasKey =
        TraeDbKey.fromEnvironment() != null || TraeDbKey.fromCache() != null;
    if (!hasKey) {
      final pids = await DesktopClient.runningPids(PlatformKind.trae);
      if (pids.isEmpty) return null;
    }
    try {
      return await open();
    } catch (_) {
      return null;
    }
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 读一条会话的全部消息（user / assistant 交替）。
  Future<List<ChatMessage>> messages(String sessionId) async {
    final rows = await _db.query(
      'chat_message',
      columns: const [
        'message_id',
        'message_role',
        'message_type',
        'message_index',
        'created_at',
      ],
      where: 'session_id = ? AND deleted_at = 0 AND is_archived = 0',
      whereArgs: [sessionId],
      orderBy: 'message_index, created_at',
    );
    if (rows.isEmpty) return const [];

    final ids = rows.map((row) => row['message_id'].toString()).toList();
    final contents = await _contents(ids);

    final messages = <ChatMessage>[];
    for (final row in rows) {
      final text = (contents[row['message_id'].toString()] ?? '').trim();
      if (text.isEmpty) continue;
      messages.add(
        ChatMessage(
          role: row['message_role']?.toString() ?? '',
          text: text,
          createdAt: _time(row['created_at']),
        ),
      );
    }

    await _appendHistoryReplies(sessionId, messages);
    return messages;
  }

  /// 关闭并清理临时明文库。
  Future<void> close() async {
    try {
      await _db.close();
    } catch (_) {
      // 忽略。
    }
    try {
      await _snapshot.delete(recursive: true);
    } catch (_) {
      // 忽略。
    }
    if (identical(_cached, this)) {
      _cached = null;
      _cachedStamp = null;
    }
  }

  // ---------------------------------------------------------------------------
  // 明文库解析
  // ---------------------------------------------------------------------------

  /// 三张内容表结构不一，统一抽成纯文本（与官方导出格式一致）。
  Future<Map<String, String>> _contents(List<String> ids) async {
    final marks = List.filled(ids.length, '?').join(',');
    final result = <String, String>{};

    // 普通消息：chat_message_general 优先于 chat_message_chat。
    // 三张内容表不一定都存在（取决于客户端版本），缺哪张就当没有。
    for (final table in const ['chat_message_chat', 'chat_message_general']) {
      final rows = await _query(
        'SELECT message_id, content FROM $table '
        'WHERE message_id IN ($marks) AND deleted_at = 0',
        ids,
      );
      for (final row in rows) {
        result[row['message_id'].toString()] = _plainText(row['content']);
      }
    }

    // 任务型消息：content 是事件结构，渲染成可读轨迹。
    final tasks = await _query(
      'SELECT message_id, content FROM chat_message_task '
      'WHERE message_id IN ($marks) AND deleted_at = 0',
      ids,
    );
    for (final row in tasks) {
      result[row['message_id'].toString()] = _renderTaskTrace(row['content']);
    }
    return result;
  }

  /// 表不存在或结构不一致时当作没有数据，不让整个会话读取失败。
  Future<List<Map<String, Object?>>> _query(
    String sql,
    List<Object?> args,
  ) async {
    try {
      return await _db.rawQuery(sql, args);
    } catch (_) {
      return const [];
    }
  }

  /// history_v2 里存的是助手最终回复，正文表里往往只有执行轨迹，
  /// 这里把没有被现有消息覆盖到的回复补进来。
  Future<void> _appendHistoryReplies(
    String sessionId,
    List<ChatMessage> messages,
  ) async {
    final rows = await _query(
      'SELECT messages FROM history_v2 WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return;

    final seen = messages.map((message) => message.text).toList();
    for (final row in rows) {
      final raw = row['messages']?.toString();
      if (raw == null || raw.isEmpty) continue;
      Object? parsed;
      try {
        parsed = jsonDecode(raw);
      } catch (_) {
        continue;
      }
      for (final reply in _historyReplies(parsed)) {
        if (seen.any((text) => text.contains(reply.$1))) continue;
        seen.add(reply.$1);
        messages.add(
          ChatMessage(role: 'assistant', text: reply.$1, createdAt: reply.$2),
        );
      }
    }
  }

  /// 从 history JSON 里取助手回复文本与时间。
  static List<(String, DateTime?)> _historyReplies(Object? parsed) {
    final Object? source = parsed is List
        ? parsed
        : parsed is Map
        ? (parsed['messages'] ?? parsed['raw_messages'] ?? parsed['history'])
        : null;
    if (source is! List) return const [];

    final replies = <(String, DateTime?)>[];
    for (final item in source) {
      if (item is! Map || item['role'] != 'assistant') continue;
      final content = item['content'] ?? item['text'] ?? item['message'] ?? '';
      final text = switch (content) {
        List() => content
            .map(
              (part) => part is String
                  ? part
                  : part is Map
                  ? (part['text_content'] ?? part['text'] ?? part['content'] ?? '')
                        .toString()
                  : '',
            )
            .join('\n'),
        _ => content.toString(),
      }.trim();
      if (text.isEmpty) continue;
      replies.add((text, _time(item['created_at'] ?? item['timestamp'])));
    }
    return replies;
  }

  /// 普通消息：可能是纯文本、JSON 数组或 {content: ...} 结构。
  static String _plainText(Object? raw) {
    if (raw == null) return '';
    final text = raw.toString().trim();
    if (text.isEmpty) return '';

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return text;
    }
    if (decoded is List) {
      return decoded
          .map(
            (item) => item is Map
                ? (item['text_content'] ??
                          item['text'] ??
                          item['content'] ??
                          jsonEncode(item))
                      .toString()
                : item.toString(),
          )
          .join('\n');
    }
    if (decoded is Map) {
      final content = decoded['content'];
      if (content is String) {
        try {
          final nested = jsonDecode(content);
          if (nested is List) {
            return nested
                .map(
                  (item) => item is Map
                      ? (item['text_content'] ?? item['text'] ?? '').toString()
                      : '',
                )
                .join('\n');
          }
        } catch (_) {
          // content 就是纯文本。
        }
        return content;
      }
      return (decoded['text_content'] ??
              decoded['text'] ??
              jsonEncode(decoded))
          .toString();
    }
    return decoded.toString();
  }

  /// chat_message_task 的 content 是 {task_id, messages:[{plan_item}]} 事件结构，
  /// 渲染成「[思考] / [工具] / 正文」的可读轨迹。
  static String _renderTaskTrace(Object? raw) {
    if (raw == null) return '';
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map && decoded['messages'] is List) {
        final lines = <String>[];
        for (final item in decoded['messages'] as List) {
          final plan = item is Map ? item['plan_item'] : null;
          if (plan is! Map) continue;
          final reasoning = plan['reasoning_content'];
          if (reasoning is String && reasoning.trim().isNotEmpty) {
            lines.add('[思考] ${reasoning.trim()}');
          }
          final call = plan['tool_call_info'];
          final params = call is Map ? call['params'] : null;
          if (params is Map) {
            final description = params['description']?.toString() ?? '';
            final command = (params['command'] ?? params['cmd'])?.toString() ?? '';
            final label = [
              description,
              command,
            ].where((text) => text.isNotEmpty).join(' — ');
            if (label.isNotEmpty) lines.add('[工具] $label');
          }
          for (final key in const ['content', 'text_content', 'text']) {
            final value = plan[key];
            if (value is String && value.trim().isNotEmpty) {
              lines.add(value.trim());
            }
          }
        }
        if (lines.isNotEmpty) return lines.join('\n');
      }
    } catch (_) {
      // 非预期结构，走通用解析。
    }
    return _plainText(raw);
  }

  static DateTime? _time(Object? raw) {
    if (raw == null) return null;
    final seconds = int.tryParse(raw.toString());
    if (seconds != null && seconds > 0) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }
    return DateTime.tryParse(raw.toString());
  }

  // ---------------------------------------------------------------------------
  // 解密
  // ---------------------------------------------------------------------------

  static String _stamp(String path) {
    String describe(String file) {
      try {
        final stat = File(file).statSync();
        return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      } catch (_) {
        return '0:0';
      }
    }

    return '${describe(path)}|${describe('$path-wal')}';
  }


  /// 复制主库与 WAL 快照，逐页解密成明文库。
  ///
  /// 不拷 -shm：过期的 wal-index 会让 SQLite 反复回放 WAL。
  /// 解密成明文的临时库（导出/迁移用），调用方负责删除 [dir]。
  static Future<String> decryptToPlain(
    String keyHex,
    String sourcePath,
    Directory dir,
  ) async {
    final copy = File(p.join(dir.path, 'database.db'));
    await File(sourcePath).copy(copy.path);
    final walSource = File('$sourcePath-wal');
    if (await walSource.exists()) {
      await walSource.copy('${copy.path}-wal');
    }

    final key = TraeDbCipher.hexBytes(keyHex);
    final plainPath = p.join(dir.path, 'plain.db');
    final input = await copy.open();
    final output = await File(plainPath).open(mode: FileMode.write);
    try {
      final pages = await input.length() ~/ pageSize;
      // 按 1MB 一块读写：几万次 4KB 读写 + 每页单独分配缓冲区都太慢。
      const pagesPerChunk = 256;
      final source = Uint8List(pageSize * pagesPerChunk);
      final target = Uint8List(pageSize * pagesPerChunk);
      for (var base = 0; base < pages; base += pagesPerChunk) {
        final remaining = pages - base;
        final count = remaining < pagesPerChunk ? remaining : pagesPerChunk;
        await input.setPosition(base * pageSize);
        final read = await input.readInto(source, 0, count * pageSize);
        final whole = read ~/ pageSize;
        for (var i = 0; i < whole; i++) {
          TraeDbCipher.decryptPageInto(
            key,
            source,
            i * pageSize,
            base + i + 1,
            target,
            i * pageSize,
          );
        }
        if (whole > 0) {
          await output.setPosition(base * pageSize);
          await output.writeFrom(target, 0, whole * pageSize);
        }
        if (whole < count) break;
      }
      await _applyWal(key, File('${copy.path}-wal'), output);
    } finally {
      await input.close();
      await output.close();
    }
    return plainPath;
  }

  /// 展平 WAL：只应用当前代的帧（按 salt 过滤），按页号覆盖写入明文库。
  static Future<void> _applyWal(
    Uint8List key,
    File walFile,
    RandomAccessFile output,
  ) async {
    if (!await walFile.exists()) return;
    final wal = await walFile.readAsBytes();
    if (wal.length < 32) return;

    final header = ByteData.sublistView(wal, 0, 32);
    final magic = header.getUint32(0);
    if (magic != 0x377f0682 && magic != 0x377f0683) return;
    if (header.getUint32(8) != pageSize) return;
    final salt1 = header.getUint32(16);
    final salt2 = header.getUint32(20);

    const frameSize = 24 + pageSize;
    final frames = (wal.length - 32) ~/ frameSize;
    final plain = Uint8List(pageSize);
    for (var i = 0; i < frames; i++) {
      final offset = 32 + i * frameSize;
      final head = ByteData.sublistView(wal, offset, offset + 24);
      if (head.getUint32(8) != salt1 || head.getUint32(12) != salt2) continue;
      final pgno = head.getUint32(0);
      if (pgno < 1 || pgno > 5000000) continue;
      try {
        TraeDbCipher.decryptPageInto(key, wal, offset + 24, pgno, plain, 0);
        await output.setPosition((pgno - 1) * pageSize);
        await output.writeFrom(plain);
      } catch (_) {
        // 撕裂帧，跳过。
      }
    }
  }

  /// 打开明文库；默认只读，迁移合并时需要可写。
  static Future<Database> openPlain(String path, {bool readOnly = true}) async {
    if (!_ffiReady) {
      sqfliteFfiInit();
      _ffiReady = true;
    }
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        singleInstance: false,
        readOnly: readOnly,
      ),
    );
  }
}
