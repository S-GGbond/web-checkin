import 'dart:io';

import 'package:checkin_hub/src/data/app_database.dart';
import 'package:checkin_hub/src/models/account.dart';
import 'package:checkin_hub/src/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 账号库行为测试。真实文件库部分需要把 `CHECKIN_HUB_DB` 指向一个临时文件：
/// `CHECKIN_HUB_DB=/tmp/checkin-test.sqlite3 flutter test test/database_test.dart`
void main() {
  group('账号库（内存）', () {
    late AppDatabase db;

    setUp(() async => db = await AppDatabase.openInMemory());
    tearDown(() async => db.close());

    test('新增账号后可按平台排序读取', () async {
      await db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 't1',
        displayName: 'Trae 账号',
        endpoint: 'https://api.trae.cn',
        credential: 'cred-1',
      );
      await db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'w1',
        displayName: 'WB 账号',
        endpoint: 'https://www.workbuddy.cn',
        credential: 'cred-2',
      );

      final accounts = await db.listAccounts();
      expect(accounts.map((a) => a.provider).toList(),
          [PlatformKind.workbuddy, PlatformKind.trae]);
      // 公开列表不包含凭据。
      expect(accounts.first.title, 'WB 账号');
    });

    test('同平台同 external_id 会更新而不是重复插入', () async {
      final first = await db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'w1',
        displayName: '旧名字',
        endpoint: 'https://www.workbuddy.cn',
        credential: 'old',
      );
      final second = await db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'w1',
        displayName: '新名字',
        endpoint: 'https://www.workbuddy.cn',
        credential: 'new',
      );

      expect(second, first);
      final accounts = await db.listAccounts();
      expect(accounts, hasLength(1));
      expect(accounts.single.displayName, '新名字');
    });

    test('状态与签到结果可回写', () async {
      final id = await db.upsertAccount(
        provider: PlatformKind.workbuddy,
        externalId: 'w1',
        displayName: 'WB',
        endpoint: 'https://www.workbuddy.cn',
        credential: 'c',
      );
      await db.updateStatus(id, {
        'today_checked_in': true,
        'usage': {'creditsTotal': 10, 'creditsLeft': 4, 'unlimited': false},
      });
      await db.updateCheckin(id, ok: true, message: '签到成功');

      final account = (await db.listAccounts()).single;
      expect(account.checkedInToday, isTrue);
      expect(account.usage?.leftLabel, '4');
      expect(account.usage?.totalLabel, '10');
      expect(account.lastCheckinOk, isTrue);
      expect(account.lastCheckinMessage, '签到成功');
    });

    test('定时配置与当日完成标记', () async {
      final id = await db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 't1',
        displayName: 'Trae',
        endpoint: 'https://api.trae.cn',
        credential: 'c',
      );
      await db.updateSchedule(id, enabled: false, time: '07:30');
      await db.markScheduleRun(id, '2026-10-16');

      final account = (await db.listAccounts()).single;
      expect(account.scheduleEnabled, isFalse);
      expect(account.scheduleTime, '07:30');
      expect(account.scheduleLastDate, '2026-10-16');
    });

    test('启停与删除账号', () async {
      final id = await db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 't1',
        displayName: 'Trae',
        endpoint: 'https://api.trae.cn',
        credential: 'c',
      );
      expect(await db.setEnabled(id, false), isTrue);
      expect(await db.listAccounts(enabledOnly: true), isEmpty);

      await db.addLog(id, PlatformKind.trae, action: 'checkin', ok: true, message: 'ok');
      expect(await db.recentLogs(), hasLength(1));

      expect(await db.deleteAccount(id), isTrue);
      // 外键级联应清掉该账号的日志。
      expect(await db.recentLogs(), isEmpty);
    });

    test('设置项可读写', () async {
      expect(await db.getSetting('missing', fallback: 'd'), 'd');
      await db.setSetting('k', 'v1');
      await db.setSetting('k', 'v2');
      expect(await db.getSetting('k'), 'v2');
    });
  });

  group('账号库（真实文件）', () {
    final envPath = Platform.environment['CHECKIN_HUB_DB'];

    test('按 CHECKIN_HUB_DB 打开真实文件库', () async {
      final db = await AppDatabase.open();
      addTearDown(() async {
        await db.close();
        final file = File(envPath!);
        if (await file.exists()) await file.delete();
      });

      expect(db.path, envPath);
      final id = await db.upsertAccount(
        provider: PlatformKind.trae,
        externalId: 'reopen-1',
        displayName: '落盘账号',
        endpoint: 'https://api.trae.cn',
        credential: 'c',
      );
      expect(id, greaterThan(0));
      expect((await db.listAccounts()).single.displayName, '落盘账号');

      if (!Platform.isWindows) {
        // 账号库应为仅本人可读。
        final mode = (await File(envPath!).stat()).mode & 0xFFF;
        expect(mode, 0x180); // 0600
      }
    }, skip: envPath == null ? '未设置 CHECKIN_HUB_DB，跳过真实文件库测试' : null);

    test('AppState 用真实文件库完成初始化', () async {
      final state = AppState();
      addTearDown(state.dispose);
      await state.init(startScheduler: false, refreshOnStart: false, syncBackground: false,
        importDesktopAccounts: false);

      expect(state.fatalError, isNull);
      expect(state.initialized, isTrue);
      expect(state.accounts, isEmpty);
    }, skip: envPath == null ? '未设置 CHECKIN_HUB_DB，跳过真实文件库测试' : null);
  });
}
