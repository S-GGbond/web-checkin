import 'dart:io';

import 'package:checkin_hub/src/background_entry.dart';
import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/services/background/android_alarm_scheduler.dart';
import 'package:checkin_hub/src/services/background/desktop_schedulers.dart';
import 'package:checkin_hub/src/services/background/schedule_manifest.dart';
import 'package:checkin_hub/src/services/checkin_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('时间解析', () {
    test('parseBackgroundTime 对非法输入回退 09:00', () {
      expect(parseBackgroundTime('07:30'), (7, 30));
      expect(parseBackgroundTime('23:59'), (23, 59));
      expect(parseBackgroundTime('bad'), (9, 0));
      expect(parseBackgroundTime('25:00'), (9, 0));
    });
  });

  group('systemd 单元文件', () {
    final scheduler = SystemdScheduler();

    test('service 使用环境变量与命令行双通道标记后台模式', () {
      final content = scheduler.serviceContent(
        7,
        const BackgroundTarget(accountId: 7, time: '09:30', label: '我的 Trae'),
      );
      expect(content, contains('[Service]'));
      expect(content, contains('Type=oneshot'));
      expect(content, contains('Environment=CHECKIN_HUB_BACKGROUND=7'));
      expect(content, contains('Environment=CHECKIN_HUB_ACCOUNT=7'));
      expect(content, contains('--background-checkin --account 7'));
      expect(content, contains('我的 Trae'));
    });

    test('timer 使用每日 OnCalendar 并开启 Persistent 补跑', () {
      final content = scheduler.timerContent(
        3,
        const BackgroundTarget(accountId: 3, time: '07:05', label: 'WB'),
      );
      expect(content, contains('OnCalendar=*-*-* 07:05:00'));
      expect(content, contains('Persistent=true'));
      expect(content, contains('Unit=checkin-hub-3.service'));
      expect(content, contains('WantedBy=timers.target'));
    });

    test('时间补零与非法值回退', () {
      expect(
        scheduler.timerContent(1, const BackgroundTarget(accountId: 1, time: '9:5', label: 'x')),
        contains('OnCalendar=*-*-* 09:05:00'),
      );
      expect(
        scheduler.timerContent(1, const BackgroundTarget(accountId: 1, time: 'oops', label: 'x')),
        contains('OnCalendar=*-*-* 09:00:00'),
      );
    });

    test('单元名与文件路径稳定', () {
      expect(scheduler.unitName(12), 'checkin-hub-12');
      expect(scheduler.timerFile(12).path, endsWith('checkin-hub-12.timer'));
      expect(scheduler.serviceFile(12).path, endsWith('checkin-hub-12.service'));
    });
  });

  group('launchd plist', () {
    test('包含每日时间、参数与环境变量', () {
      final plist = LaunchdScheduler().plistContent(
        5,
        const BackgroundTarget(accountId: 5, time: '21:15', label: '夜间'),
      );
      expect(plist, contains('<key>Label</key>'));
      expect(plist, contains('dev.checkinhub.checkin.5'));
      expect(plist, contains('<string>--background-checkin</string>'));
      expect(plist, contains('<key>Hour</key>'));
      expect(plist, contains('<integer>21</integer>'));
      expect(plist, contains('<integer>15</integer>'));
      expect(plist, contains('CHECKIN_HUB_ACCOUNT'));
      expect(plist, contains('<key>RunAtLoad</key>'));
    });

    test('路径中的 XML 特殊字符被转义', () {
      expect(xmlEscape('/Users/a&b/app'), '/Users/a&amp;b/app');
    });
  });

  group('schtasks 参数', () {
    test('任务名与可执行文件路径拼接', () {
      final scheduler = SchtasksScheduler();
      expect(scheduler.taskName(9), 'CheckinHub\\account-9');
    });

    test('shellQuote 仅在含空格时加引号', () {
      expect(shellQuote('/usr/bin/app'), '/usr/bin/app');
      expect(shellQuote('/opt/my app/app'), '"/opt/my app/app"');
    });
  });

  group('待执行账号筛选', () {
    late AppDatabase db;
    late CheckinRunner runner;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      runner = CheckinRunner(db);
    });
    tearDown(() async => db.close());

    Future<int> addAccount({
      required String time,
      bool enabled = true,
      bool scheduleEnabled = true,
      String? lastDate,
      PlatformKind provider = PlatformKind.workbuddy,
    }) async {
      final id = await db.upsertAccount(
        provider: provider,
        externalId: 'e$time$enabled$scheduleEnabled${lastDate ?? ''}${provider.id}',
        displayName: 'acc',
        endpoint: 'https://example.com',
        credential: 'c',
      );
      await db.updateSchedule(id, enabled: scheduleEnabled, time: time);
      await db.setEnabled(id, enabled);
      if (lastDate != null) await db.markScheduleRun(id, lastDate);
      return id;
    }

    test('未到点不执行，到点与过点都执行', () async {
      await addAccount(time: '09:00');
      final day = DateTime(2026, 10, 16);

      expect(await runner.dueAccounts(now: DateTime(day.year, day.month, day.day, 8, 59)), isEmpty);
      expect(await runner.dueAccounts(now: DateTime(day.year, day.month, day.day, 9, 0)), hasLength(1));
      expect(await runner.dueAccounts(now: DateTime(day.year, day.month, day.day, 23, 30)), hasLength(1));
    });

    test('当日已完成、停用账号、关闭定时都不会再执行', () async {
      await addAccount(time: '09:00', lastDate: '2026-10-16');
      await addAccount(time: '09:00', enabled: false);
      await addAccount(time: '09:00', scheduleEnabled: false);

      final due = await runner.dueAccounts(now: DateTime(2026, 10, 16, 12, 0));
      expect(due, isEmpty);
    });

    test('跨天后重新可执行', () async {
      await addAccount(time: '09:00', lastDate: '2026-10-15');
      final due = await runner.dueAccounts(now: DateTime(2026, 10, 16, 12, 0));
      expect(due, hasLength(1));
    });

    test('可以只筛选指定账号（系统调度器一次只唤起一个账号）', () async {
      final first = await addAccount(time: '09:00', provider: PlatformKind.workbuddy);
      final second = await addAccount(time: '09:00', provider: PlatformKind.trae);
      final now = DateTime(2026, 10, 16, 12, 0);

      expect(await runner.dueAccounts(now: now), hasLength(2));
      final onlyFirst = await runner.dueAccounts(accountId: first, now: now);
      expect(onlyFirst.map((row) => row['id']), [first]);
      expect(await runner.dueAccounts(accountId: second, now: now), hasLength(1));
    });
  });

  group('系统任务目标', () {
    Account account({
      required int id,
      bool enabled = true,
      bool scheduleEnabled = true,
      String time = '09:00',
    }) =>
        Account(
          id: id,
          provider: PlatformKind.workbuddy,
          externalId: 'e$id',
          displayName: '账号 $id',
          label: '',
          endpoint: 'https://example.com',
          credential: '',
          enabled: enabled,
          scheduleEnabled: scheduleEnabled,
          scheduleTime: time,
          createdAt: 0,
          updatedAt: 0,
        );

    test('只把启用且开启定时的账号注册到系统', () {
      final targets = backgroundTargets([
        account(id: 1),
        account(id: 2, enabled: false),
        account(id: 3, scheduleEnabled: false),
        account(id: 4, time: '20:30'),
      ]);
      expect(targets.map((t) => t.accountId), [1, 4]);
      expect(targets.last.time, '20:30');
      expect(targets.first.label, '账号 1');
    });
  });

  group('Android 精确闹钟', () {
    test('闹钟 id 每个账号互不冲突，且留出重试位', () {
      expect(AndroidAlarmScheduler.dailyAlarmId(7), 700);
      expect(AndroidAlarmScheduler.retryAlarmId(7, 1), 701);
      expect(AndroidAlarmScheduler.retryAlarmId(7, 2), 702);
      // 相邻账号的 id 段不重叠。
      expect(AndroidAlarmScheduler.retryAlarmId(7, 2), lessThan(AndroidAlarmScheduler.dailyAlarmId(8)));
    });

    test('nextOccurrence 取当天未过的时间，已过则顺延到明天', () {
      final now = DateTime(2026, 10, 16, 8, 0);
      expect(AndroidAlarmScheduler.nextOccurrence('09:00', now), DateTime(2026, 10, 16, 9, 0));

      final late = DateTime(2026, 10, 16, 10, 0);
      expect(AndroidAlarmScheduler.nextOccurrence('09:00', late), DateTime(2026, 10, 17, 9, 0));

      // 正好到点也算已过，避免同一天重复触发。
      final exact = DateTime(2026, 10, 16, 9, 0);
      expect(AndroidAlarmScheduler.nextOccurrence('09:00', exact), DateTime(2026, 10, 17, 9, 0));
    });

    test('非法时间回退到 09:00', () {
      final now = DateTime(2026, 10, 16, 8, 0);
      expect(AndroidAlarmScheduler.nextOccurrence('oops', now), DateTime(2026, 10, 16, 9, 0));
    });
  });

  group('任务清单', () {
    test('写入后可读回，字段缺失的条目被忽略', () async {
      final dir = await Directory.systemTemp.createTemp('checkin-manifest');
      addTearDown(() async => dir.delete(recursive: true));

      final manifest = ScheduleManifest(directory: dir);
      expect(await manifest.read(), isEmpty);

      await manifest.write(const [
        ScheduleEntry(accountId: 1, time: '09:00', label: 'a'),
        ScheduleEntry(accountId: 2, time: '20:00', label: 'b'),
      ]);
      final entries = await manifest.read();
      expect(entries, hasLength(2));
      expect(entries.first.time, '09:00');
      expect(entries.last.label, 'b');
    });
  });
}
