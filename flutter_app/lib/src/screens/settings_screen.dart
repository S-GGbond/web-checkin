import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../services/account_export.dart';
import '../services/background/background_scheduler.dart';
import '../services/desktop/desktop_switch_service.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';

/// 设置：数据位置、维护操作与关于信息。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);

    return ListView(
      padding: const EdgeInsets.all(AppTokens.space5),
      children: [
        SectionTitle(title: '设置', subtitle: '数据位置、维护操作与平台说明'),
        const SizedBox(height: AppTokens.space5),
        _SettingsCard(
          title: '数据与登录态',
          children: [
            Text('账号库位置', style: TextStyle(color: palette.textSecondary, fontSize: 12)),
            const SizedBox(height: AppTokens.space2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppTokens.space3),
              decoration: BoxDecoration(
                color: palette.surfaceElevated,
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                border: Border.all(color: palette.outline),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      state.db.path,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制路径',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: state.db.path));
                      if (context.mounted) showAppSnackBar(context, '路径已复制');
                    },
                    icon: Icon(Icons.copy_rounded, size: 16, color: palette.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTokens.space4),
            _ActionRow(
              icon: Icons.file_upload_outlined,
              title: '导出账号（JSON）',
              subtitle: 'WorkBuddy / Trae 的账号与登录态，明文保存，请妥善保管',
              trailing: OutlinedButton(
                onPressed: () async {
                  try {
                    final result = await state.exportAccounts();
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('账号已导出'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${result.count} 个账号 · '
                              '${(result.sizeBytes / 1024).toStringAsFixed(0)} KB',
                            ),
                            const SizedBox(height: AppTokens.space2),
                            SelectableText(
                              result.path,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: AppTokens.space3),
                            const Text(
                              '文件包含明文登录态，请勿上传或分享给他人。',
                              style: TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: result.path),
                              );
                              if (context.mounted) {
                                showAppSnackBar(context, '路径已复制');
                              }
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
                  } catch (error) {
                    if (context.mounted) {
                      showAppSnackBar(context, '导出失败：$error', error: true);
                    }
                  }
                },
                child: const Text('导出'),
              ),
            ),
            _ActionRow(
              icon: Icons.file_download_outlined,
              title: '导入账号（JSON）',
              subtitle: '从 checkin-accounts-*.json 恢复账号与登录态，同 id 覆盖',
              trailing: OutlinedButton(
                onPressed: () async {
                  final path = await showDialog<String>(
                    context: context,
                    builder: (context) => const _PathDialog(
                      title: '导入账号（JSON）',
                      hint: '/home/user/checkin-accounts-20261020.json',
                      note: '同 provider + 账号 id 的账号会覆盖登录态；不会删除现有账号。',
                    ),
                  );
                  if (path == null || !context.mounted) return;
                  try {
                    final result = await state.importAccounts(path: path);
                    if (!context.mounted) return;
                    final detail = result.problems.isEmpty
                        ? ''
                        : '\n${result.problems.take(5).join('\n')}';
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('导入完成'),
                        content: Text(
                          '新增 ${result.added} 个，更新 ${result.updated} 个，'
                          '跳过 ${result.skipped} 个$detail',
                        ),
                        actions: [
                          FilledButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  } on AccountImportException catch (error) {
                    if (context.mounted) {
                      showAppSnackBar(context, error.message, error: true);
                    }
                  } catch (error) {
                    if (context.mounted) {
                      showAppSnackBar(context, '导入失败：$error', error: true);
                    }
                  }
                },
                child: const Text('导入'),
              ),
            ),
            const SizedBox(height: AppTokens.space4),
            _InfoLine(
              icon: Icons.lock_outline_rounded,
              text: 'Trae 登录态以 AES-128-CBC + SHA-512 容器加密存放；WorkBuddy 登录态按平台要求明文存放，请勿拷贝该数据库。',
            ),
            _InfoLine(
              icon: Icons.timer_outlined,
              text: '每日定时由操作系统调度，应用关闭后仍会执行；失败最多重试 3 次，'
                  '每次重试间隔 5 分钟。',
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space4),
        if (state.desktopSwitchSupported) ...[
          _DesktopSwitchCard(state: state),
          const SizedBox(height: AppTokens.space4),
        ],
        _BackgroundScheduleCard(state: state),
        const SizedBox(height: AppTokens.space4),
        _SettingsCard(
          title: '关于',
          children: [
            _ActionRow(
              icon: Icons.apps_rounded,
              title: '签到中枢',
              subtitle: 'Flutter 跨端客户端 · 版本 1.0.0',
              trailing: const SizedBox.shrink(),
            ),
            _ActionRow(
              icon: Icons.devices_rounded,
              title: '支持的平台',
              subtitle: PlatformKind.values.map((p) => p.label).join(' · '),
              trailing: const SizedBox.shrink(),
            ),
            _InfoLine(
              icon: Icons.info_outline_rounded,
              text: '本项目与 WorkBuddy、Trae 官方没有隶属关系，请仅管理你本人拥有授权的账号，并遵守各平台服务条款。',
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppTokens.space4),
          ...children,
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.accent),
          const SizedBox(width: AppTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: palette.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.space3),
          trailing,
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: palette.textSecondary),
          ),
          const SizedBox(width: AppTokens.space2),
          Expanded(
            child: Text(text, style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.5)),
          ),
        ],
      ),
    );
  }
}

/// 桌面客户端账号切换：展示探测到的登录态、主程序与当前账号。
///
/// 只在桌面平台渲染；移动端由调用方整块隐藏。
class _DesktopSwitchCard extends StatelessWidget {
  const _DesktopSwitchCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final byExternalId = {
      for (final account in state.accounts) '${account.provider.id}:${account.externalId}': account.title,
    };

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('客户端探测', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              OutlinedButton(
                onPressed: () => state.refreshDesktopClients(refreshExecutable: true),
                child: const Text('重新探测'),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space2),
          Text(
            '客户端当前登录的账号会在启动或「重新探测」时自动加入账号库；切换入口在「账号」页的 Trae / WorkBuddy 分组里。',
            style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: AppTokens.space4),
          for (final provider in PlatformKind.values) ...[
            _ClientStatusBlock(
              provider: provider,
              info: state.desktopClient(provider),
              activeName: state.desktopActiveId(provider) == null
                  ? null
                  : byExternalId['${provider.id}:${state.desktopActiveId(provider)}'],
            ),
            if (provider != PlatformKind.values.last) const SizedBox(height: AppTokens.space4),
          ],
          const SizedBox(height: AppTokens.space2),
          _InfoLine(
            icon: Icons.monitor_rounded,
            text: '切换入口只在 Windows / Linux / macOS 显示；手机端无法控制桌面客户端，因此不提供。'
                '每次写入前会先完全退出客户端并保留一份登录态备份。',
          ),
        ],
      ),
    );
  }
}

class _ClientStatusBlock extends StatelessWidget {
  const _ClientStatusBlock({required this.provider, required this.info, required this.activeName});

  final PlatformKind provider;
  final DesktopClientInfo? info;
  final String? activeName;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final ready = info?.canSwitch ?? false;
    final color = ready ? palette.success : palette.textSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ProviderChip(provider: provider, dense: true),
            const SizedBox(width: AppTokens.space2),
            Expanded(
              child: Text(
                activeName == null ? '客户端未登录 / 未检测到' : '客户端当前：$activeName',
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            StatusPill(
              label: info?.summary ?? '未检测',
              color: color,
              icon: ready ? Icons.verified_rounded : Icons.link_off_rounded,
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space2),
        Text(
          info?.authFile ?? '未找到登录态文件，请先启动客户端完成一次登录',
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          '主程序：${info?.executableName ?? '未找到'}',
          style: TextStyle(color: palette.textSecondary, fontSize: 11),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 系统级后台定时：展示机制、限制与已注册的账号。
class _BackgroundScheduleCard extends StatelessWidget {
  const _BackgroundScheduleCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final BackgroundSchedulerStatus info = state.backgroundStatus;
    final accountsById = {for (final account in state.accounts) account.id: account};

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('系统级后台定时', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (state.backgroundSyncing)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else
                StatusPill(
                  label: info.available ? '${info.installedCount} 个已注册' : '不可用',
                  color: info.available ? palette.success : palette.textSecondary,
                  icon: info.available ? Icons.verified_rounded : Icons.block_rounded,
                ),
            ],
          ),
          const SizedBox(height: AppTokens.space2),
          Text(
            info.mechanism,
            style: TextStyle(color: palette.accent, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppTokens.space3),
          if (info.note != null)
            _InfoLine(icon: Icons.info_outline_rounded, text: info.note!),
          if (info.lastError != null)
            _InfoLine(icon: Icons.error_outline_rounded, text: '最近一次同步失败：${info.lastError}'),
          if (state.needsExactAlarmPermission)
            _InfoLine(
              icon: Icons.alarm_on_rounded,
              text: '尚未授予「闹钟和提醒」权限：当前只能用非精确闹钟，系统可能推迟执行。'
                  '点右侧按钮去系统设置里开启，回来后会自动重新同步。',
            ),
          const SizedBox(height: AppTokens.space3),
          if (info.installed.isEmpty)
            Text(
              '尚未注册系统任务。开启某个账号的「定时」后会自动注册在这里。',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            )
          else
            for (final entry in info.installed.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTokens.space2),
                child: Row(
                  children: [
                    Icon(Icons.event_available_rounded, size: 15, color: palette.success),
                    const SizedBox(width: AppTokens.space2),
                    Expanded(
                      child: Text(
                        accountsById[entry.key]?.title ?? '账号 #${entry.key}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '每日 ${entry.value}',
                      style: TextStyle(color: palette.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: AppTokens.space3),
          Text(
            '可执行文件：${info.executablePath}',
            style: TextStyle(color: palette.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: AppTokens.space4),
          WrapActions(
            alignment: WrapAlignment.start,
            children: [
              if (state.needsExactAlarmPermission)
                FilledButton.icon(
                  onPressed: () => state.openExactAlarmSettings(),
                  icon: const Icon(Icons.alarm_add_rounded, size: 18),
                  label: const Text('去开启精确闹钟'),
                ),
              OutlinedButton.icon(
                onPressed: state.backgroundSyncing
                    ? null
                    : () async {
                        final error = await state.syncBackgroundSchedule();
                        if (!context.mounted) return;
                        showAppSnackBar(context, error ?? '已同步到系统计划任务', error: error != null);
                      },
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('立即同步'),
              ),
              OutlinedButton.icon(
                onPressed: info.installed.isEmpty
                    ? null
                    : () async {
                        final error = await state.uninstallBackgroundSchedule();
                        if (!context.mounted) return;
                        showAppSnackBar(context, error ?? '已从系统移除全部定时任务', error: error != null);
                      },
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('从系统移除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


/// 让用户填一个本地文件路径。
class _PathDialog extends StatefulWidget {
  const _PathDialog({required this.title, required this.hint, this.note});

  final String title;
  final String hint;
  final String? note;

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(hintText: widget.hint, isDense: true),
            ),
            if (widget.note != null) ...[
              const SizedBox(height: AppTokens.space2),
              Text(
                widget.note!,
                style: TextStyle(
                  fontSize: 11,
                  color: palette.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
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
            Navigator.pop(context, path);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
