import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/activity_list.dart';

/// 全部执行动态：首页只展示最近几条，这里给出完整列表。
class ActivityScreen extends StatelessWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final palette = AppTokensScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('全部动态')),
      body: ListView(
        padding: const EdgeInsets.all(AppTokens.space5),
        children: [
          Text(
            '最近 ${state.logs.length} 条记录：登录、状态刷新、签到与定时任务的执行结果',
            style: TextStyle(
              color: palette.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppTokens.space4),
          ActivityList(logs: state.logs),
        ],
      ),
    );
  }
}
