import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/account_actions.dart';
import '../widgets/app_widgets.dart';
import '../widgets/responsive.dart';
import '../widgets/activity_list.dart';

/// 概览：今日签到进度、关键指标、分平台账号与最近动态。
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.onNavigate});

  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);

    final total = state.totalAccounts;
    final done = state.checkedInToday;
    final hasAccounts = total > 0;

    return ListView(
      padding: const EdgeInsets.all(AppTokens.space5),
      children: [
        _HeroHeader(
          done: done,
          total: total,
          hasAccounts: hasAccounts,
          refreshing: state.refreshing,
          onCheckinAll: () => AccountActions.checkinAll(context),
          onRefreshAll: () => AccountActions.refreshAll(context),
        ),
        const SizedBox(height: AppTokens.space5),
        AdaptiveCardGrid(
          minItemWidth: 200,
          maxColumns: 4,
          children: [
            StatTile(
              label: '托管账号',
              value: '$total',
              icon: Icons.folder_copy_outlined,
              accent: palette.accent,
            ),
            StatTile(
              label: '已启用',
              value: '${state.enabledAccounts}',
              icon: Icons.toggle_on_outlined,
              accent: palette.accentAlt,
            ),
            StatTile(
              label: '今日已签到',
              value: '$done / $total',
              icon: Icons.task_alt_rounded,
              accent: palette.success,
            ),
            StatTile(
              label: '最近动态',
              value: '${state.logs.length}',
              icon: Icons.history_rounded,
              accent: palette.warning,
            ),
          ],
        ),
        if (!hasAccounts) ...[
          const SizedBox(height: AppTokens.space5),
          const _OnboardingCard(),
        ],
        const SizedBox(height: AppTokens.space6),
        for (final provider in PlatformKind.values) ...[
          _ProviderSection(provider: provider),
          const SizedBox(height: AppTokens.space6),
        ],
        SectionTitle(
          title: '最近动态',
          subtitle: '登录、状态刷新与签到都会记录在案',
          trailing: TextButton(
            onPressed: () => onNavigate(2),
            child: const Text('查看全部'),
          ),
        ),
        const SizedBox(height: AppTokens.space4),
        ActivityList(logs: state.logs.take(5).toList(), compact: true),
      ],
    );
  }
}

/// 无账号时的引导卡：概览保持完整结构，同时明确告诉用户下一步做什么。
class _OnboardingCard extends StatelessWidget {
  const _OnboardingCard();

  static const _steps = [
    (Icons.add_circle_outline_rounded, '添加账号', '用官方授权页登录 WorkBuddy 或 Trae。'),
    (Icons.alarm_on_outlined, '设定时间', '在账号卡片的「定时」里设置每天的签到时间。'),
    (Icons.verified_outlined, '自动签到', '到点自动签到，失败会自动重试，结果记录在动态中。'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.rocket_launch_rounded, size: 18, color: palette.accent),
                  const SizedBox(width: AppTokens.space3),
                  Expanded(
                    child: Text(
                      '还没有托管账号，先添加一个',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (!compact)
                    FilledButton.icon(
                      onPressed: () => AccountActions.showAddAccountSheet(context),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('添加账号'),
                    ),
                ],
              ),
              const SizedBox(height: AppTokens.space4),
              if (compact)
                Column(
                  children: [
                    for (final step in _steps) _OnboardingStep(step: step),
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final step in _steps)
                      Expanded(child: _OnboardingStep(step: step)),
                  ],
                ),
              if (compact) ...[
                const SizedBox(height: AppTokens.space4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => AccountActions.showAddAccountSheet(context),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('添加账号'),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _OnboardingStep extends StatelessWidget {
  const _OnboardingStep({required this.step});

  final (IconData, String, String) step;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.space4, bottom: AppTokens.space3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.space2),
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Icon(step.$1, size: 16, color: palette.accent),
          ),
          const SizedBox(width: AppTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.$2, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  step.$3,
                  style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.done,
    required this.total,
    required this.hasAccounts,
    required this.refreshing,
    required this.onCheckinAll,
    required this.onRefreshAll,
  });

  final int done;
  final int total;
  final bool hasAccounts;
  final bool refreshing;
  final VoidCallback onCheckinAll;
  final VoidCallback onRefreshAll;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final palette = AppTokensScope.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onHero = isDark ? const Color(0xFF0A0E1A) : Colors.white;
    final progress = total == 0 ? 0.0 : done / total;

    return GradientSurface(
      padding: const EdgeInsets.all(AppTokens.space5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${now.month} 月 ${now.day} 日 · 星期${_weekdays[now.weekday - 1]}',
                style: TextStyle(color: onHero.withValues(alpha: 0.75), fontSize: 13),
              ),
              const SizedBox(height: AppTokens.space2),
              Text(
                '签到中枢',
                style: TextStyle(
                  color: onHero,
                  fontSize: compact ? 26 : 32,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: AppTokens.space2),
              Text(
                total == 0
                    ? '添加账号后开始自动签到'
                    : (done == total ? '今日全部账号已完成签到' : '还有 ${total - done} 个账号待签到'),
                style: TextStyle(color: onHero.withValues(alpha: 0.85), fontSize: 14),
              ),
              const SizedBox(height: AppTokens.space5),
              WrapActions(
                alignment: WrapAlignment.start,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: onHero,
                      foregroundColor: palette.accent,
                    ),
                    onPressed: hasAccounts ? onCheckinAll : null,
                    icon: const Icon(Icons.done_all_rounded, size: 18),
                    label: const Text('全部签到'),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: onHero,
                      side: BorderSide(color: onHero.withValues(alpha: 0.5)),
                    ),
                    onPressed: (!hasAccounts || refreshing) ? null : onRefreshAll,
                    icon: refreshing
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: onHero),
                          )
                        : const Icon(Icons.sync_rounded, size: 18),
                    label: Text(refreshing ? '刷新中' : '刷新状态'),
                  ),
                ],
              ),
            ],
          );

          final ring = UsageRing(
            progress: progress,
            color: onHero,
            size: 108,
            center: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$done',
                  style: TextStyle(color: onHero, fontSize: 26, fontWeight: FontWeight.w800),
                ),
                Text(
                  '共 $total',
                  style: TextStyle(color: onHero.withValues(alpha: 0.8), fontSize: 11),
                ),
              ],
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                info,
                const SizedBox(height: AppTokens.space5),
                Align(alignment: Alignment.centerLeft, child: ring),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: info),
              const SizedBox(width: AppTokens.space5),
              ring,
            ],
          );
        },
      ),
    );
  }
}

class _ProviderSection extends StatelessWidget {
  const _ProviderSection({required this.provider});

  final PlatformKind provider;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final accounts = state.accounts.where((a) => a.provider == provider).toList();
    final color = provider == PlatformKind.trae ? palette.traeColor : palette.workbuddyColor;
    final icon = provider == PlatformKind.trae ? Icons.bolt_rounded : Icons.rocket_launch_rounded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: AppTokens.space3),
            Text(provider.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(width: AppTokens.space2),
            Text(
              '${accounts.length} 个账号',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => AccountActions.startLogin(context, provider),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        const SizedBox(height: AppTokens.space3),
        if (accounts.isEmpty)
          SurfaceCard(
            child: Row(
              children: [
                Icon(Icons.inbox_outlined, color: palette.textSecondary, size: 20),
                const SizedBox(width: AppTokens.space3),
                Expanded(
                  child: Text(
                    '暂无 ${provider.label} 账号',
                    style: TextStyle(color: palette.textSecondary, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else
          AdaptiveCardGrid(
            children: [
              for (final account in accounts) buildAccountCard(context, account),
            ],
          ),
      ],
    );
  }
}
