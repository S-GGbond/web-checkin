import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/checkin_log.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_list.dart';
import '../widgets/app_widgets.dart';

enum _LogFilter { all, workbuddy, trae, failed }

/// 动态：完整的执行日志，可按平台与结果筛选。
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  _LogFilter _filter = _LogFilter.all;

  List<CheckinLog> _apply(List<CheckinLog> logs) {
    switch (_filter) {
      case _LogFilter.all:
        return logs;
      case _LogFilter.workbuddy:
        return logs.where((l) => l.provider == PlatformKind.workbuddy).toList();
      case _LogFilter.trae:
        return logs.where((l) => l.provider == PlatformKind.trae).toList();
      case _LogFilter.failed:
        return logs.where((l) => !l.ok).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    final logs = _apply(state.logs);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTokens.space5,
            AppTokens.space5,
            AppTokens.space5,
            AppTokens.space3,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(
                title: '执行动态',
                subtitle: '登录、状态刷新、定时触发与签到结果',
                trailing: IconButton(
                  tooltip: '重新载入',
                  onPressed: () => state.reload(),
                  icon: Icon(Icons.refresh_rounded, size: 20, color: palette.textSecondary),
                ),
              ),
              const SizedBox(height: AppTokens.space4),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterChip(
                      label: '全部',
                      selected: _filter == _LogFilter.all,
                      onSelected: () => setState(() => _filter = _LogFilter.all),
                    ),
                    _FilterChip(
                      label: 'WorkBuddy',
                      selected: _filter == _LogFilter.workbuddy,
                      onSelected: () => setState(() => _filter = _LogFilter.workbuddy),
                    ),
                    _FilterChip(
                      label: 'Trae',
                      selected: _filter == _LogFilter.trae,
                      onSelected: () => setState(() => _filter = _LogFilter.trae),
                    ),
                    _FilterChip(
                      label: '仅失败',
                      selected: _filter == _LogFilter.failed,
                      onSelected: () => setState(() => _filter = _LogFilter.failed),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? const EmptyState(
                  icon: Icons.history_toggle_off_rounded,
                  title: '没有符合条件的记录',
                  message: '换个筛选条件，或先刷新一次账号状态。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppTokens.space5,
                    0,
                    AppTokens.space5,
                    AppTokens.space5,
                  ),
                  itemCount: logs.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppTokens.space2),
                  itemBuilder: (context, index) => ActivityList(logs: [logs[index]], compact: false),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = AppTokensScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: AppTokens.space2),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
        showCheckmark: false,
        backgroundColor: palette.surface,
        selectedColor: palette.accent.withValues(alpha: 0.18),
        side: BorderSide(color: selected ? palette.accent : palette.outline),
        labelStyle: TextStyle(
          color: selected ? palette.accent : palette.textSecondary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          fontSize: 12,
        ),
      ),
    );
  }
}
