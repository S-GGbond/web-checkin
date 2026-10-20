import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/account.dart';
import '../../util/app_paths.dart';

/// 桌面客户端（Trae CN / WorkBuddy）的定位、进程与文件写入。
///
/// 只覆盖桌面平台：Android / iOS 上所有方法都返回「不支持」，
/// 由调用方隐藏入口，不做任何降级尝试。
class DesktopClient {
  DesktopClient._();

  /// 目前实现的两端都基于 Electron，仅 Windows / Linux / macOS 有意义。
  static bool get supported => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static bool supports(PlatformKind provider) => supported;

  static const String traeAuthKey = 'iCubeAuthInfo://icube.cloudide';

  static const List<String> _traeVariants = ['Trae CN', 'TRAE SOLO CN', 'Trae', 'TRAE SOLO'];

  static String get _home => AppPaths.home;

  static String get _appData => Platform.environment['APPDATA'] ?? '';
  static String get _localAppData => Platform.environment['LOCALAPPDATA'] ?? '';

  // ---------------------------------------------------------------------------
  // 登录态文件
  // ---------------------------------------------------------------------------

  static List<String> traeAuthFiles() {
    final files = <String>[];
    for (final name in _traeVariants) {
      if (Platform.isWindows) {
        files.add(p.join(_appData, name, 'User', 'globalStorage', 'storage.json'));
        files.add(p.join(_localAppData, name, 'User', 'globalStorage', 'storage.json'));
      } else if (Platform.isMacOS) {
        files.add(p.join(_home, 'Library', 'Application Support', name, 'User', 'globalStorage', 'storage.json'));
      } else {
        files.add(p.join(_home, '.config', name, 'User', 'globalStorage', 'storage.json'));
      }
    }
    return files.where((file) => File(file).existsSync()).toList();
  }

  static List<String> workbuddyAuthFiles() {
    const rel = 'CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info';
    final files = <String>[];
    if (Platform.isWindows) {
      files.add(p.join(_localAppData, rel));
      files.add(p.join(_appData, rel));
    } else if (Platform.isMacOS) {
      files.add(p.join(_home, 'Library', 'Application Support', rel));
    } else {
      files.add(p.join(_home, '.local', 'share', rel));
      files.add(p.join(_home, '.config', rel));
    }
    return files.where((file) => File(file).existsSync()).toList();
  }

  // ---------------------------------------------------------------------------
  // 主程序
  // ---------------------------------------------------------------------------

  static final Map<PlatformKind, String?> _executableCache = {};

  /// 定位客户端主程序。
  ///
  /// [refresh] 为真时丢弃缓存重新探测（用户在界面上点「重新探测」时才需要）；
  /// 内部的定时刷新/切换后刷新都走缓存，避免反复做安装目录搜索拖慢界面。
  static Future<String?> executable(PlatformKind provider, {bool refresh = false}) async {
    if (refresh) _executableCache.remove(provider);
    if (_executableCache.containsKey(provider)) return _executableCache[provider];
    final found = (provider == PlatformKind.trae ? await _findTrae() : await _findWorkbuddy()) ??
        await _runningExecutable(provider);
    _executableCache[provider] = found;
    return found;
  }

  /// 安装路径不在候选列表里时，从正在运行的进程反查主程序路径。
  ///
  /// Windows 上没有 `/proc`，用 PowerShell 取 `Get-Process().Path`；
  /// Linux 直接读 `/proc/<pid>/exe`；macOS 用 `ps` 取命令行首段。
  static Future<String?> _runningExecutable(PlatformKind provider) async {
    if (Platform.isWindows) {
      final name = provider == PlatformKind.trae ? 'Trae*' : 'WorkBuddy';
      final script = "\$p = Get-Process -ErrorAction SilentlyContinue | "
          "Where-Object { \$_.ProcessName -like '$name' } | Select-Object -First 1; "
          "if (\$p) { \$p.Path }";
      try {
        final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
        if (result.exitCode == 0) {
          final found = (result.stdout as String).trim();
          if (found.isNotEmpty && File(found).existsSync()) return found;
        }
      } catch (_) {
        // PowerShell 不可用时放弃
      }
      return null;
    }
    for (final pid in await runningPids(provider)) {
      try {
        if (Platform.isLinux) {
          final target = File('/proc/$pid/exe').resolveSymbolicLinksSync();
          if (File(target).existsSync()) return target;
        } else {
          final result = await Process.run('ps', ['-p', '$pid', '-o', 'command=']);
          final command = (result.stdout as String).trim();
          final first = command.split(RegExp(r'\s')).firstWhere((part) => part.isNotEmpty, orElse: () => '');
          if (first.isNotEmpty && File(first).existsSync()) return first;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static void clearCache() => _executableCache.clear();

  static Future<String?> _findTrae() async {
    final candidates = <String>[];
    if (Platform.isWindows) {
      for (final name in ['Trae CN', 'Trae']) {
        candidates.add(p.join(_localAppData, 'Programs', name, '$name.exe'));
        candidates.add(p.join(Platform.environment['PROGRAMFILES'] ?? '', name, '$name.exe'));
        candidates.add(p.join(Platform.environment['PROGRAMFILES(X86)'] ?? '', name, '$name.exe'));
      }
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '/Applications/Trae CN.app/Contents/MacOS/Electron',
        p.join(_home, 'Applications', 'Trae CN.app', 'Contents', 'MacOS', 'Electron'),
      ]);
    } else {
      candidates.addAll([
        '/usr/share/trae-cn/trae-cn',
        '/usr/share/trae/trae',
        '/opt/trae-cn/trae-cn',
        '/opt/trae/trae',
        '/usr/lib/trae-cn/trae-cn',
        p.join(_home, '.local', 'share', 'trae-cn', 'trae-cn'),
      ]);
    }
    return _firstFile(candidates) ?? await _which(['trae-cn', 'trae']);
  }

  static Future<String?> _findWorkbuddy() async {
    final candidates = <String>[];
    if (Platform.isWindows) {
      candidates.addAll([
        p.join(_localAppData, 'Programs', 'WorkBuddy', 'WorkBuddy.exe'),
        p.join(Platform.environment['PROGRAMFILES'] ?? '', 'WorkBuddy', 'WorkBuddy.exe'),
        p.join(Platform.environment['PROGRAMFILES(X86)'] ?? '', 'WorkBuddy', 'WorkBuddy.exe'),
      ]);
    } else if (Platform.isMacOS) {
      candidates.addAll([
        '/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy',
        '/Applications/WorkBuddy.app/Contents/MacOS/Electron',
        p.join(_home, 'Applications', 'WorkBuddy.app', 'Contents', 'MacOS', 'WorkBuddy'),
      ]);
    } else {
      candidates.addAll([
        '/opt/workbuddy/workbuddy',
        '/usr/lib/workbuddy/workbuddy',
        '/usr/share/workbuddy/workbuddy',
        '/usr/local/workbuddy/workbuddy',
        p.join(_home, '.local', 'opt', 'workbuddy', 'workbuddy'),
      ]);
    }
    return _firstFile(candidates) ??
        await _which(['workbuddy']) ??
        (Platform.isLinux
            ? await _searchExecutable(['/var/lib/apm', '/opt', '/usr/lib', '/usr/share'], 'workbuddy')
            : null);
  }

  static String? _firstFile(List<String> candidates) {
    for (final candidate in candidates) {
      if (candidate.isEmpty) continue;
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String?> _which(List<String> names) async {
    for (final name in names) {
      try {
        final result = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
        if (result.exitCode != 0) continue;
        final first = const LineSplitter()
            .convert(result.stdout as String)
            .map((line) => line.trim())
            .firstWhere((line) => line.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) return first;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 有限深度搜索：Linux 上通过 apm 转制的安装路径层级较深
  /// （如 `/var/lib/apm/apm/files/ace-env/var/lib/apm/<pkg>/files/core/opt/workbuddy/workbuddy`）。
  static Future<String?> _searchExecutable(List<String> roots, String name, {int maxDepth = 14}) async {
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      final found = await _walk(dir, name, maxDepth);
      if (found != null) return found;
    }
    return null;
  }

  static Future<String?> _walk(Directory dir, String name, int depth) async {
    if (depth < 0) return null;
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return null;
    }
    final directories = <Directory>[];
    for (final entry in entries) {
      if (entry is File && p.basename(entry.path) == name && !entry.path.endsWith('.sh')) {
        return entry.path;
      }
      if (entry is Directory) directories.add(entry);
    }
    for (final child in directories) {
      final found = await _walk(child, name, depth - 1);
      if (found != null) return found;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 进程
  // ---------------------------------------------------------------------------

  static List<String> _processMatchers(PlatformKind provider) {
    if (Platform.isWindows) {
      return provider == PlatformKind.trae ? ['Trae CN.exe', 'Trae.exe'] : ['WorkBuddy.exe'];
    }
    if (Platform.isMacOS) {
      return provider == PlatformKind.trae
          ? ['Trae CN.app/Contents/MacOS', 'Trae.app/Contents/MacOS']
          : ['WorkBuddy.app/Contents/MacOS'];
    }
    return provider == PlatformKind.trae
        ? ['/trae-cn', 'trae-cn/trae-cn', '/opt/trae/trae']
        : ['/workbuddy', 'workbuddy/workbuddy'];
  }

  static Future<List<int>> runningPids(PlatformKind provider) async {
    final matchers = _processMatchers(provider);
    final pids = <int>{};
    if (Platform.isWindows) {
      for (final image in matchers) {
        try {
          final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $image', '/NH']);
          if (result.exitCode != 0) continue;
          for (final line in const LineSplitter().convert(result.stdout as String)) {
            final match = RegExp('^${RegExp.escape(image)}\\s+(\\d+)', caseSensitive: false).firstMatch(line.trim());
            if (match != null) pids.add(int.parse(match.group(1)!));
          }
        } catch (_) {
          continue;
        }
      }
      return pids.toList();
    }
    for (final pattern in matchers) {
      try {
        final result = await Process.run('pgrep', ['-f', pattern]);
        if (result.exitCode != 0) continue;
        for (final line in const LineSplitter().convert(result.stdout as String)) {
          final pid = int.tryParse(line.trim());
          if (pid != null) pids.add(pid);
        }
      } catch (_) {
        continue;
      }
    }
    pids.remove(pid);
    return pids.toList();
  }

  /// 只判断进程是否还活着：Linux 直接看 `/proc`，避免每次轮询都 spawn `pgrep`。
  static bool _alive(int pid) {
    if (Platform.isLinux) return File('/proc/$pid/stat').existsSync();
    if (Platform.isMacOS) {
      try {
        return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    return true; // Windows 由 runningPids 统一判断
  }

  /// Electron 的子进程（renderer / zygote / gpu / utility）都带 `--type=`。
  /// 真正会在退出时回写 storage.json 的是主进程，等它退出即可，不必等整棵树。
  static bool _isMainProcess(int pid) {
    if (!Platform.isLinux) return true;
    try {
      final cmdline = String.fromCharCodes(File('/proc/$pid/cmdline').readAsBytesSync());
      return !cmdline.contains('--type=');
    } catch (_) {
      return true;
    }
  }

  static Future<List<int>> _waitLocal(List<int> pids, Duration limit) async {
    final deadline = DateTime.now().add(limit);
    var left = pids.where(_alive).toList();
    while (left.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      left = left.where(_alive).toList();
    }
    return left;
  }

  /// 完全退出客户端；返回仍在运行的主进程 PID（空表示已退出，可以安全写入）。
  static Future<List<int>> stop(PlatformKind provider) async {
    final initial = await runningPids(provider);
    if (initial.isEmpty) return const [];

    if (Platform.isWindows) {
      for (final image in _processMatchers(provider)) {
        try {
          await Process.run('taskkill', ['/IM', image, '/T', '/F']);
        } catch (_) {
          continue;
        }
      }
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(deadline)) {
        final left = await runningPids(provider);
        if (left.isEmpty) return const [];
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      return await runningPids(provider);
    }

    final mains = initial.where(_isMainProcess).toList();
    final targets = mains.isEmpty ? initial : mains;

    for (final pid in initial) {
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {
        continue;
      }
    }
    if ((await _waitLocal(targets, const Duration(milliseconds: 2500))).isEmpty) return const [];

    for (final pid in initial) {
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {
        continue;
      }
    }
    return _waitLocal(mains.isEmpty ? initial : mains, const Duration(milliseconds: 1200));
  }

  /// 以脱离方式启动客户端，不继承本进程的生命周期。
  static Future<void> launch(String executable) async {
    if (Platform.isMacOS) {
      final match = RegExp(r'^(.*\.app)/Contents/MacOS/').firstMatch(executable);
      if (match != null) {
        await Process.start('open', ['-a', match.group(1)!], mode: ProcessStartMode.detached);
        return;
      }
    }
    await Process.start(executable, const [], mode: ProcessStartMode.detached, workingDirectory: p.dirname(executable));
  }

  // ---------------------------------------------------------------------------
  // 文件
  // ---------------------------------------------------------------------------

  /// 原子写入：同目录临时文件 + rename，并保留原文件权限位。
  static void writeAtomic(String target, String content) {
    final file = File(target);
    var mode = 0x180; // 0o600
    try {
      mode = file.statSync().mode & 0x1FF;
    } catch (_) {
      // 文件尚不存在
    }
    final tmp = File('$target.tmp-$pid');
    tmp.writeAsStringSync(content, flush: true);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', [mode.toRadixString(8), tmp.path]);
      } catch (_) {
        // 忽略：部分文件系统不支持权限位
      }
    }
    tmp.renameSync(target);
  }

  /// 备份登录态文件，返回备份路径。
  static String backup(String target) {
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final path = '$target.bak-$stamp';
    File(target).copySync(path);
    return path;
  }
}
