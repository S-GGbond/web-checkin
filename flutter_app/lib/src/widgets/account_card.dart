import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/account.dart';
import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// 账号卡片。所有操作通过回调上抛，便于在测试中直接渲染。
class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.account,
    required this.busy,
    required this.onCheckin,
    required this.onRefresh,
    required this.onSchedule,
    required this.onToggleEnabled,
    required this.onDelete,
    this.onSwitchDesktop,
    this.desktopActive = false,
  });

  final Account account;
  final bool busy;
  final VoidCallback onCheckin;
  final VoidCallback onRefresh;
  final VoidCallback onSchedule;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onDelete;

  /// 桌面端才有：把该账号的登录态写回本机客户端。移动端传 null，入口不渲染。
  final VoidCallback? onSwitchDesktop;

  /// 客户端当前是否登录的就是这个账号。
  final bool desktopActive;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final textTheme = Theme.of(context).textTheme;
    final usage = account.usage;
    final checkedIn = account.checkedInToday;

    final Color providerColor =
        account.provider == PlatformKind.trae ? palette.traeColor : palette.workbuddyColor;

    final statusPill = !account.enabled
        ? StatusPill(label: '已停用', color: palette.textSecondary, icon: Icons.pause_circle_outline_rounded)
        : checkedIn
            ? StatusPill(label: '今日已签到', color: palette.success, icon: Icons.task_alt_rounded)
            : account.lastCheckinOk == false
                ? StatusPill(label: '上次失败', color: palette.danger, icon: Icons.error_outline_rounded)
                : StatusPill(label: '待签到', color: palette.warning, icon: Icons.schedule_rounded);

    final switchable = onSwitchDesktop != null && !desktopActive && !busy;

    final card = SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      highlight: desktopActive || (checkedIn && account.enabled),
      onTap: switchable ? onSwitchDesktop : null,
      // 客户端当前登录的账号用绿色边框标出来，一眼能看出「现在用的是哪个」。
      borderColor: desktopActive ? palette.success : null,
      borderWidth: desktopActive ? 1.6 : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ProviderChip(provider: account.provider, dense: true),
                        if (account.label.isNotEmpty) ...[
                          const SizedBox(width: AppTokens.space2),
                          Flexible(
                            child: Text(
                              account.label,
                              style: TextStyle(color: palette.textSecondary, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                        if (desktopActive) ...[
                          const SizedBox(width: AppTokens.space2),
                          StatusPill(
                            label: '客户端',
                            color: palette.success,
                            icon: Icons.desktop_windows_rounded,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppTokens.space2),
                    Text(
                      account.title,
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTokens.space3),
              statusPill,
            ],
          ),
          const SizedBox(height: AppTokens.space4),
          Row(
            children: [
              UsageRing(
                progress: usage?.progress ?? 0,
                color: providerColor,
                size: 52,
                center: Text(
                  usage == null ? '—' : '${(usage.progress * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: AppTokens.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('剩余额度', style: TextStyle(color: palette.textSecondary, fontSize: 12)),
                    const SizedBox(height: 2),
                    Text(
                      usage == null ? '暂无数据' : '${usage.leftLabel} / ${usage.totalLabel}',
                      style: textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppTokens.space1),
                    Text(
                      _subtitle(),
                      style: TextStyle(color: palette.textSecondary, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space4),
          Row(
            children: [
              Expanded(
                child: checkedIn && account.enabled
                    ? OutlinedButton.icon(
                        onPressed: busy ? null : onCheckin,
                        icon: const Icon(Icons.refresh_rounded, size: 16),
                        label: const Text('再签到一次'),
                      )
                    : FilledButton.icon(
                        onPressed: busy || !account.enabled ? null : onCheckin,
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.check_circle_outline_rounded, size: 16),
                        label: const Text('立即签到'),
                      ),
              ),
              const SizedBox(width: AppTokens.space2),
              _IconAction(
                icon: Icons.sync_rounded,
                tooltip: '刷新状态',
                busy: busy,
                onPressed: onRefresh,
              ),
              _IconAction(
                icon: Icons.alarm_rounded,
                tooltip: '每日定时 ${account.scheduleTime}',
                active: account.scheduleEnabled,
                onPressed: onSchedule,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                icon: Icon(Icons.more_horiz_rounded, color: palette.textSecondary, size: 20),
                color: palette.surfaceElevated,
                onSelected: (value) {
                  switch (value) {
                    case 'switch':
                      onSwitchDesktop?.call();
                    case 'toggle':
                      onToggleEnabled(!account.enabled);
                    case 'delete':
                      _confirmDelete(context);
                  }
                },
                itemBuilder: (context) => [
                  if (onSwitchDesktop != null)
                    PopupMenuItem(
                      value: 'switch',
                      enabled: !desktopActive,
                      child: Row(
                        children: [
                          Icon(
                            desktopActive
                                ? Icons.check_circle_outline_rounded
                                : Icons.desktop_windows_rounded,
                            size: 16,
                            color: desktopActive ? palette.success : palette.textSecondary,
                          ),
                          const SizedBox(width: AppTokens.space2),
                          Text(desktopActive ? '客户端当前账号' : '切换到客户端'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(account.enabled ? '停用账号' : '启用账号'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除账号', style: TextStyle(color: palette.danger)),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    if (!switchable) return card;
    return Tooltip(
      message: '点击切换到「${account.title}」，会重启 ${account.provider.label} 客户端',
      waitDuration: const Duration(milliseconds: 600),
      child: card,
    );
  }

  String _subtitle() {
    final schedule = account.scheduleEnabled ? '定时 ${account.scheduleTime}' : '定时关闭';
    final last = account.lastCheckinAt == null
        ? '尚未签到'
        : '上次 ${DateFormat('MM-dd HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(account.lastCheckinAt! * 1000),
          )}';
    return '$schedule · $last';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final palette = AppTokensScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除「${account.title}」吗？本地登录态会一并移除，需要重新授权。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) onDelete();
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
    this.active = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool busy;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return IconButton(
      onPressed: busy ? null : onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(
        icon,
        size: 20,
        color: active ? palette.textSecondary : palette.outline,
      ),
    );
  }
}
