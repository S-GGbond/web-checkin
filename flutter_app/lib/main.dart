import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/background_entry.dart';
import 'src/services/background/android_alarm_scheduler.dart';

Future<void> main(List<String> args) async {
  // 系统调度器唤起的无界面运行：不启动界面，跑完当次任务直接退出。
  if (isBackgroundInvocation(args)) {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final result = await runBackgroundCheckin(
        accountId: backgroundAccountId(args),
      );
      stdout.writeln('[background-checkin] $result');
      exit(result.ok ? 0 : 1);
    } catch (error) {
      stderr.writeln('[background-checkin] 执行失败: $error');
      exit(1);
    }
  }

  // binding 必须建在同一个 zone 里，键盘事件回调才走得到 [_handleUncaught]。
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 键盘事件来自引擎回调，异常不走 zone 时由这里兜底。
    PlatformDispatcher.instance.onError = (error, stack) {
      if (_isLockKeyAssertion(error)) return true;
      return false;
    };
    // Android 需要先注册闹钟回调入口（其他平台为空操作）。
    await AndroidAlarmScheduler.ensureInitialized();
    runApp(const CheckinHubApp());
  }, _handleUncaught);
}

/// 兜底：忽略 Flutter 的「合成 Lock 键」断言，其它错误照常上报。
///
/// Windows 上窗口重新获得焦点时，引擎会补发 Num Lock / Caps Lock 的
/// **合成 KeyDown**；如果这两个键在失焦前就已经处于按下状态，框架会抛
/// `!_pressedKeys.containsKey(event.physicalKey)`。事件本身与应用无关，
/// 但异常会把这一次点击/按键一起吞掉，表现就是「点了没反应、控制台报错」。
void _handleUncaught(Object error, StackTrace stack) {
  if (_isLockKeyAssertion(error)) return;
  FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack));
}

bool _isLockKeyAssertion(Object error) =>
    error is AssertionError &&
    error.toString().contains('!_pressedKeys.containsKey');
