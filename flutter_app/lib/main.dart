import 'dart:io';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/background_entry.dart';
import 'src/services/background/android_alarm_scheduler.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 系统调度器唤起的无界面运行：不启动界面，跑完当次任务直接退出。
  if (isBackgroundInvocation(args)) {
    try {
      final result = await runBackgroundCheckin(accountId: backgroundAccountId(args));
      stdout.writeln('[background-checkin] $result');
      exit(result.ok ? 0 : 1);
    } catch (error) {
      stderr.writeln('[background-checkin] 执行失败: $error');
      exit(1);
    }
  }

  // Android 需要先注册闹钟回调入口（其他平台为空操作）。
  await AndroidAlarmScheduler.ensureInitialized();

  runApp(const CheckinHubApp());
}
