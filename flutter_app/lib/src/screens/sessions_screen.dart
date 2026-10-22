import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/chat_session.dart';
import '../services/desktop/desktop_client.dart';
import '../services/sessions/session_service.dart';
import '../services/sessions/trae_migrator.dart';
import '../services/sessions/workbuddy_packer.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';

/// 后台 isolate 的入参：只带可发送的基本类型，避免把 async 帧 / widget 树带过去。
class _CopyRequest {
  const _CopyRequest({
    required this.fromUid,
    required this.toUid,
    required this.sessionIds,
  });

  final String fromUid;
  final String toUid;
  final Set<String> sessionIds;
}

class _MergeRequest {
  const _MergeRequest({required this.path, required this.dryRun});

  final String path;
  final bool dryRun;
}

/// 顶层入口：加解密 + 复制 200 MB 级的库要十几秒，放后台 isolate 跑。
Future<TraeCopyResult> _copyTask(_CopyRequest request) =>
    const TraeMigrator().copySessions(
      fromUid: request.fromUid,
      toUid: request.toUid,
      sessionIds: request.sessionIds,
    );

Future<TraePackResult> _packTask(Set<String> sessionIds) =>
    const TraeMigrator().pack(sessionIds: sessionIds);

Future<TraeMergeResult> _mergeTask(_MergeRequest request) =>
    const TraeMigrator().merge(
      fromPath: request.path,
      dryRun: request.dryRun,
      requireClientClosed: false,
    );

/// 会话：把本机客户端里散落的会话（WorkBuddy 桌面端 / CLI、Trae）合并成一张列表，
/// 选中的桌面端会话可以复制到另一个 WorkBuddy 账号。
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({super.key, this.scanOverride, this.service});

  /// 仅测试使用：注入一份扫描结果，避免依赖本机真实目录。
  final Future<SessionScanResult> Function()? scanOverride;

  /// 仅测试使用：替换会话服务（例如让 Trae 正文读取不碰本机加密库）。
  final SessionService? service;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late final SessionService _service = widget.service ?? const SessionService();

  SessionScanResult? _scan;
  final Set<String> _selected = {};
  final Map<String, int> _pages = {};
  String _query = '';
  PlatformKind? _providerFilter;
  bool _loading = true;
  bool _packing = false;
  bool _merging = false;

  /// 上次扫描完成时间：短时间内重复进入页面不再全盘重扫。
  DateTime? _lastScan;
  static const _scanTtl = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    final last = _lastScan;
    if (!force &&
        _scan != null &&
        last != null &&
        DateTime.now().difference(last) < _scanTtl) {
      return;
    }
    setState(() => _loading = true);
    final result = await (widget.scanOverride?.call() ?? _service.scan());
    if (!mounted) return;
    _lastScan = DateTime.now();
    setState(() {
      _scan = result;
      _loading = false;
      _pages.clear();
      _selected.removeWhere((key) {
        return !result.sessions.any(
          (session) =>
              session.key == key &&
              (session.accountMigratable || session.migratable),
        );
      });
    });
  }

  void _toggle(ChatSession session, bool selected) {
    setState(() {
      if (selected) {
        // 一次只能操作一类：要么 WorkBuddy 迁移到账号，要么 Trae 导出迁移包。
        final mixing = _selectedSessions.any(
          (item) => item.migratable != session.migratable,
        );
        if (mixing) _selected.clear();
        // 桌面端会话一次只能来自同一个账号；CLI 会话没有账号归属，不参与。
        final uids = _selectedSessions
            .map((item) => item.accountUid)
            .where((uid) => uid.isNotEmpty)
            .toSet();
        if (session.copyable &&
            uids.length == 1 &&
            !uids.contains(session.accountUid)) {
          _selected.clear();
        }
        _selected.add(session.key);
      } else {
        _selected.remove(session.key);
      }
    });
  }

  List<ChatSession> get _selectedSessions {
    final sessions = _scan?.sessions ?? const <ChatSession>[];
    return sessions
        .where((session) => _selected.contains(session.key))
        .toList();
  }

  void _setQuery(String value) {
    setState(() {
      _query = value;
      _pages.clear();
    });
  }

  void _setProvider(PlatformKind? provider) {
    setState(() {
      _providerFilter = provider;
      _pages.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < AppTokens.mediumBreakpoint;
    final pageSize = width >= AppTokens.wideBreakpoint ? 8 : 6;
    final scan = _scan;
    final groups = _groups(state);

    final traeSelected = _selectedSessions
        .where((session) => session.migratable)
        .length;
    final accountSelected = _selectedSessions
        .where((session) => session.accountMigratable)
        .length;
    final actions = WrapActions(
      alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
      children: [
        OutlinedButton.icon(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('刷新'),
        ),
        OutlinedButton.icon(
          onPressed: _packing || _merging ? null : () => _importPack(context),
          icon: const Icon(Icons.file_download_rounded, size: 16),
          label: const Text('导入迁移包'),
        ),
        FilledButton.icon(
          onPressed: accountSelected + traeSelected == 0
              ? null
              : () => _migrateDialog(context, state),
          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
          label: Text(
            accountSelected + traeSelected == 0
                ? '迁移到其他账号…'
                : traeSelected > 0
                ? '复制 $traeSelected 条到账号…'
                : '迁移 $accountSelected 条到账号…',
          ),
        ),
        if (_selected.isNotEmpty)
          OutlinedButton.icon(
            onPressed: _packing ? null : () => _exportPack(context),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(
              _packing
                  ? '导出中…'
                  : traeSelected > 0
                  ? '导出 $traeSelected 条迁移包'
                  : '导出 ${_selected.length} 条会话包',
            ),
          ),
      ],
    );

    return ListView(
      padding: EdgeInsets.all(narrow ? AppTokens.space4 : AppTokens.space5),
      children: [
        if (narrow) ...[
          Text('会话', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppTokens.space1),
          Text(
            '合并本机客户端里的会话：WorkBuddy / CodeBuddy IDE / CLI 可迁移到另一个账号，Trae 可复制一份到另一个账号，或导出迁移包',
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppTokens.space3),
          actions,
        ] else
          SectionTitle(
            title: '会话',
            subtitle:
                '合并本机客户端里的会话：WorkBuddy / CodeBuddy IDE / CLI 迁移到另一个账号；Trae 复制到另一个账号，或导出迁移包',
            trailing: actions,
          ),
        const SizedBox(height: AppTokens.space4),
        if (!DesktopClient.supported)
          const EmptyState(
            icon: Icons.desktop_access_disabled_rounded,
            title: '当前平台不支持读取会话',
            message: '会话来自桌面客户端的本地数据目录，请在 Windows / macOS / Linux 客户端上查看。',
          )
        else if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTokens.space6),
            child: Center(
              child: Text(
                '正在读取本机会话…',
                style: TextStyle(color: palette.textSecondary, fontSize: 13),
              ),
            ),
          )
        else if (scan == null || scan.sessions.isEmpty)
          const EmptyState(
            icon: Icons.forum_outlined,
            title: '本机没有找到会话',
            message: '先用对应客户端聊过一次，或确认客户端的数据目录可读。',
          )
        else ...[
          _SummaryBar(
            scan: scan,
            provider: _providerFilter,
            onProvider: _setProvider,
          ),
          const SizedBox(height: AppTokens.space3),
          _SearchField(value: _query, onChanged: _setQuery),
          const SizedBox(height: AppTokens.space4),
          if (groups.isEmpty)
            const EmptyState(
              icon: Icons.search_off_rounded,
              title: '没有匹配的会话',
              message: '换个关键词，或把筛选切回「全部」。',
            )
          else
            for (final group in groups) ...[
              _SessionGroupCard(
                group: group,
                selected: _selected,
                page: _pages[group.key] ?? 0,
                pageSize: pageSize,
                onPage: (page) => setState(() => _pages[group.key] = page),
                onToggle: _toggle,
                onOpen: (session) => _showSession(context, session),
              ),
              const SizedBox(height: AppTokens.space4),
            ],
          Text(
            '对话正文来自客户端本地文件；Trae 的正文保存在客户端加密库里，只能显示会话信息与最后一条回复摘要。'
            'Qoder 会读桌面端 main.sqlite 与 CLI 的 projects/*.jsonl。'
            '转存会写入目标账号的数据目录，建议先退出客户端再操作，重启客户端后生效。',
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  List<_SessionGroup> _groups(AppState state) {
    final scan = _scan;
    if (scan == null) return const [];
    final query = _query.trim().toLowerCase();

    bool matches(ChatSession session) {
      if (_providerFilter != null && session.provider != _providerFilter) {
        return false;
      }
      if (query.isEmpty) return true;
      final haystack = [
        session.title,
        session.project,
        session.cwd,
        session.sessionId,
        session.agent,
        session.model,
        session.preview,
      ].join(' ').toLowerCase();
      return haystack.contains(query);
    }

    final sessions = scan.sessions.where(matches).toList();
    final groups = <_SessionGroup>[];
    final known = <String>{};

    for (final account in state.accounts) {
      final list = sessions
          .where(
            (session) =>
                session.provider == account.provider &&
                session.accountUid == account.externalId,
          )
          .toList();
      if (list.isEmpty) continue;
      known.add('${account.provider.id}:${account.externalId}');
      groups.add(
        _SessionGroup(
          title: account.title,
          subtitle: '已登记账号 · ${account.externalId}',
          provider: account.provider,
          sessions: list,
        ),
      );
    }

    // 数据目录里存在、但账号库里没有登记的账号，单独成组，避免会话凭空消失。
    final unmatched = <String, List<ChatSession>>{};
    for (final session in sessions) {
      if (session.accountUid.isEmpty) continue;
      final key = '${session.provider.id}:${session.accountUid}';
      if (known.contains(key)) continue;
      unmatched.putIfAbsent(key, () => []).add(session);
    }
    for (final entry in unmatched.entries) {
      final first = entry.value.first;
      final uid = first.accountUid;
      groups.add(
        _SessionGroup(
          title: '未登记账号 · ${uid.length > 8 ? uid.substring(0, 8) : uid}',
          subtitle: uid,
          provider: first.provider,
          sessions: entry.value,
        ),
      );
    }

    final cli = sessions
        .where((session) => session.source == SessionSource.workbuddyCli)
        .toList();
    if (cli.isNotEmpty) {
      groups.add(
        _SessionGroup(
          title: 'CodeBuddy CLI',
          subtitle: '~/.codebuddy/projects',
          provider: PlatformKind.workbuddy,
          sessions: cli,
        ),
      );
    }

    final looseDesktop = sessions
        .where(
          (session) =>
              session.source == SessionSource.workbuddyDesktop &&
              session.accountUid.isEmpty,
        )
        .toList();
    if (looseDesktop.isNotEmpty) {
      groups.add(
        _SessionGroup(
          title: 'WorkBuddy · 未关联账号',
          subtitle: '仅桌面端会话元数据',
          provider: PlatformKind.workbuddy,
          sessions: looseDesktop,
        ),
      );
    }

    final looseTrae = sessions
        .where(
          (session) =>
              session.provider == PlatformKind.trae &&
              session.accountUid.isEmpty,
        )
        .toList();
    if (looseTrae.isNotEmpty) {
      groups.add(
        _SessionGroup(
          title: 'Trae · 未关联账号',
          subtitle: '状态库里没有记录 UserID',
          provider: PlatformKind.trae,
          sessions: looseTrae,
        ),
      );
    }

    final looseQoder = sessions
        .where(
          (session) =>
              session.provider == PlatformKind.qoder &&
              session.accountUid.isEmpty,
        )
        .toList();
    if (looseQoder.isNotEmpty) {
      groups.add(
        _SessionGroup(
          title: 'Qoder · 本机会话',
          subtitle: '桌面端未登录或读不到当前账号',
          provider: PlatformKind.qoder,
          sessions: looseQoder,
        ),
      );
    }

    return groups;
  }

  Future<void> _migrateDialog(BuildContext context, AppState state) async {
    final trae = _selectedSessions
        .where((session) => session.migratable)
        .toList();
    if (trae.isNotEmpty) return _copyDialog(context, state, trae);

    final sessions = _selectedSessions
        .where((session) => session.accountMigratable)
        .toList();
    if (sessions.isEmpty) return;
    final sourceUid = sessions
        .map((session) => session.accountUid)
        .firstWhere((uid) => uid.isNotEmpty, orElse: () => '');
    final targets = state.accounts
        .where(
          (account) =>
              account.provider == PlatformKind.workbuddy &&
              (sourceUid.isEmpty || account.externalId != sourceUid),
        )
        .toList();
    if (targets.isEmpty) {
      showAppSnackBar(context, '没有其他 WorkBuddy 账号可作为迁移目标', error: true);
      return;
    }

    // WorkBuddy 客户端会话是改归属（原账号不再有），CodeBuddy IDE 是复制一份。
    final movingOnly = sessions.every((session) => session.movable);
    final target = await showDialog<Account>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('迁移 ${sessions.length} 条会话'),
        content: SizedBox(
          width: min(380, MediaQuery.sizeOf(context).width - 64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                movingOnly
                    ? '选择目标账号（会话归属改到目标账号，原账号不再显示）：'
                    : '选择目标账号（会复制一份，原账号保留）：',
              ),
              const SizedBox(height: AppTokens.space2),
              for (final account in targets)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.account_circle_outlined,
                    size: 18,
                    color: AppTokensScope.of(context).accent,
                  ),
                  title: Text(account.title),
                  subtitle: Text(
                    account.externalId,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(context, account),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;

    try {
      final count = await _withProgress(
        context,
        '正在迁移 ${sessions.length} 条会话到 ${target.title}…',
        () => _service.copySessions(
          sessions: sessions,
          targetUid: target.externalId,
        ),
      );
      if (!context.mounted) return;
      setState(() {
        _selected.clear();
      });
      showAppSnackBar(
        context,
        count == 0
            ? '没有可迁移的会话'
            : movingOnly
            ? '已把 $count 条会话改归属到 ${target.title}'
            : '已迁移 $count 条到 ${target.title}，重启 CodeBuddy IDE 并打开对应项目文件夹即可看到',
      );
      await _load(force: true);
    } catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(context, '迁移失败：$error', error: true);
    }
  }

  /// 写客户端库的操作（解密 → 改写 → 重加密）要几秒，期间用模态进度锁住界面：
  /// 既告诉用户「在干活」，也防止中途退出 / 关客户端导致写坏。
  Future<T> _withProgress<T>(
    BuildContext context,
    String label,
    Future<T> Function() task,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: AppTokens.space3),
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
    navigator.push(route);
    try {
      return await task();
    } finally {
      if (route.isActive) navigator.removeRoute(route);
    }
  }

  /// 迁移条件不满足时的说明弹窗（比 SnackBar 更不容易被忽略）。
  Future<void> _showMigrationHint(
    BuildContext context,
    String title,
    String message,
  ) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: min(400, MediaQuery.sizeOf(context).width - 64),
          child: Text(
            message,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 写 Trae 会话库前先确认客户端已退出；只是残留在托盘/后台时给出「结束并继续」。
  Future<bool> _ensureTraeClosed(BuildContext context) async {
    final pids = await DesktopClient.runningPids(PlatformKind.trae);
    if (pids.isEmpty) return true;
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Trae 还在运行'),
        content: SizedBox(
          width: min(400, MediaQuery.sizeOf(context).width - 64),
          child: Text(
            '检测到 Trae 进程（pid ${pids.take(3).join('、')}）。'
            '写入会话库前需要完全退出，否则会被客户端覆盖。是否结束它并继续？',
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('结束并继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    final left = await DesktopClient.stop(PlatformKind.trae);
    if (left.isEmpty) return true;
    if (context.mounted) {
      showAppSnackBar(
        context,
        'Trae 仍在运行（pid ${left.join('、')}），请先在托盘里退出再试',
        error: true,
      );
    }
    return false;
  }

  /// Trae 的会话库里没有账号列，归属记在「项目」上：复制 =
  /// 给目标账号建/复用同路径项目，把选中的会话整条复制过去（原会话保留）。
  Future<void> _copyDialog(
    BuildContext context,
    AppState state,
    List<ChatSession> sessions,
  ) async {
    final sourceUid = sessions.first.accountUid;
    if (sourceUid.isEmpty) {
      await _showMigrationHint(
        context,
        '这条 Trae 会话没有关联账号',
        '会话归属是从 Trae 的登录态里读出来的，这条记录没有留下账号信息，无法判断副本要放到哪个账号下。',
      );
      return;
    }
    final registered = <String>{
      for (final account in state.accounts)
        if (account.provider == PlatformKind.trae) account.externalId,
    };
    // 会话库里有、账号库里没登记的账号也列出来：复制只需要目标 uid，
    // 不要求本机当前登录着那个账号。
    final discovered = <String>{
      for (final session in _scan?.sessions ?? const <ChatSession>[])
        if (session.provider == PlatformKind.trae &&
            session.accountUid.isNotEmpty &&
            session.accountUid != sourceUid &&
            !registered.contains(session.accountUid))
          session.accountUid,
    };
    final targets = <({String title, String uid})>[
      for (final account in state.accounts)
        if (account.provider == PlatformKind.trae &&
            account.externalId != sourceUid)
          (title: account.title, uid: account.externalId),
      for (final uid in discovered)
        (
          title: '未登记账号 · ${uid.length > 8 ? uid.substring(0, 8) : uid}',
          uid: uid,
        ),
    ];
    if (targets.isEmpty) {
      await _showMigrationHint(
        context,
        '没有其他 Trae 账号可以作为目标',
        '本机会话库里只有 $sourceUid 这一个 Trae 账号的记录。'
            '先在 Trae 里登录另一个账号（随便打开一个项目，让它产生会话），再回来刷新即可。',
      );
      return;
    }

    final target = await showDialog<({String title, String uid})>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('复制 ${sessions.length} 条 Trae 会话'),
        content: SizedBox(
          width: min(420, MediaQuery.sizeOf(context).width - 64),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '把选中的 ${sessions.length} 条会话复制一份到目标账号，原账号的会话保留不动。'
                'Trae 的归属记在项目上，副本会挂在目标账号的同路径项目下（没有就新建一个）。',
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: AppTokens.space2),
              const Text(
                '请先完全退出 Trae 客户端；原库会自动备份，可随时还原。',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: AppTokens.space3),
              const Text('选择目标账号：'),
              for (final account in targets)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.account_circle_outlined,
                    size: 18,
                    color: AppTokensScope.of(context).accent,
                  ),
                  title: Text(account.title),
                  subtitle: Text(
                    account.uid,
                    style: const TextStyle(fontSize: 11),
                  ),
                  onTap: () => Navigator.pop(context, account),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target == null || !context.mounted) return;
    if (!await _ensureTraeClosed(context)) return;
    if (!context.mounted) return;

    setState(() => _merging = true);
    try {
      final ids = sessions.map((session) => session.sessionId).toSet();
      // 加解密 + 复制 200 MB 级的库要十几秒，放后台 isolate，界面才不会「未响应」。
      final result = await _withProgress(
        context,
        '正在复制 ${ids.length} 条 Trae 会话（解密 → 复制 → 重新加密）…',
        () => compute(
          _copyTask,
          _CopyRequest(
            fromUid: sourceUid,
            toUid: target.uid,
            sessionIds: ids,
          ),
        ),
      );
      if (!context.mounted) return;
      if (result.sessions == 0) {
        showAppSnackBar(context, '没有找到可复制的会话');
      } else {
        // 后台 isolate 拿不到应用目录，归属兜底记录放到主 isolate 写。
        await SessionService.rememberTraeOwnership({
          for (final id in result.newSessionIds.values) id: target.uid,
        });
        if (!context.mounted) return;
        await _showCopyReport(context, result, target);
      }
      setState(() => _selected.clear());
      await _load(force: true);
    } on TraeMigrationException catch (error) {
      if (context.mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '复制失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  Future<void> _showCopyReport(
    BuildContext context,
    TraeCopyResult result,
    ({String title, String uid}) target,
  ) async {
    final tables = result.tables.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('会话已复制'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已把 ${result.sessions} 条会话复制到 ${target.title}（${result.toUid}），'
                  '共写入 ${result.rows} 行；原账号的会话保持不变。',
                ),
                const SizedBox(height: AppTokens.space2),
                Text(
                  '新会话 ${result.newSessionIds.length} 条 · 新建项目 ${result.createdProjects} 个',
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
                if (tables.isNotEmpty) ...[
                  const SizedBox(height: AppTokens.space2),
                  for (final entry in tables.take(8))
                    Text(
                      '· ${entry.key}：${entry.value}',
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                ],
                if (result.backupPath != null) ...[
                  const SizedBox(height: AppTokens.space3),
                  const Text('原库备份：', style: TextStyle(fontSize: 12)),
                  SelectableText(
                    result.backupPath!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                const SizedBox(height: AppTokens.space3),
                const Text(
                  'Trae 的会话列表只显示「当前打开的工作区」里的会话。'
                  '重启并切到目标账号后，打开下面这些文件夹才能看到副本，'
                  '开着别的工作区时不会出现：',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
                for (final path in result.projectPaths)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTokens.space1),
                    child: SelectableText(
                      '· $path',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 导出选中的会话：Trae 走加密库裁剪成的 SQLite 迁移包，
  /// WorkBuddy 家族走明文 JSON 会话包（导入端写回 WorkBuddy 客户端）。
  Future<void> _exportPack(BuildContext context) async {
    final sessions = _selectedSessions;
    if (sessions.isEmpty) return;
    final trae = sessions.where((session) => session.migratable).toList();
    if (trae.isEmpty) return _exportWorkbuddyPack(context, sessions);
    final ids = trae.map((session) => session.sessionId).toSet();
    setState(() => _packing = true);
    try {
      final result = await _withProgress(
        context,
        '正在导出 ${ids.length} 条会话的迁移包…',
        () => compute(_packTask, ids),
      );
      if (!context.mounted) return;
      setState(() => _selected.clear());
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('迁移包已导出'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '含 ${result.sessions} 个会话 · ${_formatBytes(result.sizeBytes)}',
                ),
                const SizedBox(height: AppTokens.space2),
                SelectableText(
                  result.path,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
                const SizedBox(height: AppTokens.space3),
                const Text(
                  '把文件拷到另一台机器，在那台机器上退出 Trae 后点「导入迁移包」。包里是明文正文，传完请删除。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.path));
                if (context.mounted) showAppSnackBar(context, '路径已复制');
              },
              child: const Text('复制路径'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on TraeMigrationException catch (error) {
      if (context.mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '导出失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _packing = false);
    }
  }

  /// 导出 WorkBuddy / CodeBuddy IDE / CLI 会话成 JSON 包。
  Future<void> _exportWorkbuddyPack(
    BuildContext context,
    List<ChatSession> sessions,
  ) async {
    setState(() => _packing = true);
    try {
      final result = await _withProgress(
        context,
        '正在导出 ${sessions.length} 条会话…',
        () => const WorkbuddyPacker().pack(
          sessions: sessions,
          readMessages: _service.readMessages,
        ),
      );
      if (!context.mounted) return;
      setState(() => _selected.clear());
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('会话包已导出'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '含 ${result.sessions} 个会话 · ${_formatBytes(result.sizeBytes)}',
                ),
                const SizedBox(height: AppTokens.space2),
                SelectableText(
                  result.path,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                ),
                const SizedBox(height: AppTokens.space3),
                const Text(
                  '在另一台机器上点「导入迁移包」选这个文件即可写进 WorkBuddy。包里是明文正文，传完请删除。',
                  style: TextStyle(fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: result.path));
                if (context.mounted) showAppSnackBar(context, '路径已复制');
              },
              child: const Text('复制路径'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } on WorkbuddyPackException catch (error) {
      if (context.mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '导出失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _packing = false);
    }
  }

  /// 会话包是 JSON（WorkBuddy 家族），迁移包是 SQLite（Trae）。
  static Future<bool> _isWorkbuddyPack(String path) async {
    try {
      final handle = await File(path).open();
      try {
        final head = await handle.read(64);
        return utf8
            .decode(head, allowMalformed: true)
            .trimLeft()
            .startsWith('{');
      } finally {
        await handle.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _importWorkbuddyPack(
    BuildContext context,
    String path,
    bool dryRun,
  ) async {
    final state = context.read<AppState>();
    final accounts = state.accounts
        .where((account) => account.provider == PlatformKind.workbuddy)
        .toList();

    String? target;
    if (accounts.isNotEmpty) {
      target = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入到哪个账号'),
          content: SizedBox(
            width: min(380, MediaQuery.sizeOf(context).width - 64),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.inbox_outlined, size: 18),
                  title: const Text('沿用包里的账号'),
                  onTap: () => Navigator.pop(context, ''),
                ),
                for (final account in accounts)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.account_circle_outlined,
                      size: 18,
                      color: AppTokensScope.of(context).accent,
                    ),
                    title: Text(account.title),
                    subtitle: Text(
                      account.externalId,
                      style: const TextStyle(fontSize: 11),
                    ),
                    onTap: () => Navigator.pop(context, account.externalId),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (target == null || !context.mounted) return;
    }

    setState(() => _merging = true);
    try {
      final count = await _withProgress(
        context,
        dryRun ? '正在试算会话包…' : '正在把会话写进 WorkBuddy…',
        () => const WorkbuddyPacker().import(
          fromPath: path,
          targetUid: (target != null && target.isNotEmpty) ? target : null,
          dryRun: dryRun,
        ),
      );
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        dryRun ? '会话包里有 $count 条会话（未写入）' : '已导入 $count 条会话到 WorkBuddy',
      );
      if (!dryRun) await _load(force: true);
    } on WorkbuddyPackException catch (error) {
      if (context.mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '导入失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  /// 把迁移包里的新会话合并进本机 Trae 库（会自动备份并重新加密）。
  Future<void> _importPack(BuildContext context) async {
    final request = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => const _ImportPackDialog(),
    );
    if (request == null || !context.mounted) return;
    final (path, dryRun) = request;
    final workbuddyPack = await _isWorkbuddyPack(path);
    if (!context.mounted) return;
    if (workbuddyPack) {
      return _importWorkbuddyPack(context, path, dryRun);
    }
    if (!dryRun && !await _ensureTraeClosed(context)) return;
    if (!context.mounted) return;
    setState(() => _merging = true);
    try {
      final result = await _withProgress(
        context,
        dryRun ? '正在试算迁移包…' : '正在合并迁移包（解密 → 合并 → 重新加密）…',
        () => compute(_mergeTask, _MergeRequest(path: path, dryRun: dryRun)),
      );
      if (!context.mounted) return;
      await _showMergeReport(context, result);
      if (!result.dryRun) await _load(force: true);
    } on TraeMigrationException catch (error) {
      if (context.mounted) showAppSnackBar(context, error.message, error: true);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, '合并失败：$error', error: true);
      }
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  Future<void> _showMergeReport(
    BuildContext context,
    TraeMergeResult result,
  ) async {
    final tables = result.tables.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.dryRun ? '试算结果（未写入）' : '合并完成'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '源包 ${result.sourceSessions} 个会话，其中新会话 '
                  '${result.newSessions} 个，合计写入 ${result.rows} 行',
                ),
                if (tables.isEmpty) ...[
                  const SizedBox(height: AppTokens.space2),
                  const Text('没有新会话需要导入，本机库未改动。'),
                ],
                for (final entry in tables.take(10))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${entry.key}: ${entry.value.$1}'
                      '${entry.value.$1 == entry.value.$2 ? '' : ' / ${entry.value.$2}'}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (result.backupPath != null) ...[
                  const SizedBox(height: AppTokens.space3),
                  const Text('原库备份：', style: TextStyle(fontSize: 12)),
                  SelectableText(
                    result.backupPath!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSession(BuildContext context, ChatSession session) async {
    final palette = AppTokensScope.of(context);
    final messages = _service.readMessages(session);
    final screen = MediaQuery.sizeOf(context);
    final meta = [
      session.source.label,
      if (session.projectLabel.isNotEmpty) session.projectLabel,
      if (session.agent.isNotEmpty) session.agent,
      if (session.model.isNotEmpty) session.model,
      '${session.messageCount} 条消息',
    ].join(' · ');

    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: EdgeInsets.all(
          screen.width < AppTokens.mediumBreakpoint
              ? AppTokens.space3
              : AppTokens.space6,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: min(760, screen.width),
            maxHeight: min(640, screen.height * 0.88),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTokens.space4,
                  AppTokens.space4,
                  AppTokens.space2,
                  AppTokens.space2,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.title,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: palette.outline),
              Expanded(
                child: _SessionBody(session: session, messages: messages),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部统计 + 平台筛选。
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.scan,
    required this.provider,
    required this.onProvider,
  });

  final SessionScanResult scan;
  final PlatformKind? provider;
  final ValueChanged<PlatformKind?> onProvider;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    String? part(String label, int count) =>
        count == 0 ? null : '$label $count';
    final parts = <String>[
      ?part('WorkBuddy', scan.countOf(SessionSource.workbuddyApp)),
      ?part('CodeBuddy IDE', scan.countOf(SessionSource.workbuddyDesktop)),
      ?part('CLI', scan.countOf(SessionSource.workbuddyCli)),
      ?part('Trae', scan.traeCount),
      ?part('Qoder', scan.countOf(SessionSource.qoder)),
    ];
    return Wrap(
      spacing: AppTokens.space2,
      runSpacing: AppTokens.space2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '共 ${scan.sessions.length} 条 · ${parts.join(' · ')}',
          style: TextStyle(fontSize: 12, color: palette.textSecondary),
        ),
        const SizedBox(width: AppTokens.space2),
        for (final option in <PlatformKind?>[
          null,
          ...PlatformKind.values.where(
            (provider) => scan.sessions.any(
              (session) => session.provider == provider,
            ),
          ),
        ])
          ChoiceChip(
            label: Text(option == null ? '全部' : option.label),
            selected: provider == option,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onProvider(option),
          ),
      ],
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部清空（例如切换筛选）时同步输入框，正常输入不会被覆盖。
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
      _controller.selection = TextSelection.collapsed(
        offset: widget.value.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _controller,
          onChanged: widget.onChanged,
          decoration: const InputDecoration(
            isDense: true,
            hintText: '搜索标题、项目、模型或会话 ID',
            prefixIcon: Icon(Icons.search_rounded, size: 18),
          ),
        ),
      ),
    );
  }
}

class _SessionGroup {
  const _SessionGroup({
    required this.title,
    required this.subtitle,
    required this.provider,
    required this.sessions,
  });

  final String title;
  final String subtitle;
  final PlatformKind provider;
  final List<ChatSession> sessions;

  String get key => '${provider.id}:$title';
}

class _SessionGroupCard extends StatelessWidget {
  const _SessionGroupCard({
    required this.group,
    required this.selected,
    required this.page,
    required this.pageSize,
    required this.onPage,
    required this.onToggle,
    required this.onOpen,
  });

  final _SessionGroup group;
  final Set<String> selected;
  final int page;
  final int pageSize;
  final ValueChanged<int> onPage;
  final void Function(ChatSession session, bool selected) onToggle;
  final ValueChanged<ChatSession> onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final textTheme = Theme.of(context).textTheme;
    final totalPages = (group.sessions.length + pageSize - 1) ~/ pageSize;
    final current = page.clamp(0, totalPages - 1);
    final visible = group.sessions
        .skip(current * pageSize)
        .take(pageSize)
        .toList();

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ProviderChip(provider: group.provider, dense: true),
              const SizedBox(width: AppTokens.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (group.subtitle.isNotEmpty)
                      Text(
                        group.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppTokens.space2),
              Text(
                '${group.sessions.length} 条会话',
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            ],
          ),
          if (group.sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTokens.space3),
              child: Text(
                '本机没有这个账号的会话记录（登录客户端并聊过一次后才会出现）',
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
            )
          else ...[
            const SizedBox(height: AppTokens.space2),
            for (final session in visible)
              _SessionRow(
                session: session,
                checked: selected.contains(session.key),
                onCheck: (value) => onToggle(session, value),
                onOpen: () => onOpen(session),
              ),
            if (totalPages > 1)
              Padding(
                padding: const EdgeInsets.only(top: AppTokens.space1),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      '第 ${current + 1} / $totalPages 页',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textSecondary,
                      ),
                    ),
                    const SizedBox(width: AppTokens.space1),
                    IconButton(
                      tooltip: '上一页',
                      visualDensity: VisualDensity.compact,
                      onPressed: current > 0 ? () => onPage(current - 1) : null,
                      icon: const Icon(Icons.chevron_left_rounded, size: 18),
                    ),
                    IconButton(
                      tooltip: '下一页',
                      visualDensity: VisualDensity.compact,
                      onPressed: current < totalPages - 1
                          ? () => onPage(current + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.checked,
    required this.onCheck,
    required this.onOpen,
  });

  final ChatSession session;
  final bool checked;
  final ValueChanged<bool> onCheck;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final meta = <String>[
      session.sourceLabel,
      if (session.projectLabel.isNotEmpty) session.projectLabel,
      if (session.model.isNotEmpty) session.model,
      if (session.agent.isNotEmpty) session.agent,
      '${session.messageCount} 条消息',
      if (session.updatedAt != null)
        DateFormat('MM-dd HH:mm').format(session.updatedAt!.toLocal()),
      if ((session.status).isNotEmpty) session.status,
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: AppTokens.space1),
      decoration: BoxDecoration(
        color: checked
            ? palette.accent.withValues(alpha: 0.06)
            : palette.surface,
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        border: Border.all(
          color: checked
              ? palette.accent.withValues(alpha: 0.4)
              : palette.outline,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: (session.accountMigratable || session.migratable)
              ? 0
              : AppTokens.space3,
          top: AppTokens.space1,
          bottom: AppTokens.space1,
          right: AppTokens.space1,
        ),
        child: Row(
          children: [
            if (session.accountMigratable || session.migratable)
              Checkbox(
                value: checked,
                visualDensity: VisualDensity.compact,
                onChanged: (value) => onCheck(value ?? false),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    style: const TextStyle(fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta.join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (session.preview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '“${session.preview}”',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textSecondary.withValues(alpha: 0.85),
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppTokens.space2),
            TextButton(onPressed: onOpen, child: const Text('查看')),
          ],
        ),
      ),
    );
  }
}

class _SessionBody extends StatelessWidget {
  const _SessionBody({required this.session, required this.messages});

  final ChatSession session;
  final Future<List<ChatMessage>> messages;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ChatMessage>>(
      future: messages,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _SessionLoading(
            label: session.source == SessionSource.trae
                ? '正在解密 Trae 会话库…'
                : '正在读取会话…',
          );
        }
        return _body(context, snapshot.data ?? const []);
      },
    );
  }

  Widget _body(BuildContext context, List<ChatMessage> messages) {
    final palette = AppTokensScope.of(context);

    if (messages.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(AppTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (session.preview.isNotEmpty) ...[
              Text(
                '最后一条回复',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: palette.textSecondary,
                ),
              ),
              const SizedBox(height: AppTokens.space2),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppTokens.space3),
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  border: Border.all(color: palette.outline),
                ),
                child: SelectableText(
                  session.preview,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
              ),
              const SizedBox(height: AppTokens.space3),
            ],
            Text(
              session.source == SessionSource.trae
                  ? '没能读到这条会话的正文：Trae 未运行、密钥被系统拒绝，或这条会话没有正文。'
                        '先启动一次 Trae 再重试，或用 TRAE_DB_KEY 指定密钥。'
                  : session.messageCount == 0
                  ? '这条会话没有消息记录，只保留了客户端登记的信息。'
                  : '这条会话没有可显示的消息',
              style: TextStyle(
                fontSize: 12,
                color: palette.textSecondary,
                height: 1.5,
              ),
            ),
            if (session.path.isNotEmpty) ...[
              const SizedBox(height: AppTokens.space3),
              SelectableText(
                session.path,
                style: TextStyle(fontSize: 11, color: palette.textSecondary),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(AppTokens.space4),
      itemCount: messages.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppTokens.space3),
      itemBuilder: (context, index) {
        final message = messages[index];
        final isUser = message.role == 'user';
        return Container(
          padding: const EdgeInsets.all(AppTokens.space3),
          decoration: BoxDecoration(
            color: isUser ? palette.surfaceElevated : palette.surface,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            border: Border.all(color: palette.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    isUser ? '我' : 'AI',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isUser ? palette.accent : palette.success,
                    ),
                  ),
                  if (message.createdAt != null) ...[
                    const SizedBox(width: AppTokens.space2),
                    Text(
                      DateFormat(
                        'MM-dd HH:mm',
                      ).format(message.createdAt!.toLocal()),
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              SelectableText(
                message.text,
                style: const TextStyle(fontSize: 13, height: 1.5),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 会话正文加载中的占位（Trae 要解密整个库，可能需要几秒）。
class _SessionLoading extends StatelessWidget {
  const _SessionLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AppTokens.space3),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 选择迁移包文件（手填路径）+ 是否只试算。
class _ImportPackDialog extends StatefulWidget {
  const _ImportPackDialog();

  @override
  State<_ImportPackDialog> createState() => _ImportPackDialogState();
}

class _ImportPackDialogState extends State<_ImportPackDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _dryRun = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return AlertDialog(
      title: const Text('导入迁移包'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '包路径：Trae 是 trae-sessions-*.db，WorkBuddy 是 workbuddy-sessions-*.json，'
              '会自动识别',
            ),
            const SizedBox(height: AppTokens.space2),
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: '/home/user/trae-sessions-20261020.db',
                isDense: true,
              ),
            ),
            const SizedBox(height: AppTokens.space2),
            Text(
              '合并前请完全退出 Trae；导入会自动备份原库，已有会话保持本机版本。',
              style: TextStyle(
                fontSize: 11,
                color: palette.textSecondary,
                height: 1.5,
              ),
            ),
            CheckboxListTile(
              value: _dryRun,
              onChanged: (value) => setState(() => _dryRun = value ?? false),
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('只试算，不写入', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final path = _controller.text.trim();
            if (path.isEmpty) return;
            Navigator.pop(context, (path, _dryRun));
          },
          child: const Text('开始'),
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
