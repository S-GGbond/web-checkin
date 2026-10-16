import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 每日定时设置对话框。
class ScheduleDialog extends StatefulWidget {
  const ScheduleDialog({
    super.key,
    required this.title,
    required this.enabled,
    required this.time,
  });

  final String title;
  final bool enabled;
  final String time;

  /// 返回 (enabled, "HH:MM")，取消时返回 null。
  static Future<(bool, String)?> show(
    BuildContext context, {
    required String title,
    required bool enabled,
    required String time,
  }) {
    return showDialog<(bool, String)>(
      context: context,
      builder: (_) => ScheduleDialog(title: title, enabled: enabled, time: time),
    );
  }

  @override
  State<ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<ScheduleDialog> {
  late bool _enabled = widget.enabled;
  late TimeOfDay _time = _parse(widget.time);

  static TimeOfDay _parse(String value) {
    final parts = value.split(':');
    final hour = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 9;
    final minute = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  String get _formatted =>
      '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return AlertDialog(
      title: const Text('每日定时签到'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: TextStyle(color: palette.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: AppTokens.space4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
              title: const Text('开启每日定时'),
              subtitle: Text(
                '注册到系统计划任务，应用关闭后仍会在设定时间自动签到',
                style: TextStyle(color: palette.textSecondary, fontSize: 12),
              ),
            ),
            const SizedBox(height: AppTokens.space2),
            InkWell(
              onTap: !_enabled
                  ? null
                  : () async {
                      final picked = await showTimePicker(context: context, initialTime: _time);
                      if (picked != null) setState(() => _time = picked);
                    },
              borderRadius: BorderRadius.circular(AppTokens.radiusSm),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTokens.space4,
                  vertical: AppTokens.space3,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceElevated,
                  borderRadius: BorderRadius.circular(AppTokens.radiusSm),
                  border: Border.all(color: palette.outline),
                ),
                child: Row(
                  children: [
                    Icon(Icons.alarm_rounded, size: 18, color: palette.accent),
                    const SizedBox(width: AppTokens.space3),
                    Text('签到时间', style: TextStyle(color: palette.textSecondary, fontSize: 13)),
                    const Spacer(),
                    Text(
                      _formatted,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: _enabled ? palette.textPrimary : palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_enabled, _formatted)),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
