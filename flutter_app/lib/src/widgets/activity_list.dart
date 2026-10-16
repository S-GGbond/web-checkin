import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/account.dart';
import '../models/checkin_log.dart';
import '../theme/app_theme.dart';
import 'app_widgets.dart';

/// 执行日志时间线。
class ActivityList extends StatelessWidget {
  const ActivityList({super.key, required this.logs, this.compact = false});

  final List<CheckinLog> logs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return SurfaceCard(
        child: Row(
          children: [
            const Icon(Icons.hourglass_empty_rounded, size: 18),
            const SizedBox(width: AppTokens.space3),
            Expanded(
              child: Text(
                '还没有执行记录',
                style: TextStyle(
                  color: AppTokensScope.of(context).textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < logs.length; i++) ...[
          _LogRow(log: logs[i], compact: compact),
          if (i != logs.length - 1) const SizedBox(height: AppTokens.space2),
        ],
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.log, required this.compact});

  final CheckinLog log;
  final bool compact;

  static const Map<String, (String, IconData)> _actions = {
    'login': ('登录', Icons.login_rounded),
    'status': ('状态刷新', Icons.sync_rounded),
    'checkin': ('签到', Icons.flag_rounded),
    'schedule': ('定时任务', Icons.alarm_rounded),
    'claim': ('签到', Icons.flag_rounded),
    'already': ('重复签到', Icons.task_alt_rounded),
    'skip': ('跳过', Icons.remove_circle_outline_rounded),
  };

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    final (label, icon) = _actions[log.action] ?? (log.action, Icons.circle_outlined);
    final color = log.ok ? palette.success : palette.danger;
    final providerColor = log.provider == PlatformKind.trae ? palette.traeColor : palette.workbuddyColor;

    return SurfaceCard(
      padding: EdgeInsets.symmetric(
        horizontal: AppTokens.space4,
        vertical: compact ? AppTokens.space3 : AppTokens.space4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppTokens.space2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: AppTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.accountTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppTokens.space1),
                Wrap(
                  spacing: AppTokens.space2,
                  runSpacing: AppTokens.space1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: providerColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(AppTokens.radiusPill),
                      ),
                      child: Text(
                        log.provider.label,
                        style: TextStyle(color: providerColor, fontSize: 10, fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text(
                      label,
                      style: TextStyle(color: palette.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  log.message,
                  style: TextStyle(
                    color: log.ok ? palette.textSecondary : palette.danger,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTokens.space3),
          Text(
            DateFormat('MM-dd HH:mm').format(
              DateTime.fromMillisecondsSinceEpoch(log.createdAt * 1000),
            ),
            style: TextStyle(color: palette.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
