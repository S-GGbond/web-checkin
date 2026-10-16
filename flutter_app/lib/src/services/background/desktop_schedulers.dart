import 'dart:io';

import 'package:path/path.dart' as p;

import '../../background_entry.dart';
import 'background_scheduler.dart';
import 'schedule_manifest.dart';

/// 桌面三平台共用：清单负责「我们装了什么」，系统查询负责「现在是否还有效」。
abstract class DesktopScheduler implements BackgroundScheduler {
  DesktopScheduler({ScheduleManifest? manifest})
      : _manifest = manifest ?? const ScheduleManifest();

  final ScheduleManifest _manifest;
  BackgroundSchedulerStatus _status = BackgroundSchedulerStatus(
    mechanism: '初始化中',
    available: true,
    executablePath: Platform.resolvedExecutable,
  );

  @override
  BackgroundSchedulerStatus get status => _status;

  String get mechanism;

  String get note;

  String get executablePath => Platform.resolvedExecutable;

  @override
  void dispose() {}

  /// 注册单个账号的每日任务（必须可重复执行，即覆盖已有配置）。
  Future<void> installEntry(BackgroundTarget target);

  /// 移除单个账号的每日任务（不存在时不应报错）。
  Future<void> removeEntry(int accountId);

  /// 系统中是否仍存在该账号的任务。
  Future<bool> entryExists(int accountId);

  Future<ProcessResult> run(String executable, List<String> args) async {
    try {
      return await Process.run(executable, args);
    } on ProcessException catch (error) {
      return ProcessResult(0, 127, '', error.message);
    }
  }

  @override
  Future<BackgroundSchedulerStatus> refresh() async {
    final entries = await _manifest.read();
    final installed = <int, String>{};
    for (final entry in entries) {
      if (await entryExists(entry.accountId)) installed[entry.accountId] = entry.time;
    }
    _status = BackgroundSchedulerStatus(
      mechanism: mechanism,
      available: true,
      executablePath: executablePath,
      note: note,
      installed: installed,
    );
    return _status;
  }

  @override
  Future<String?> sync(List<BackgroundTarget> targets) async {
    final previous = {for (final entry in await _manifest.read()) entry.accountId: entry};
    final desired = <int, BackgroundTarget>{for (final target in targets) target.accountId: target};

    try {
      // 先清理已不再需要的任务。
      for (final entry in previous.values) {
        if (!desired.containsKey(entry.accountId)) {
          await removeEntry(entry.accountId);
        }
      }

      final installed = <int, String>{};
      for (final target in desired.values) {
        final old = previous[target.accountId];
        final unchanged = old != null && old.time == target.time && old.label == target.label;
        // 清单可能过期（用户手动删过系统任务、或上一次移除未同步清单），
        // 因此以系统查询结果为准，必要时重新注册。
        if (!unchanged || !await entryExists(target.accountId)) {
          await installEntry(target);
        }
        installed[target.accountId] = target.time;
      }

      await _manifest.write([
        for (final target in desired.values)
          ScheduleEntry(accountId: target.accountId, time: target.time, label: target.label),
      ]);

      _status = BackgroundSchedulerStatus(
        mechanism: mechanism,
        available: true,
        executablePath: executablePath,
        note: note,
        installed: installed,
      );
      return null;
    } catch (error) {
      _status = BackgroundSchedulerStatus(
        mechanism: mechanism,
        available: true,
        executablePath: executablePath,
        note: note,
        installed: _status.installed,
        lastError: error.toString(),
      );
      return error.toString();
    }
  }

  @override
  Future<String?> uninstallAll() async {
    final entries = await _manifest.read();
    final errors = <String>[];
    for (final entry in entries) {
      try {
        await removeEntry(entry.accountId);
      } catch (error) {
        errors.add('账号 ${entry.accountId}: $error');
      }
    }
    await _manifest.write(const []);
    _status = BackgroundSchedulerStatus(
      mechanism: mechanism,
      available: true,
      executablePath: executablePath,
      note: note,
    );
    return errors.isEmpty ? null : errors.join('；');
  }
}

String _home() => Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

/// Linux：systemd 用户定时器。
class SystemdScheduler extends DesktopScheduler {
  @override
  String get mechanism => 'systemd 用户定时器';

  @override
  String get note => '由 systemd --user 按点唤起，应用关闭后依然有效；'
      'Persistent=true 会在开机后补跑当天错过的任务。需要 systemd 用户会话可用。';

  /// 单元文件目录，测试可覆盖以避免写入真实的 systemd 配置。
  Directory? unitDirOverride;

  Directory get unitDir {
    if (unitDirOverride != null) return unitDirOverride!;
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : p.join(_home(), '.config');
    return Directory(p.join(base, 'systemd', 'user'));
  }

  String unitName(int accountId) => 'checkin-hub-$accountId';

  File serviceFile(int accountId) => File(p.join(unitDir.path, '${unitName(accountId)}.service'));

  File timerFile(int accountId) => File(p.join(unitDir.path, '${unitName(accountId)}.timer'));

  String serviceContent(int accountId, BackgroundTarget target) {
    final buffer = StringBuffer()
      ..writeln('[Unit]')
      ..writeln('Description=签到中枢 定时签到：${target.label}')
      ..writeln('After=network-online.target')
      ..writeln()
      ..writeln('[Service]')
      ..writeln('Type=oneshot')
      ..writeln('Environment=CHECKIN_HUB_BACKGROUND=$accountId')
      ..writeln('Environment=CHECKIN_HUB_ACCOUNT=$accountId');
    // Flutter 桌面端需要图形会话才能初始化引擎，把当前会话的显示变量带过去。
    for (final key in ['DISPLAY', 'WAYLAND_DISPLAY']) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) {
        buffer.writeln('Environment=$key=$value');
      }
    }
    buffer
      ..writeln('ExecStart=${shellQuote(executablePath)} --background-checkin --account $accountId')
      ..writeln();
    return buffer.toString();
  }

  String timerContent(int accountId, BackgroundTarget target) {
    final (hour, minute) = parseBackgroundTime(target.time);
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    final buffer = StringBuffer()
      ..writeln('[Unit]')
      ..writeln('Description=签到中枢 每日 $hh:$mm 签到：${target.label}')
      ..writeln()
      ..writeln('[Timer]')
      ..writeln('OnCalendar=*-*-* $hh:$mm:00')
      ..writeln('Persistent=true')
      ..writeln('Unit=${unitName(accountId)}.service')
      ..writeln()
      ..writeln('[Install]')
      ..writeln('WantedBy=timers.target')
      ..writeln();
    return buffer.toString();
  }

  @override
  Future<void> installEntry(BackgroundTarget target) async {
    await unitDir.create(recursive: true);
    await serviceFile(target.accountId).writeAsString(serviceContent(target.accountId, target));
    await timerFile(target.accountId).writeAsString(timerContent(target.accountId, target));
    await run('systemctl', ['--user', 'daemon-reload']);
    final result = await run('systemctl', ['--user', 'enable', '--now', '${unitName(target.accountId)}.timer']);
    if (result.exitCode != 0) {
      final stderrText = '${result.stderr}'.trim();
      throw ProcessException(
        'systemctl',
        ['--user', 'enable', '--now', '${unitName(target.accountId)}.timer'],
        stderrText.isEmpty ? '启用定时器失败' : stderrText,
        result.exitCode,
      );
    }
  }

  @override
  Future<void> removeEntry(int accountId) async {
    await run('systemctl', ['--user', 'disable', '--now', '${unitName(accountId)}.timer']);
    for (final file in [timerFile(accountId), serviceFile(accountId)]) {
      if (await file.exists()) await file.delete();
    }
    await run('systemctl', ['--user', 'daemon-reload']);
  }

  @override
  Future<bool> entryExists(int accountId) async {
    if (!await timerFile(accountId).exists()) return false;
    final result = await run('systemctl', ['--user', 'is-enabled', '${unitName(accountId)}.timer']);
    // 用户管理器不可用时退回文件存在判断，避免误报「未安装」。
    if (result.exitCode == 127) return true;
    return '${result.stdout}'.trim().startsWith('enabled') || '${result.stdout}'.trim() == 'static';
  }
}

/// macOS：LaunchAgent。
class LaunchdScheduler extends DesktopScheduler {
  @override
  String get mechanism => 'launchd LaunchAgent';

  @override
  String get note => '通过 ~/Library/LaunchAgents 注册每日任务，应用关闭后依然有效；'
      '需要当前用户处于登录状态（LaunchAgent 不覆盖未登录/关机时段）。';

  String label(int accountId) => 'dev.checkinhub.checkin.$accountId';

  File plistFile(int accountId) =>
      File(p.join(_home(), 'Library', 'LaunchAgents', '${label(accountId)}.plist'));

  String plistContent(int accountId, BackgroundTarget target) {
    final (hour, minute) = parseBackgroundTime(target.time);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label(accountId)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(executablePath)}</string>
    <string>--background-checkin</string>
    <string>--account</string>
    <string>$accountId</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CHECKIN_HUB_BACKGROUND</key>
    <string>$accountId</string>
    <key>CHECKIN_HUB_ACCOUNT</key>
    <string>$accountId</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>$hour</integer>
    <key>Minute</key>
    <integer>$minute</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
''';
  }

  @override
  Future<void> installEntry(BackgroundTarget target) async {
    final file = plistFile(target.accountId);
    await file.parent.create(recursive: true);
    await file.writeAsString(plistContent(target.accountId, target));

    final uid = _uid();
    await run('launchctl', ['bootout', 'gui/$uid/${label(target.accountId)}']);
    final result = await run('launchctl', ['bootstrap', 'gui/$uid', file.path]);
    if (result.exitCode != 0) {
      // 老版本 macOS 回退到 load -w。
      final legacy = await run('launchctl', ['load', '-w', file.path]);
      if (legacy.exitCode != 0) {
        throw ProcessException('launchctl', ['bootstrap', 'gui/$uid', file.path], '${result.stderr}'.trim(), result.exitCode);
      }
    }
  }

  @override
  Future<void> removeEntry(int accountId) async {
    final uid = _uid();
    await run('launchctl', ['bootout', 'gui/$uid/${label(accountId)}']);
    await run('launchctl', ['unload', '-w', plistFile(accountId).path]);
    final file = plistFile(accountId);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> entryExists(int accountId) => plistFile(accountId).exists();

  String _uid() => Platform.environment['UID'] ?? '${Process.runSync('id', ['-u']).stdout}'.trim();
}

/// Windows：任务计划程序。
class SchtasksScheduler extends DesktopScheduler {
  @override
  String get mechanism => 'Windows 任务计划程序';

  @override
  String get note => '通过 schtasks 注册每日任务，应用关闭后依然有效；'
      '任务在用户登录状态下运行（桌面端需要图形会话），关机期间错过的任务不会自动补跑。';

  String taskName(int accountId) => 'CheckinHub\\account-$accountId';

  @override
  Future<void> installEntry(BackgroundTarget target) async {
    final (hour, minute) = parseBackgroundTime(target.time);
    final time = '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
    final action = '"$executablePath" --background-checkin --account ${target.accountId}';
    final result = await run('schtasks', [
      '/Create',
      '/F',
      '/TN',
      taskName(target.accountId),
      '/SC',
      'DAILY',
      '/ST',
      time,
      '/TR',
      action,
    ]);
    if (result.exitCode != 0) {
      final stderrText = '${result.stderr}'.trim();
      final stdoutText = '${result.stdout}'.trim();
      throw ProcessException(
        'schtasks',
        ['/Create', '/TN', taskName(target.accountId)],
        stderrText.isEmpty ? stdoutText : stderrText,
        result.exitCode,
      );
    }
  }

  @override
  Future<void> removeEntry(int accountId) async {
    await run('schtasks', ['/Delete', '/F', '/TN', taskName(accountId)]);
  }

  @override
  Future<bool> entryExists(int accountId) async {
    final result = await run('schtasks', ['/Query', '/TN', taskName(accountId)]);
    return result.exitCode == 0;
  }
}

/// 简单的 shell 引号处理：含空格时用双引号包裹。
String shellQuote(String value) => value.contains(' ') ? '"$value"' : value;

String xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
