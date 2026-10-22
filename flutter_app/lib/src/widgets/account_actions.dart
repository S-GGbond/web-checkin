import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'account_card.dart';
import 'app_widgets.dart';
import 'login_dialog.dart';
import 'schedule_dialog.dart';

/// 账号相关操作的统一入口，供多个页面复用，避免重复弹窗逻辑。
class AccountActions {
  AccountActions._();

  static Future<void> checkin(BuildContext context, Account account) async {
    final state = context.read<AppState>();
    final error = await state.checkinAccount(account.id);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      error ?? '${account.title} 签到成功',
      error: error != null,
    );
  }

  static Future<void> refresh(BuildContext context, Account account) async {
    final state = context.read<AppState>();
    final error = await state.refreshAccount(account.id);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      error ?? '${account.title} 状态已更新',
      error: error != null,
    );
  }

  static Future<void> schedule(BuildContext context, Account account) async {
    final state = context.read<AppState>();
    final result = await ScheduleDialog.show(
      context,
      title: account.title,
      enabled: account.scheduleEnabled,
      time: account.scheduleTime,
    );
    if (result == null) return;
    await state.setSchedule(account.id, enabled: result.$1, time: result.$2);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      result.$1 ? '已设置每日 ${result.$2} 自动签到' : '已关闭每日定时',
    );
  }

  static Future<void> toggleEnabled(BuildContext context, Account account, bool enabled) async {
    final state = context.read<AppState>();
    await state.setEnabled(account.id, enabled);
    if (!context.mounted) return;
    showAppSnackBar(context, enabled ? '已启用 ${account.title}' : '已停用 ${account.title}');
  }

  static Future<void> delete(BuildContext context, Account account) async {
    final state = context.read<AppState>();
    await state.deleteAccount(account.id);
    if (!context.mounted) return;
    showAppSnackBar(context, '已删除 ${account.title}');
  }

  /// 桌面端：把该账号的登录态写回本机客户端，并重启客户端。
  ///
  /// 点击即执行（不再二次确认）；客户端会被强制退出，写入前自动备份。
  /// 移动端不会走到这里（调用方按平台隐藏入口）。
  static Future<void> switchDesktop(BuildContext context, Account account) async {
    final state = context.read<AppState>();
    if (state.isDesktopActive(account)) {
      showAppSnackBar(context, '${account.provider.label} 客户端当前已是 ${account.title}');
      return;
    }
    final result = await state.switchDesktopAccount(account.id);
    if (!context.mounted) return;
    showAppSnackBar(context, result.message, error: !result.ok);
  }

  static Future<void> startLogin(BuildContext context, PlatformKind provider) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final session = await state.startLogin(provider);
      if (!context.mounted) return;
      if (!session.isTerminal) {
        await LoginDialog.show(context, session);
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('启动登录失败：$error')),
      );
    }
  }

  static Future<void> checkinAll(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.checkinAllEnabled();
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? '全部账号签到完成')),
    );
  }

  static Future<void> refreshAll(BuildContext context) async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    await state.refreshAll(force: true);
    messenger.showSnackBar(const SnackBar(content: Text('已刷新所有账号状态')));
  }

  /// 打开「添加账号」选择面板。
  static Future<void> showAddAccountSheet(BuildContext context) async {
    final palette = AppTokensScope.of(context);
    final provider = await showModalBottomSheet<PlatformKind>(
      context: context,
      backgroundColor: palette.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppTokens.radiusLg)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('添加账号', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppTokens.space1),
              Text(
                '通过官方授权页登录，登录态仅保存在本机账号库。',
                style: TextStyle(color: palette.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: AppTokens.space4),
              _ProviderTile(
                provider: PlatformKind.workbuddy,
                description: '浏览器授权 + 轮询领取登录态',
              ),
              const SizedBox(height: AppTokens.space2),
              _ProviderTile(
                provider: PlatformKind.trae,
                description: 'PKCE 授权，本地回环回调接收授权码',
              ),
              const SizedBox(height: AppTokens.space2),
              _ProviderTile(
                provider: PlatformKind.qoder,
                description: '设备码登录，浏览器确认后自动入库',
              ),
              const SizedBox(height: AppTokens.space2),
            ],
          ),
        ),
      ),
    );
    if (provider != null && context.mounted) {
      await startLogin(context, provider);
    }
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.provider, required this.description});

  final PlatformKind provider;
  final String description;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final color = palette.colorOf(provider);
    final icon = providerIcon(provider);
    return Material(
      color: palette.surfaceElevated,
      borderRadius: BorderRadius.circular(AppTokens.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.radiusMd),
        onTap: () => Navigator.pop(context, provider),
        child: Container(
          padding: const EdgeInsets.all(AppTokens.space4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTokens.radiusMd),
            border: Border.all(color: palette.outline),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppTokens.space3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: AppTokens.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(provider.label, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(description, style: TextStyle(color: palette.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// 首页/账号页共享的账号卡片构造，把操作回调接上。
Widget buildAccountCard(BuildContext context, Account account) {
  final state = context.watch<AppState>();
  return AccountCard(
    account: account,
    busy: state.isBusy(account.id),
    onCheckin: () => AccountActions.checkin(context, account),
    onRefresh: () => AccountActions.refresh(context, account),
    onSchedule: () => AccountActions.schedule(context, account),
    onToggleEnabled: (value) => AccountActions.toggleEnabled(context, account, value),
    onDelete: () => AccountActions.delete(context, account),
  );
}
