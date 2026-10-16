import 'dart:async';
import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';

import '../../background_entry.dart';
import '../../data/app_database.dart';
import 'android_permissions.dart';
import 'background_scheduler.dart';
import 'schedule_manifest.dart';

/// 每天重试的间隔（与桌面端一致）。
const Duration androidAlarmRetryDelay = Duration(seconds: 300);

/// 用 `AlarmManager` 的精确闹钟（`setExactAndAllowWhileIdle`）在指定时间唤起
/// 应用的后台 isolate，设备休眠时也会被唤醒，因此能准点签到。
///
/// Android 14 起 `SCHEDULE_EXACT_ALARM` 默认被拒绝：未授权时自动退化为非精确
/// 闹钟（仍能执行，只是可能被系统推迟），并在界面上引导用户去开启。
class AndroidAlarmScheduler implements BackgroundScheduler {
  AndroidAlarmScheduler({ScheduleManifest? manifest})
      : _manifest = manifest ?? const ScheduleManifest();

  final ScheduleManifest _manifest;

  /// 每个账号占 100 个 id：0 表示每日闹钟，1..2 表示当天的重试。
  static int dailyAlarmId(int accountId) => accountId * 100;

  static int retryAlarmId(int accountId, int attempt) => accountId * 100 + attempt;

  static const int _maxRetryAttempt = 2;

  BackgroundSchedulerStatus _status = const BackgroundSchedulerStatus(
    mechanism: 'Android 精确闹钟（AlarmManager）',
    available: true,
    executablePath: 'Android 后台 isolate',
    note: '由系统闹钟在设定时间精确唤醒（休眠中也会唤醒），应用被杀后依然有效，'
        '重启后自动恢复。需要「闹钟和提醒」权限；未授权时会退化为非精确闹钟。',
  );

  /// 应用启动时注册后台回调入口。
  static Future<void> ensureInitialized() async {
    if (!Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.initialize();
    } catch (_) {
      // 初始化失败不影响前台功能。
    }
  }

  static DateTime nextOccurrence(String time, DateTime now) {
    final (hour, minute) = parseBackgroundTime(time);
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  }

  static Future<void> _scheduleAt({
    required int accountId,
    required int alarmId,
    required DateTime at,
    required int attempt,
  }) async {
    // 权限缺失时 setExact 会抛异常，这里主动退化为非精确闹钟。
    final exact = await AndroidPermissions.canScheduleExactAlarms();
    await AndroidAlarmManager.oneShotAt(
      at,
      alarmId,
      androidAlarmCallback,
      exact: exact,
      wakeup: true,
      allowWhileIdle: true,
      rescheduleOnReboot: true,
      params: {'accountId': accountId, 'attempt': attempt},
    );
  }

  /// 排下一次「每日」闹钟（后台回调与前台同步都会调用）。
  static Future<void> rescheduleForAccount(int accountId) async {
    try {
      final db = await AppDatabase.open();
      try {
        final row = await db.getAccountRow(accountId);
        final usable = row != null &&
            (row['enabled'] as int? ?? 1) == 1 &&
            (row['schedule_enabled'] as int? ?? 1) == 1;
        if (!usable) {
          await cancelAccount(accountId);
          return;
        }
        final time = (row['schedule_time'] as String?) ?? '09:00';
        await _scheduleAt(
          accountId: accountId,
          alarmId: dailyAlarmId(accountId),
          at: nextOccurrence(time, DateTime.now()),
          attempt: 0,
        );
      } finally {
        await db.close();
      }
    } catch (_) {
      // 后台环境异常时不要抛出，避免系统判定任务失败后反复重试。
    }
  }

  /// 失败后另排一次重试闹钟。
  static Future<void> scheduleRetry(int accountId, int attempt) async {
    if (attempt > _maxRetryAttempt) return;
    await _scheduleAt(
      accountId: accountId,
      alarmId: retryAlarmId(accountId, attempt),
      at: DateTime.now().add(androidAlarmRetryDelay),
      attempt: attempt,
    );
  }

  static Future<void> cancelAccount(int accountId) async {
    for (var attempt = 0; attempt <= _maxRetryAttempt; attempt++) {
      await AndroidAlarmManager.cancel(
        attempt == 0 ? dailyAlarmId(accountId) : retryAlarmId(accountId, attempt),
      );
    }
  }

  @override
  BackgroundSchedulerStatus get status => _status;

  @override
  Future<BackgroundSchedulerStatus> refresh() async {
    final entries = await _manifest.read();
    final exact = await AndroidPermissions.canScheduleExactAlarms();
    _status = BackgroundSchedulerStatus(
      mechanism: _status.mechanism,
      available: true,
      executablePath: _status.executablePath,
      note: exact
          ? _status.note
          : '尚未授予「闹钟和提醒」权限，目前退化为非精确闹钟（系统可能推迟执行）。'
              '点击下方按钮去系统设置里开启。',
      installed: {for (final entry in entries) entry.accountId: entry.time},
    );
    return _status;
  }

  @override
  Future<String?> sync(List<BackgroundTarget> targets) async {
    try {
      final previous = await _manifest.read();
      final desired = {for (final target in targets) target.accountId: target};

      for (final entry in previous) {
        if (!desired.containsKey(entry.accountId)) {
          await cancelAccount(entry.accountId);
        }
      }
      for (final target in desired.values) {
        await cancelAccount(target.accountId);
        await _scheduleAt(
          accountId: target.accountId,
          alarmId: dailyAlarmId(target.accountId),
          at: nextOccurrence(target.time, DateTime.now()),
          attempt: 0,
        );
      }

      await _manifest.write([
        for (final target in desired.values)
          ScheduleEntry(accountId: target.accountId, time: target.time, label: target.label),
      ]);

      _status = BackgroundSchedulerStatus(
        mechanism: _status.mechanism,
        available: true,
        executablePath: _status.executablePath,
        note: _status.note,
        installed: {for (final target in desired.values) target.accountId: target.time},
      );
      return null;
    } catch (error) {
      _status = BackgroundSchedulerStatus(
        mechanism: _status.mechanism,
        available: true,
        executablePath: _status.executablePath,
        note: _status.note,
        installed: _status.installed,
        lastError: error.toString(),
      );
      return error.toString();
    }
  }

  @override
  Future<String?> uninstallAll() async {
    try {
      for (final entry in await _manifest.read()) {
        await cancelAccount(entry.accountId);
      }
      await _manifest.write(const []);
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  @override
  void dispose() {}
}

/// 闹钟回调入口。必须是顶层函数并标注 vm:entry-point，
/// 否则 release 构建下找不到入口。
@pragma('vm:entry-point')
void androidAlarmCallback(int alarmId, Map<String, dynamic> params) async {
  final raw = params['accountId'];
  final accountId = raw is int ? raw : int.tryParse('${raw ?? ''}');
  if (accountId == null) return;
  final attempt = (params['attempt'] as num?)?.toInt() ?? 0;
  final isDaily = alarmId == AndroidAlarmScheduler.dailyAlarmId(accountId);

  final result = await runBackgroundCheckin(
    accountId: accountId,
    // 后台 isolate 时间有限：一次唤醒只尝试一次，失败另排闹钟重试。
    maxAttempts: 1,
    lockOnExhausted: false,
  );

  // 每日闹钟负责把下一天排上；重试闹钟不重复排。
  if (isDaily) {
    await AndroidAlarmScheduler.rescheduleForAccount(accountId);
  }
  if (result.failed > 0) {
    await AndroidAlarmScheduler.scheduleRetry(accountId, attempt + 1);
  }
}
