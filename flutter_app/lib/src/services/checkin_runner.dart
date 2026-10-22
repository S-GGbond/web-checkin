import '../data/app_database.dart';
import '../models/account.dart';
import 'http_json.dart';
import 'qoder/qoder_service.dart';
import 'scheduler.dart';
import 'trae/trae_service.dart';
import 'workbuddy/workbuddy_service.dart';

/// 签到执行的共享内核：既能被应用内的前台调度器调用，也能被
/// 操作系统触发的无界面进程调用，两条路径共用同一套选择与落库逻辑。
class CheckinRunner {
  CheckinRunner(this.db)
      : trae = TraeService(db),
        workbuddy = WorkBuddyService(db),
        qoder = QoderService(db);

  final AppDatabase db;
  final TraeService trae;
  final WorkBuddyService workbuddy;
  final QoderService qoder;

  static String todayKey(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  /// 刷新单个账号的状态（余额 + 签到状态）并落库。
  Future<Map<String, dynamic>> status(Map<String, Object?> row) async {
    final id = row['id'] as int;
    final provider = PlatformKind.fromId(row['provider'] as String);
    try {
      final result = switch (provider) {
        PlatformKind.trae => await trae.status(row),
        PlatformKind.workbuddy => await workbuddy.status(row),
        PlatformKind.qoder => await qoder.status(row),
      };
      await db.updateStatus(id, result);
      await db.addLog(id, provider, action: 'status', ok: true, message: '状态刷新成功', payload: result);
      return result;
    } catch (error) {
      final message = error is ApiException ? error.message : error.toString();
      await db.addLog(id, provider, action: 'status', ok: false, message: message);
      await db.updateCheckin(id, ok: false, message: message);
      rethrow;
    }
  }

  /// 执行一次平台签到，并把结果写入状态、签到摘要与日志。
  /// 平台/网络异常会向上抛出，由调用方决定是否重试。
  Future<Map<String, dynamic>> checkin(Map<String, Object?> row) async {
    final id = row['id'] as int;
    final provider = PlatformKind.fromId(row['provider'] as String);
    final result = switch (provider) {
      PlatformKind.trae => await trae.checkin(row),
      PlatformKind.workbuddy => await workbuddy.checkin(row),
      PlatformKind.qoder => await qoder.checkin(row),
    };
    return {'account_id': id, 'provider': provider.id, 'display_name': row['display_name'], ...result};
  }

  /// 选出「现在应该执行」的账号。
  ///
  /// 条件与调度器一致：启用、开启定时、当日未完成、已过计划时间。
  /// 传入 [accountId] 时只判断该账号（操作系统的单账号定时器走这条）。
  Future<List<Map<String, Object?>>> dueAccounts({
    int? accountId,
    DateTime? now,
  }) async {
    final moment = now ?? DateTime.now();
    final today = todayKey(moment);
    final rows = await db.listAccountRows(enabledOnly: true);
    return rows.where((row) {
      if (accountId != null && row['id'] != accountId) return false;
      if ((row['schedule_enabled'] as int? ?? 1) != 1) return false;
      if (row['schedule_last_date'] == today) return false;
      final (hour, minute) = CheckinScheduler.parseScheduleTime((row['schedule_time'] as String?) ?? '09:00');
      return moment.hour > hour || (moment.hour == hour && moment.minute >= minute);
    }).toList();
  }

  Future<void> markScheduleDone(int accountId, String date) => db.markScheduleRun(accountId, date);

  Future<void> logSchedule(
    Map<String, Object?> row, {
    required bool ok,
    required String message,
  }) =>
      db.addLog(
        row['id'] as int,
        PlatformKind.fromId(row['provider'] as String),
        action: 'schedule',
        ok: ok,
        message: message,
      );

  Future<Map<String, Object?>?> accountRow(int accountId) => db.getAccountRow(accountId);
}
