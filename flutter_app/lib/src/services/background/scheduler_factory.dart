import 'dart:io';

import 'android_alarm_scheduler.dart';
import 'background_scheduler.dart';
import 'desktop_schedulers.dart';

/// 按当前平台选择系统级后台定时的实现。
///
/// - Linux：systemd 用户定时器
/// - macOS：launchd LaunchAgent
/// - Windows：任务计划程序（schtasks）
/// - Android：AlarmManager 精确闹钟（休眠中也会被唤醒，可准点）
/// - iOS：系统不允许可靠的定时后台执行，只保留应用内的兜底调度
///
/// 桌面端统一走「由系统唤起应用自身可执行文件」的方式：进程起来后不显示窗口，
/// 跑完签到即退出，因此应用关闭后依然会执行。
BackgroundScheduler createBackgroundScheduler() {
  if (Platform.isLinux) return SystemdScheduler();
  if (Platform.isMacOS) return LaunchdScheduler();
  if (Platform.isWindows) return SchtasksScheduler();
  if (Platform.isAndroid) return AndroidAlarmScheduler();
  if (Platform.isIOS) {
    return UnsupportedScheduler(
      'iOS 不允许应用在指定时间可靠地后台唤醒（BGTaskScheduler 由系统决定时机）。'
      '请保持应用运行，或每天打开一次应用，启动时会自动补跑当天错过的签到。',
    );
  }
  return UnsupportedScheduler('当前平台没有可用的系统级定时机制');
}
