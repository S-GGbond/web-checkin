import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/account_actions.dart';
import '../widgets/account_card.dart';
import '../widgets/app_widgets.dart';
import '../widgets/client_status_line.dart';
import '../widgets/responsive.dart';

/// 托管账号：按平台分组管理每个账号的签到、定时与启停。
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);

    return ListView(
      padding: const EdgeInsets.all(AppTokens.space5),
      children: [
        SectionTitle(
          title: '托管账号',
          subtitle: state.desktopSwitchSupported
              ? '每个账号有独立的每日签到时间；Trae / WorkBuddy 分组标题里可直接切换客户端登录态'
              : '每个账号都有独立的每日签到时间，可在卡片上的「定时」中设置',
          trailing: WrapActions(
            children: [
              OutlinedButton.icon(
                onPressed: state.refreshing ? null : () => AccountActions.refreshAll(context),
                icon: const Icon(Icons.sync_rounded, size: 16),
                label: const Text('刷新状态'),
              ),
              FilledButton.icon(
                onPressed: () => AccountActions.showAddAccountSheet(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加账号'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTokens.space5),
        if (state.accounts.isEmpty)
          EmptyState(
            icon: Icons.folder_open_outlined,
            title: '还没有托管账号',
            message: '通过官方授权添加 WorkBuddy 或 Trae 账号。',
            action: FilledButton.icon(
              onPressed: () => AccountActions.showAddAccountSheet(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加账号'),
            ),
          )
        else
          for (final provider in PlatformKind.values)
            if (state.accounts.any((account) => account.provider == provider)) ...[
              _GroupHeader(provider: provider),
              const SizedBox(height: AppTokens.space3),
              _GroupBody(provider: provider),
              const SizedBox(height: AppTokens.space6),
            ],
        if (state.accounts.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => AccountActions.checkinAll(context),
                  icon: const Icon(Icons.done_all_rounded, size: 18),
                  label: const Text('全部账号立即签到'),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppTokens.space4),
        Text(
          '登录态只保存在本机账号库中；每日定时已注册到系统计划任务，应用关闭后依然有效。',
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.provider});

  final PlatformKind provider;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final count = state.accounts.where((a) => a.provider == provider).length;
    final color = palette.colorOf(provider);
    final info = state.desktopClient(provider);
    // 客户端登录态与账号列表放在同一个分组里；平台不支持换号时整块隐藏。
    final showSwitcher = state.desktopClientSupported(provider) && count > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: AppTokens.space2),
            Text(provider.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: AppTokens.space2),
            Text('$count', style: TextStyle(color: palette.textSecondary, fontSize: 12)),
            if (showSwitcher) ...[
              const Spacer(),
              StatusPill(
                label: info?.summary ?? '检测中',
                color: (info?.canSwitch ?? false) ? palette.success : palette.textSecondary,
                icon: (info?.canSwitch ?? false) ? Icons.link_rounded : Icons.link_off_rounded,
              ),
            ],
          ],
        ),
        if (showSwitcher)
          Padding(
            padding: const EdgeInsets.only(left: AppTokens.space4, top: AppTokens.space2),
            child: ClientStatusLine(provider: provider),
          ),
      ],
    );
  }
}

class _GroupBody extends StatelessWidget {
  const _GroupBody({required this.provider});

  final PlatformKind provider;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final accounts = state.accounts.where((a) => a.provider == provider).toList();
    final canSwitchClient = state.canSwitchClient(provider);
    if (accounts.isEmpty) {
      return SurfaceCard(
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, color: palette.textSecondary, size: 18),
            const SizedBox(width: AppTokens.space3),
            Expanded(
              child: Text(
                '暂无 ${provider.label} 账号',
                style: TextStyle(color: palette.textSecondary, fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => AccountActions.startLogin(context, provider),
              child: const Text('添加'),
            ),
          ],
        ),
      );
    }
    return AdaptiveCardGrid(
      children: [
        for (final account in accounts)
          AccountCard(
            account: account,
            busy: state.isBusy(account.id),
            onCheckin: () => AccountActions.checkin(context, account),
            onRefresh: () => AccountActions.refresh(context, account),
            onSchedule: () => AccountActions.schedule(context, account),
            onToggleEnabled: (value) => AccountActions.toggleEnabled(context, account, value),
            onDelete: () => AccountActions.delete(context, account),
            onSwitchDesktop: canSwitchClient
                ? () => AccountActions.switchDesktop(context, account)
                : null,
            desktopActive: state.isDesktopActive(account),
          ),
      ],
    );
  }
}
