import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/activity_list.dart';

/// 定时任务：每个账号的定时、下次触发、上次结果与最近执行记录。
class SchedulesScreen extends StatelessWidget {
  const SchedulesScreen({super.key});

  static const _scheduleActions = {'checkin', 'claim', 'already', 'skip', 'schedule'};

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final scheduled = state.accounts.where((a) => a.scheduleEnabled).toList()
      ..sort((a, b) => a.scheduleTime.compareTo(b.scheduleTime));
    final executed = state.logs
        .where((log) => _scheduleActions.contains(log.action))
        .take(30)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('定时任务')),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.space5),
        children: [
          SurfaceCard(
            padding: const EdgeInsets.all(AppTokens.space4),
            child: Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: '已启用',
                    value: '${scheduled.length}',
                    icon: Icons.alarm_on_rounded,
                    color: palette.accent,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '今日已签到',
                    value: '${state.accounts.where((a) => a.checkedInToday).length}',
                    icon: Icons.check_circle_outline_rounded,
                    color: palette.success,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '系统已注册',
                    value: '${state.backgroundStatus.installedCount}',
                    icon: Icons.event_available_rounded,
                    color: palette.traeColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTokens.space5),
          SectionTitle(
            title: '按账号',
            subtitle: '定时到点后由系统计划任务触发，应用没打开也会执行',
          ),
          const SizedBox(height: AppTokens.space3),
          if (scheduled.isEmpty)
            EmptyState(
              icon: Icons.alarm_off_rounded,
              title: '还没有启用定时任务',
              message: '在账号卡片的「定时」里选择每天的执行时间，开启后会出现在这里。',
            )
          else
            for (final account in scheduled) ...[
              _ScheduleCard(account: account),
              const SizedBox(height: AppTokens.space3),
            ],
          const SizedBox(height: AppTokens.space3),
          SectionTitle(
            title: '最近执行记录',
            subtitle: '签到 / 定时任务的执行结果，最多 30 条',
          ),
          const SizedBox(height: AppTokens.space3),
          ActivityList(logs: executed),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(height: AppTokens.space2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: TextStyle(color: palette.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.account});

  final Account account;

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// (今天|明天) HH:mm
  static String nextRun(String time, DateTime now) {
    final parts = time.split(':');
    final hour = parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    final sameDay =
        next.year == now.year && next.month == now.month && next.day == now.day;
    return '${sameDay ? '今天' : '明天'} ${_two(hour)}:${_two(minute)}';
  }

  static String? _formatAt(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    return DateFormat('MM-dd HH:mm').format(
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final color = palette.colorOf(account.provider);
    final last = _formatAt(account.lastCheckinAt);
    final ok = account.lastCheckinOk;

    return SurfaceCard(
      padding: const EdgeInsets.all(AppTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  account.title,
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              StatusPill(
                label: account.checkedInToday ? '今日已签到' : '未签到',
                color: account.checkedInToday ? palette.success : palette.textSecondary,
                icon: account.checkedInToday
                    ? Icons.verified_rounded
                    : Icons.schedule_rounded,
              ),
            ],
          ),
          const SizedBox(height: AppTokens.space3),
          _Line(
            icon: Icons.alarm_rounded,
            label: '每日 ${account.scheduleTime}',
            color: color,
          ),
          _Line(
            icon: Icons.update_rounded,
            label: '下次 ${nextRun(account.scheduleTime, DateTime.now())}',
            color: palette.textSecondary,
          ),
          if (last != null)
            _Line(
              icon: ok == false
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              label:
                  '上次 $last${ok == null ? '' : (ok ? ' · 成功' : ' · 失败')}',
              color: ok == false ? palette.danger : palette.success,
            )
          else
            _Line(
              icon: Icons.history_rounded,
              label: '还没有执行记录',
              color: palette.textSecondary,
            ),
          if ((account.lastCheckinMessage ?? '').isNotEmpty) ...[
            const SizedBox(height: AppTokens.space2),
            Text(
              account.lastCheckinMessage!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textSecondary, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.space2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: AppTokens.space2),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
