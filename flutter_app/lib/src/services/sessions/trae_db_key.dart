import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../models/account.dart';
import '../../util/app_paths.dart';
import '../desktop/desktop_client.dart';

/// Trae 会话加密库（`ModularData/ai-agent/database.db`）的密钥获取。
///
/// 该库是 SQLCipher v4，key 为 32 字节原始密钥，由客户端运行时生成、不落盘、
/// 也读不到启动参数 —— 只能从进程内存里抓 \`PRAGMA key = "x'<64hex>'"\`。
///
/// 取值顺序：手动/环境变量 → 本地缓存 → 运行中的 Trae 进程 → 拉起隔离实例。
/// 抓到后写入 \`~/.trae-sessions-key.json\`（与 trae-checkin 脚本共用同一份缓存，
/// 任一边抓过一次另一边就能直接用）。
class TraeDbKey {
  TraeDbKey._();

  /// 手动指定密钥的环境变量。
  static const String envVar = 'TRAE_DB_KEY';

  static const String _cacheName = '.trae-sessions-key.json';
  static final Uint8List _pattern = Uint8List.fromList(
    utf8.encode('PRAGMA key = "x\''),
  );
  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

  /// 硬失败（无权限读内存）的 pid，避免反复重试。
  static final Set<int> _denied = <int>{};

  static bool isKey(String? value) => value != null && _hex64.hasMatch(value);

  static File cacheFile() => File(p.join(AppPaths.home, _cacheName));

  static String? fromEnvironment() {
    final value = Platform.environment[envVar];
    return isKey(value) ? value : null;
  }

  static String? fromCache() {
    try {
      final file = cacheFile();
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final key = decoded['key']?.toString();
      return isKey(key) ? key : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveCache(String key, String dbPath) async {
    try {
      final file = cacheFile();
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'key': key,
          'db': dbPath,
          'captured_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (_) {
      // 缓存失败不影响本次使用。
    }
  }

  /// 依次尝试各处来源，返回能解开 [dbPath] 的 key；全部失败返回 null。
  ///
  /// [validate] 用来校验候选 key 是否真的能解开当前库（通常是解第一页看 SQLite 头）。
  static Future<String?> resolve({
    required String dbPath,
    String? manual,
    bool Function(String key)? validate,
    void Function(String message)? log,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    bool ok(String key) => validate?.call(key) ?? true;

    // 手动指定的 key 只认它自己：无效就直接失败，不去猜别的来源。
    if (manual != null) return ok(manual) ? manual : null;

    for (final source in <String?>[fromEnvironment(), fromCache()]) {
      if (!isKey(source)) continue;
      if (ok(source!)) {
        log?.call('使用已缓存的密钥');
        return source;
      }
      log?.call('已有密钥解不开当前库，重新抓取');
    }

    final deadline = DateTime.now().add(timeout);
    var key = await _captureFromRunning(log);
    if (key != null && ok(key)) {
      await saveCache(key, dbPath);
      return key;
    }

    if (DateTime.now().isBefore(deadline)) {
      key = await _captureBySpawning(log, deadline);
      if (key != null && ok(key)) {
        await saveCache(key, dbPath);
        return key;
      }
      if (key != null) log?.call('抓到的密钥解不开当前库（库可能来自其它机器）');
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // 进程枚举
  // ---------------------------------------------------------------------------

  static Future<List<int>> _traePids() async {
    if (Platform.isLinux) {
      final pids = <int>[];
      try {
        for (final entity in Directory('/proc').listSync()) {
          final pid = int.tryParse(p.basename(entity.path));
          if (pid == null) continue;
          try {
            final cmdline = File('/proc/$pid/cmdline').readAsStringSync();
            if (cmdline.toLowerCase().contains('trae')) pids.add(pid);
          } catch (_) {
            // 进程已退出。
          }
        }
      } catch (_) {
        // 没有 /proc。
      }
      return pids;
    }
    if (Platform.isMacOS) {
      try {
        final result = await Process.run('ps', ['-Ao', 'pid=,comm=']);
        return const LineSplitter()
            .convert(result.stdout.toString())
            .where((line) => line.contains('Trae'))
            .map((line) => int.tryParse(line.trim().split(RegExp(r'\s+')).first))
            .whereType<int>()
            .toList();
      } catch (_) {
        return const [];
      }
    }
    if (Platform.isWindows) {
      try {
        final result = await Process.run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-Process | Where-Object { \$_.Path -like '*Trae*' }).Id",
        ]);
        return result.stdout
            .toString()
            .split(RegExp(r'\s+'))
            .map(int.tryParse)
            .whereType<int>()
            .toList();
      } catch (_) {
        return const [];
      }
    }
    return const [];
  }

  /// Linux：枚举 [root] 的全部存活后代。隔离实例的 utility 子进程 cmdline
  /// 不一定带 user-data-dir，按 PPid 血缘找更稳。
  static List<int> _descendants(int root) {
    final children = <int, List<int>>{};
    try {
      for (final entity in Directory('/proc').listSync()) {
        final pid = int.tryParse(p.basename(entity.path));
        if (pid == null) continue;
        try {
          final stat = File('/proc/$pid/stat').readAsStringSync();
          final match = RegExp(r'^\d+ \(.+\) (\w) (\d+)').firstMatch(stat);
          if (match == null || match.group(1) == 'Z') continue;
          final ppid = int.tryParse(match.group(2)!);
          if (ppid == null) continue;
          children.putIfAbsent(ppid, () => <int>[]).add(pid);
        } catch (_) {
          // 进程已退出。
        }
      }
    } catch (_) {
      return const [];
    }

    final result = <int>[];
    final queue = <int>[root];
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      result.add(current);
      queue.addAll(children[current] ?? const []);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 内存扫描
  // ---------------------------------------------------------------------------

  /// 在缓冲区里找 \`PRAGMA key = "x'<64hex>'\`，返回紧随其后的 64 位十六进制。
  static String? keyIn(Uint8List buffer) {
    final limit = buffer.length - 80;
    for (var i = 0; i <= limit; i++) {
      if (buffer[i] != _pattern[0]) continue;
      var hit = true;
      for (var j = 1; j < _pattern.length; j++) {
        if (buffer[i + j] != _pattern[j]) {
          hit = false;
          break;
        }
      }
      if (!hit) continue;
      final hex = String.fromCharCodes(
        buffer.sublist(i + _pattern.length, i + _pattern.length + 64),
      );
      if (_hex64.hasMatch(hex)) return hex;
    }
    return null;
  }

  static Future<String?> _scanPids(
    List<int> pids,
    void Function(String)? log,
  ) async {
    final candidates = pids.where((pid) => !_denied.contains(pid)).toList();
    if (candidates.isEmpty) return null;

    if (Platform.isLinux) {
      for (final pid in candidates) {
        final key = await _scanLinuxProcMem(pid, log);
        if (key != null) return key;
      }
      return null;
    }
    if (Platform.isMacOS) {
      for (final pid in candidates) {
        final key = await _probeLldb(pid, log);
        if (key != null) return key;
      }
      return null;
    }
    if (Platform.isWindows) return _probePowerShell(candidates, log);
    return null;
  }

  /// Linux：遍历 `/proc/<pid>/maps` 的可写区，分块读 `/proc/<pid>/mem`。
  static Future<String?> _scanLinuxProcMem(
    int pid,
    void Function(String)? log,
  ) async {
    String maps;
    try {
      maps = File('/proc/$pid/maps').readAsStringSync();
    } catch (_) {
      return null;
    }

    RandomAccessFile mem;
    try {
      mem = await File('/proc/$pid/mem').open();
    } catch (_) {
      log?.call('pid $pid 内存不可读（Yama），不再重试');
      _denied.add(pid);
      return null;
    }

    const chunkSize = 64 * 1024 * 1024;
    try {
      for (final line in const LineSplitter().convert(maps)) {
        final match = RegExp(
          r'^([0-9a-f]+)-([0-9a-f]+) (....) ',
        ).firstMatch(line);
        if (match == null) continue;
        if (!match.group(3)!.startsWith('rw')) continue; // key 在堆/匿名可写区
        final start = int.parse(match.group(1)!, radix: 16);
        final end = int.parse(match.group(2)!, radix: 16);
        final size = end - start;
        if (size <= 0 || size > 1024 * 1024 * 1024) continue;

        for (var offset = 0; offset < size; offset += chunkSize) {
          final length = size - offset < chunkSize ? size - offset : chunkSize;
          try {
            await mem.setPosition(start + offset);
            final data = await mem.read(length);
            final key = keyIn(data);
            if (key != null) return key;
          } catch (_) {
            // 区域可能不可读（guard page / 已释放），跳到下一段。
          }
        }
      }
    } finally {
      try {
        await mem.close();
      } catch (_) {
        // 忽略。
      }
    }
    return null;
  }

  /// macOS：lldb attach 后在内存里找 pattern（需要 Xcode 命令行工具）。
  static Future<String?> _probeLldb(
    int pid,
    void Function(String)? log,
  ) async {
    final patternHex = _pattern
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    ProcessResult result;
    try {
      result = await Process.run('lldb', [
        '-b',
        '-p',
        '$pid',
        '-o',
        'memory find -e x -s $patternHex -v',
        '-o',
        'detach',
        '-o',
        'quit',
      ]);
    } catch (_) {
      return null;
    }
    final output = '${result.stdout}${result.stderr}';
    final direct = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(output);
    if (direct != null) return direct.group(0);
    if (RegExp(
      'attach failed|operation not permitted|unable to attach',
      caseSensitive: false,
    ).hasMatch(output)) {
      log?.call('pid $pid lldb attach 被拒，不再重试');
      _denied.add(pid);
      return null;
    }

    // 从 hex dump 重建：命中的 pattern 之后紧跟 64 个十六进制字符。
    final rows = <int, int>{};
    for (final match in RegExp(
      r'0x([0-9a-f]+):\s*((?:[0-9a-f]{2}\s*)+)',
    ).allMatches(output)) {
      final base = int.parse(match.group(1)!, radix: 16);
      final bytes = match.group(2)!.trim().split(RegExp(r'\s+'));
      for (var i = 0; i < bytes.length; i++) {
        rows[base + i] = int.parse(bytes[i], radix: 16);
      }
    }
    for (final match in RegExp(
      r'found at(?: address)?\s+(0x[0-9a-f]+)',
    ).allMatches(output)) {
      final address = int.parse(match.group(1)!.substring(2), radix: 16);
      final buffer = StringBuffer();
      for (var i = 16; i < 80; i++) {
        final byte = rows[address + i];
        if (byte == null) break;
        buffer.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      final hex = buffer.toString();
      if (_hex64.hasMatch(hex)) return hex;
    }
    return null;
  }

  /// Windows：PowerShell P/Invoke 调 ReadProcessMemory 扫可读区。
  static Future<String?> _probePowerShell(
    List<int> pids,
    void Function(String)? log,
  ) async {
    if (pids.isEmpty) return null;
    final script = _powerShellProbe.replaceAll('@PIDS@', pids.join(','));
    String out;
    try {
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        '-',
      ]);
      process.stdin.write(script);
      await process.stdin.close();
      out = await process.stdout.transform(utf8.decoder).join();
      await process.stderr.drain<void>();
    } catch (_) {
      return null;
    }
    final match = RegExp(r'\b[0-9a-fA-F]{64}\b').firstMatch(out);
    if (match == null) log?.call('Windows 内存扫描未命中');
    return match?.group(0);
  }

  // ---------------------------------------------------------------------------
  // 隔离实例
  // ---------------------------------------------------------------------------

  /// 扫描运行中的 Trae；没启动或被 Yama 拒绝时返回 null。
  static Future<String?> _captureFromRunning(
    void Function(String)? log,
  ) async {
    final pids = await _traePids();
    if (pids.isEmpty) return null;
    return _scanPids(pids, log);
  }

  /// 拉起一个带独立 \`--user-data-dir\` 的 Trae 实例，扫它自己的后代进程。
  ///
  /// 本进程是它的祖先，Linux 的 Yama 允许读子进程内存；key 是机器级确定的，
  /// 抓一次缓存即可。无论成败都杀掉实例并清理临时目录。
  static Future<String?> _captureBySpawning(
    void Function(String)? log,
    DateTime deadline,
  ) async {
    final binary = await DesktopClient.executable(PlatformKind.trae);
    if (binary == null) {
      log?.call('找不到 Trae 可执行文件，无法抓取密钥');
      return null;
    }

    Directory? userDataDir;
    Process? process;
    try {
      userDataDir = await Directory.systemTemp.createTemp('trae-keycap-');
      process = await Process.start(binary, [
        '--user-data-dir=${userDataDir.path}',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-sync',
        '--disable-gpu',
        '--disable-crash-reporter',
        '--disable-features=Translate',
      ], mode: ProcessStartMode.detached);
      log?.call('已启动隔离 Trae 实例（pid ${process.pid}）抓取密钥');

      var emptyPolls = 0;
      while (DateTime.now().isBefore(deadline)) {
        final pids = Platform.isLinux
            ? _descendants(process.pid)
            : await _traePids();
        final key = await _scanPids(pids, log);
        if (key != null) {
          log?.call('在进程 [${pids.join(",")}] 内存中命中密钥');
          return key;
        }
        if (pids.length <= 1) {
          if (++emptyPolls >= 10) break; // 冷启动可能慢到 ~25s
        } else {
          emptyPolls = 0;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2500));
      }
      log?.call('隔离实例存活期间未在内存里找到密钥');
      return null;
    } catch (error) {
      log?.call('抓取密钥失败：$error');
      return null;
    } finally {
      if (process != null) {
        if (Platform.isWindows) {
          try {
            await Process.run('taskkill', [
              '/PID',
              '${process.pid}',
              '/T',
              '/F',
            ]);
          } catch (_) {
            // 忽略。
          }
        } else {
          try {
            Process.killPid(-process.pid, ProcessSignal.sigkill);
          } catch (_) {
            try {
              process.kill(ProcessSignal.sigkill);
            } catch (_) {
              // 忽略。
            }
          }
        }
      }
      try {
        await userDataDir?.delete(recursive: true);
      } catch (_) {
        // 忽略。
      }
    }
  }

  /// Windows 内存扫描脚本：OpenProcess + VirtualQueryEx + ReadProcessMemory。
  static const String _powerShellProbe = r'''
$ErrorActionPreference='SilentlyContinue'
Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public class TMem {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern IntPtr OpenProcess(int a,bool i,int p);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h,IntPtr a,byte[] b,IntPtr s,out IntPtr r);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool VirtualQueryEx(IntPtr h,IntPtr a,out MBI b,IntPtr l);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [StructLayout(LayoutKind.Sequential)] public struct MBI { public IntPtr BaseAddress; public IntPtr AllocationBase; public uint AllocationProtect; public IntPtr RegionSize; public uint State; public uint Protect; public uint Type; }
}
'@
$pat='PRAGMA key = "x'+[char]39
foreach($id in @(@PIDS@)){
  $h=[TMem]::OpenProcess(0x410,$false,$id); if($h -eq [IntPtr]::Zero){continue}
  $addr=0L
  while($true){
    $mbi=New-Object TMem+MBI
    $len=[Runtime.InteropServices.Marshal]::SizeOf($mbi)
    if(-not [TMem]::VirtualQueryEx($h,[IntPtr]$addr,[ref]$mbi,[IntPtr]$len)){break}
    $pr=$mbi.Protect
    $readable=($pr -eq 2 -or $pr -eq 4 -or $pr -eq 8 -or $pr -eq 0x20 -or $pr -eq 0x40 -or $pr -eq 0x80)
    if($mbi.State -eq 0x1000 -and $readable -and $mbi.RegionSize.ToInt64() -gt 0){
      $base=$mbi.BaseAddress.ToInt64(); $total=$mbi.RegionSize.ToInt64()
      if($total -gt 0x20000000){$total=0x20000000}
      $off=0L; $tail=''
      while($off -lt $total){
        $len2=[Math]::Min(0x1000000,$total-$off)
        $buf=New-Object byte[] ([int]$len2)
        $rd=[IntPtr]::Zero
        if([TMem]::ReadProcessMemory($h,[IntPtr]($base+$off),$buf,[IntPtr]$len2,[ref]$rd)){
          $s=$tail+[Text.Encoding]::ASCII.GetString($buf,0,[int]$rd)
          $i=$s.IndexOf($pat)
          if($i -ge 0 -and $i+80 -le $s.Length){
            $k=$s.Substring($i+16,64)
            if($k -match '^[0-9a-fA-F]{64}$'){Write-Output $k;[TMem]::CloseHandle($h);exit 0}
          }
          if($s.Length -gt 16){$tail=$s.Substring($s.Length-16)}else{$tail=$s}
        }else{$tail=''}
        $off+=$len2
      }
    }
    $next=$mbi.BaseAddress.ToInt64()+$mbi.RegionSize.ToInt64()
    if($next -le $addr -or $next -le 0){break}
    $addr=$next
  }
  [TMem]::CloseHandle($h)
}
exit 1
''';
}
