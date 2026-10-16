import 'dart:io';

import 'package:checkin_hub/src/background_entry.dart';
import 'package:checkin_hub/src/services/background/desktop_schedulers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实的 systemd 用户定时器集成验证：会写入 ~/.config/systemd/user 并调用
/// systemctl --user，因此默认跳过，需要显式开启：
///
/// ```bash
/// CHECKIN_VERIFY_SYSTEMD=1 WEB_CHECKIN_HOME=/tmp/bg-verify flutter test test/systemd_integration_test.dart
/// ```
void main() {
  final enabled = Platform.environment['CHECKIN_VERIFY_SYSTEMD'] == '1';
  final skipReason = enabled ? null : '未设置 CHECKIN_VERIFY_SYSTEMD=1，跳过真实 systemd 集成测试';

  group('systemd 用户定时器（真实环境）', () {
    // 用一个不会与真实账号冲突的 ID。
    const probeAccountId = 999001;

    test('安装后 systemd 能识别，移除后清理干净', () async {
      final scheduler = SystemdScheduler();
      final timer = scheduler.timerFile(probeAccountId);
      final service = scheduler.serviceFile(probeAccountId);

      addTearDown(() async {
        await scheduler.removeEntry(probeAccountId);
      });

      final error = await scheduler.sync([
        const BackgroundTarget(accountId: probeAccountId, time: '03:07', label: '集成验证'),
      ]);
      expect(error, isNull, reason: '同步到 systemd 失败');

      expect(await timer.exists(), isTrue);
      expect(await service.exists(), isTrue);
      expect(await timer.readAsString(), contains('OnCalendar=*-*-* 03:07:00'));

      // systemd 自身应当已经识别该定时器。
      final isEnabled = await Process.run(
        'systemctl',
        ['--user', 'is-enabled', '${scheduler.unitName(probeAccountId)}.timer'],
      );
      expect('${isEnabled.stdout}'.trim(), contains('enabled'));

      final list = await Process.run('systemctl', ['--user', 'list-timers', '--all']);
      expect('${list.stdout}', contains(scheduler.unitName(probeAccountId)));

      final status = await scheduler.refresh();
      expect(status.installed[probeAccountId], '03:07');

      // 移除后文件与 systemd 记录都应消失。
      await scheduler.removeEntry(probeAccountId);
      expect(await timer.exists(), isFalse);
      expect(await service.exists(), isFalse);

      final afterRemove = await Process.run(
        'systemctl',
        ['--user', 'is-enabled', '${scheduler.unitName(probeAccountId)}.timer'],
      );
      expect(afterRemove.exitCode, isNot(0));
    }, skip: skipReason);

    test('sync 会移除不再需要的账号任务', () async {
      final scheduler = SystemdScheduler();
      addTearDown(() async => scheduler.removeEntry(probeAccountId));

      await scheduler.sync([
        const BackgroundTarget(accountId: probeAccountId, time: '03:07', label: '集成验证'),
      ]);
      expect(await scheduler.timerFile(probeAccountId).exists(), isTrue);

      // 目标为空：应删除已注册的任务。
      await scheduler.sync(const []);
      expect(await scheduler.timerFile(probeAccountId).exists(), isFalse);
    }, skip: skipReason);
  });
}
