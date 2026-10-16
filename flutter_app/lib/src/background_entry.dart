import 'dart:async';
import 'dart:io';

import 'data/app_database.dart';
import 'models/account.dart';
import 'services/checkin_runner.dart';
import 'services/scheduler.dart';

/// 无界面后台签到入口。
///
/// 由操作系统的调度器（systemd / launchd / schtasks / WorkManager）以
/// 「应用自身 + 环境变量」的方式唤起，因此不需要额外的可执行文件：
/// 进程起来后不显示窗口，跑完当次任务直接退出。
const String backgroundEnvKey = 'CHECKIN_HUB_BACKGROUND';
const String backgroundArgFlag = '--background-checkin';
const String backgroundAccountEnvKey = 'CHECKIN_HUB_ACCOUNT';

/// 是否为后台调度唤起。
bool isBackgroundInvocation(List<String> args) =>
    Platform.environment[backgroundEnvKey] != null || args.contains(backgroundArgFlag);

/// 解析本次要处理的账号 ID。为空表示「处理所有到点账号」。
int? backgroundAccountId(List<String> args) {
  final fromEnv = Platform.environment[backgroundAccountEnvKey];
  final parsedFromEnv = fromEnv == null ? null : int.tryParse(fromEnv);
  if (parsedFromEnv != null) return parsedFromEnv;

  final index = args.indexOf('--account');
  if (index >= 0 && index + 1 < args.length) {
    return int.tryParse(args[index + 1]);
  }
  return null;
}

/// 后台唤醒的执行结果。
class BackgroundRunResult {
  const BackgroundRunResult({
    required this.attempted,
    required this.succeeded,
    required this.failed,
    this.skippedReason,
  });

  final int attempted;
  final int succeeded;
  final int failed;
  final String? skippedReason;

  bool get ok => failed == 0;

  @override
  String toString() =>
      'attempted=$attempted succeeded=$succeeded failed=$failed${skippedReason == null ? '' : ' skipped=$skippedReason'}';
}

/// 跑一次后台签到：只处理「已到点且当日未完成」的账号。
///
/// 重试策略与应用内调度器一致：最多 [maxAttempts] 次，每次间隔 [retryDelay]。
/// 这里的重试是在同一进程内等待完成，因为操作系统只会唤起一次。
///
/// [lockOnExhausted] 为 true 时，重试耗尽后会写入当日完成标记，避免系统调度器
/// 反复唤醒（桌面端由 systemd / 计划任务驱动，一次唤醒跑完为止）。
/// Android 的 WorkManager 受后台执行时长限制，改为单次尝试 + 自行排下一次重试，
/// 因此传 false，让重试任务仍能被选中。
Future<BackgroundRunResult> runBackgroundCheckin({
  int? accountId,
  int maxAttempts = 3,
  Duration retryDelay = const Duration(seconds: 300),
  DateTime? now,
  bool lockOnExhausted = true,
  AppDatabase? database,
}) async {
  AppDatabase? db;
  var owned = false;
  try {
    if (database != null) {
      db = database;
    } else {
      db = await AppDatabase.open();
      owned = true;
    }
    final runner = CheckinRunner(db);
    final due = await runner.dueAccounts(accountId: accountId, now: now);
    if (due.isEmpty) {
      return const BackgroundRunResult(
        attempted: 0,
        succeeded: 0,
        failed: 0,
        skippedReason: '当日无待执行任务',
      );
    }

    final today = CheckinRunner.todayKey(now ?? DateTime.now());
    var succeeded = 0;
    var failed = 0;

    for (final row in due) {
      final accountIdValue = row['id'] as int;
      var done = false;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        await runner.logSchedule(
          row,
          ok: true,
          message: '系统后台任务触发（第 $attempt/$maxAttempts 次），计划时间 ${row['schedule_time']}',
        );
        try {
          final result = await runner.checkin(row);
          if (result['ok'] == true) {
            await runner.markScheduleDone(accountIdValue, today);
            succeeded++;
            done = true;
            break;
          }
          // 平台明确返回失败（例如登录态失效）。
          if (attempt >= maxAttempts) {
            await runner.logSchedule(row, ok: false, message: '后台签到连续 $attempt 次失败，今日不再重试');
          }
        } catch (error) {
          if (attempt >= maxAttempts) {
            await runner.logSchedule(row, ok: false, message: '后台签到连续 $attempt 次失败，今日不再重试');
          }
        }
        if (attempt < maxAttempts) {
          await Future<void>.delayed(retryDelay);
        }
      }
      if (!done) {
        // 桌面端在这里锁定当日，避免系统调度器反复唤醒；
        // Android 交给重试任务继续处理，所以不锁。
        if (lockOnExhausted) {
          await runner.markScheduleDone(accountIdValue, today);
        }
        failed++;
      }
    }

    return BackgroundRunResult(attempted: due.length, succeeded: succeeded, failed: failed);
  } finally {
    // 只关闭自己打开的库，注入的库由调用方负责。
    if (owned) await db?.close();
  }
}

/// 需要为哪些账号安装系统级定时任务。
class BackgroundTarget {
  const BackgroundTarget({required this.accountId, required this.time, required this.label});

  final int accountId;

  /// `HH:MM`
  final String time;
  final String label;
}

/// 从账号列表提炼出需要安装系统任务的目标。
List<BackgroundTarget> backgroundTargets(List<Account> accounts) {
  return [
    for (final account in accounts)
      if (account.enabled && account.scheduleEnabled)
        BackgroundTarget(accountId: account.id, time: account.scheduleTime, label: account.title),
  ];
}

/// 校验 `HH:MM`，非法时回退到 09:00（与调度器保持一致）。
(int, int) parseBackgroundTime(String value) => CheckinScheduler.parseScheduleTime(value);
