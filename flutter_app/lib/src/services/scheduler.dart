import 'dart:async';

import '../data/app_database.dart';
import '../models/account.dart';

/// 每账号每日定时签到的调度器。
///
/// 与原 Python 端语义一致：到点触发、失败按固定间隔重试有限次、
/// 成功或重试耗尽后锁定当日；应用启动时补跑当天已过点但未完成的任务。
/// 由于是随应用运行的调度器，应用在后台时由操作系统决定是否继续计时。
class CheckinScheduler {
  CheckinScheduler({
    required AppDatabase db,
    required Future<void> Function(Map<String, Object?> row) runCheckin,
  })  : _db = db,
        _runCheckin = runCheckin;

  final AppDatabase _db;
  final Future<void> Function(Map<String, Object?> row) _runCheckin;

  static const int maxAttempts = 3;
  static const Duration retryDelay = Duration(seconds: 300);
  static const Duration tick = Duration(seconds: 30);

  Timer? _timer;
  bool _ticking = false;

  /// account_id → (运行日期, 已尝试次数)
  final Map<int, (String, int)> _retryState = {};
  final Set<int> _inFlight = {};

  void start() {
    _timer ??= Timer.periodic(tick, (_) => unawaited(runDue()));
    unawaited(runDue());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 清掉某账号的当日重试计数（例如改了计划时间后）。
  void resetRetry(int accountId) => _retryState.remove(accountId);

  void forget(int accountId) {
    _retryState.remove(accountId);
    _inFlight.remove(accountId);
  }

  static String _todayKey(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  static (int, int) parseScheduleTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return (9, 0);
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null || hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return (9, 0);
    }
    return (hour, minute);
  }

  /// 走一遍所有账号，触发到点且当日未完成的任务。
  Future<void> runDue() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final now = DateTime.now();
      final today = _todayKey(now);
      final rows = await _db.listAccountRows(enabledOnly: true);
      for (final row in rows) {
        final id = row['id'] as int;
        if (_inFlight.contains(id)) continue;
        if ((row['schedule_enabled'] as int? ?? 1) != 1) continue;
        if (row['schedule_last_date'] == today) continue;
        final (hour, minute) = parseScheduleTime((row['schedule_time'] as String?) ?? '09:00');
        if (now.hour < hour || (now.hour == hour && now.minute < minute)) continue;

        final state = _retryState[id];
        final attempts = (state != null && state.$1 == today ? state.$2 : 0) + 1;
        _inFlight.add(id);
        try {
          await _db.addLog(
            id,
            PlatformKind.fromId(row['provider'] as String),
            action: 'schedule',
            ok: true,
            message: '每日定时任务触发（第 $attempts/$maxAttempts 次），计划时间 ${row['schedule_time']}',
          );
          await _runCheckin(row);
          await _db.markScheduleRun(id, today);
          _retryState.remove(id);
        } catch (error) {
          if (attempts >= maxAttempts) {
            await _db.markScheduleRun(id, today);
            _retryState.remove(id);
            await _db.addLog(
              id,
              PlatformKind.fromId(row['provider'] as String),
              action: 'schedule',
              ok: false,
              message: '定时签到连续 $attempts 次失败，今日不再重试',
            );
          } else {
            _retryState[id] = (today, attempts);
            _scheduleRetry(id);
          }
        } finally {
          _inFlight.remove(id);
        }
      }
    } finally {
      _ticking = false;
    }
  }

  void _scheduleRetry(int accountId) {
    Timer(retryDelay, () => unawaited(_retryNow(accountId)));
  }

  Future<void> _retryNow(int accountId) async {
    final row = await _db.getAccountRow(accountId);
    if (row == null || (row['enabled'] as int? ?? 1) != 1) {
      forget(accountId);
      return;
    }
    final today = _todayKey(DateTime.now());
    final state = _retryState[accountId];
    final attempts = (state != null && state.$1 == today ? state.$2 : 0) + 1;
    if (_inFlight.contains(accountId)) return;
    _inFlight.add(accountId);
    try {
      await _db.addLog(
        accountId,
        PlatformKind.fromId(row['provider'] as String),
        action: 'schedule',
        ok: true,
        message: '每日定时任务重试（第 $attempts/$maxAttempts 次），计划时间 ${row['schedule_time']}',
      );
      await _runCheckin(row);
      await _db.markScheduleRun(accountId, today);
      _retryState.remove(accountId);
    } catch (_) {
      if (attempts >= maxAttempts) {
        await _db.markScheduleRun(accountId, today);
        _retryState.remove(accountId);
        await _db.addLog(
          accountId,
          PlatformKind.fromId(row['provider'] as String),
          action: 'schedule',
          ok: false,
          message: '定时签到连续 $attempts 次失败，今日不再重试',
        );
      } else {
        _retryState[accountId] = (today, attempts);
        _scheduleRetry(accountId);
      }
    } finally {
      _inFlight.remove(accountId);
    }
  }
}
