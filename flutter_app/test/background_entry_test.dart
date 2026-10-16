import 'package:checkin_hub/src/background_entry.dart';
import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/checkin_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 无界面后台执行的完整流程：挑选 → 重试 → 落库 → 退出码。
/// 用无法解密的 Trae 凭据让签到确定性失败，避免真实网络请求。
void main() {
  late AppDatabase db;

  setUp(() async => db = await AppDatabase.openInMemory());
  tearDown(() async => db.close());

  Future<int> addAccount({String time = '00:05', bool scheduleEnabled = true}) async {
    final id = await db.upsertAccount(
      provider: PlatformKind.trae,
      externalId: 'bg-$time-$scheduleEnabled',
      displayName: '后台账号',
      endpoint: 'https://api.trae.cn',
      credential: 'not-a-valid-container',
    );
    await db.updateSchedule(id, enabled: scheduleEnabled, time: time);
    return id;
  }

  final noon = DateTime(2026, 10, 16, 12, 0);

  test('没有到点账号时直接跳过', () async {
    await addAccount(time: '23:59');

    final result = await runBackgroundCheckin(database: db, now: noon);

    expect(result.attempted, 0);
    expect(result.ok, isTrue);
    expect(result.skippedReason, '当日无待执行任务');
    expect(await db.recentLogs(), isEmpty);
  });

  test('重试耗尽后锁定当日，并记录失败', () async {
    final id = await addAccount();

    final result = await runBackgroundCheckin(
      database: db,
      now: noon,
      retryDelay: Duration.zero,
    );

    expect(result.attempted, 1);
    expect(result.failed, 1);
    expect(result.ok, isFalse);

    // recentLogs 是最新在前，这里按发生顺序排列。
    final logs = (await db.recentLogs()).reversed.toList();
    // 每次尝试都记一条 schedule，耗尽后再补一条失败说明。
    final scheduleLogs = logs.where((log) => log.action == 'schedule').toList();
    expect(scheduleLogs, hasLength(4));
    expect(scheduleLogs.first.message, contains('第 1/3 次'));
    expect(scheduleLogs.last.ok, isFalse);
    expect(scheduleLogs.last.message, contains('今日不再重试'));

    // 当日已锁定，避免系统调度器反复唤醒。
    final account = (await db.listAccounts()).firstWhere((a) => a.id == id);
    expect(account.scheduleLastDate, CheckinRunner.todayKey(noon));
    expect(await CheckinRunner(db).dueAccounts(now: noon), isEmpty);
  });

  test('lockOnExhausted=false 时保留当日可重试（Android 走这条）', () async {
    final id = await addAccount();

    final result = await runBackgroundCheckin(
      database: db,
      now: noon,
      maxAttempts: 1,
      lockOnExhausted: false,
    );

    expect(result.failed, 1);
    final account = (await db.listAccounts()).firstWhere((a) => a.id == id);
    expect(account.scheduleLastDate, isNull);
    // 仍然可被下一次重试任务选中。
    expect(await CheckinRunner(db).dueAccounts(now: noon), hasLength(1));
  });

  test('关闭定时的账号不会被后台唤起', () async {
    await addAccount(scheduleEnabled: false);

    final result = await runBackgroundCheckin(database: db, now: noon);

    expect(result.attempted, 0);
    expect(result.skippedReason, '当日无待执行任务');
  });

  test('只处理指定账号', () async {
    final first = await addAccount(time: '00:05');
    await addAccount(time: '00:06');

    final result = await runBackgroundCheckin(
      database: db,
      accountId: first,
      now: noon,
      retryDelay: Duration.zero,
    );

    expect(result.attempted, 1);
    final scheduleLogs = (await db.recentLogs()).where((log) => log.action == 'schedule');
    expect(scheduleLogs.every((log) => log.accountId == first), isTrue);
  });
}
