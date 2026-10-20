import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/chat_session.dart';
import '../services/desktop/desktop_client.dart';
import '../services/sessions/session_service.dart';
import '../services/sessions/trae_migrator.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final result = await (widget.scanOverride?.call() ?? _service.scan());
    if (!mounted) return;
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
          onPressed: accountSelected == 0
              ? null
              : () => _migrateDialog(context, state),
          icon: const Icon(Icons.drive_file_move_rounded, size: 18),
          label: Text(
            accountSelected == 0
                ? '迁移到其他账号…'
                : '迁移 $accountSelected 条到账号…',
          ),
        ),
        if (traeSelected > 0)
          OutlinedButton.icon(
            onPressed: _packing ? null : () => _exportPack(context),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: Text(
              _packing ? '导出中…' : '导出 $traeSelected 条迁移包',
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
            '合并本机客户端里的会话：WorkBuddy 勾选后可迁移到另一个账号，Trae 可勾选导出迁移包',
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
            subtitle: '合并本机客户端里的会话：WorkBuddy 桌面端 / CLI 可迁移到另一个账号，Trae 可勾选导出迁移包',
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
            '迁移会写入目标账号的数据目录，建议先退出客户端再操作，重启客户端后生效。',
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

    return groups;
  }

  Future<void> _migrateDialog(BuildContext context, AppState state) async {
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
              const Text('选择目标账号（会复制一份，原账号保留）：'),
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
    if (target == null || !mounted) return;

    try {
      final count = await _service.copySessions(
        sessions: sessions,
        targetUid: target.externalId,
      );
      if (!context.mounted) return;
      setState(() {
        _selected.clear();
      });
      showAppSnackBar(
        context,
        count == 0 ? '没有可迁移的会话' : '已迁移 $count 条会话到 ${target.title}',
      );
      await _load();
    } catch (error) {
      if (!context.mounted) return;
      showAppSnackBar(context, '迁移失败：$error', error: true);
    }
  }

  /// 把选中的 Trae 会话导出成迁移包（明文 SQLite，只含这些会话）。
  Future<void> _exportPack(BuildContext context) async {
    final ids = _selectedSessions
        .where((session) => session.migratable)
        .map((session) => session.sessionId)
        .toSet();
    if (ids.isEmpty) return;
    setState(() => _packing = true);
    try {
      final result = await const TraeMigrator().pack(sessionIds: ids);
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

  /// 把迁移包里的新会话合并进本机 Trae 库（会自动备份并重新加密）。
  Future<void> _importPack(BuildContext context) async {
    final request = await showDialog<(String, bool)>(
      context: context,
      builder: (context) => const _ImportPackDialog(),
    );
    if (request == null || !context.mounted) return;
    final (path, dryRun) = request;
    setState(() => _merging = true);
    try {
      final result = await const TraeMigrator().merge(
        fromPath: path,
        dryRun: dryRun,
      );
      if (!context.mounted) return;
      await _showMergeReport(context, result);
      if (!result.dryRun) await _load();
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
                    style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
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
    final parts = <String>[
      'WorkBuddy 桌面端 ${scan.countOf(SessionSource.workbuddyDesktop)}',
      'CLI ${scan.countOf(SessionSource.workbuddyCli)}',
      'Trae ${scan.traeCount}',
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
        for (final option in const <PlatformKind?>[
          null,
          PlatformKind.workbuddy,
          PlatformKind.trae,
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
      title: const Text('导入 Trae 迁移包'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('迁移包路径（另一台机器导出的 trae-sessions-*.db）'),
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

