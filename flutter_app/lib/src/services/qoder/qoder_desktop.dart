import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../util/app_paths.dart';

/// Qoder 桌面端登录态（Linux）：Electron safeStorage（libsecret + AES-128-CBC）。
///
/// 解密/加密借系统钥匙环完成：调用 python3 的 secretstorage + cryptography，
/// 与 qoder-checkin 的 safe_storage.py 同一套参数（saltysalt / 16 个空格 IV / v11 前缀）。
class QoderDesktopAuth {
  QoderDesktopAuth._();

  static bool get supported => Platform.isLinux;

  /// 客户端主程序候选路径（Linux 安装包 / 手动解压都在这两处）。
  static const _executables = ['/usr/bin/qoder-cn', '/opt/Qoder CN/qoder-cn'];

  static String? executablePath() {
    for (final candidate in _executables) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// 解密一次要起一个 python 进程（约 0.3–0.8 秒），短时间内复用结果。
  static ({Map<String, dynamic>? data, DateTime at})? _readCache;
  static const _cacheTtl = Duration(seconds: 20);

  static void invalidate() => _readCache = null;

  static const String _helper = 'import sys, os, json, hashlib, tempfile\nimport secretstorage\nfrom cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes\nSALT = b\'saltysalt\'\nIV = b\' \' * 16\ndef keys():\n    bus = secretstorage.dbus_init()\n    out = []\n    for col in secretstorage.get_all_collections(bus):\n        if col.is_locked():\n            continue\n        for item in col.get_all_items():\n            a = item.get_attributes()\n            if a.get(\'xdg:schema\') != \'chrome_libsecret_os_crypt_password_v2\':\n                continue\n            if \'qoder\' not in str(a.get(\'application\') or \'\').lower():\n                continue\n            try:\n                out.append(hashlib.pbkdf2_hmac(\'sha1\', bytes(item.get_secret()), SALT, 1, 16))\n            except Exception:\n                pass\n    return out\nmode = sys.argv[1]\npath = sys.argv[2]\nks = keys()\nif not ks:\n    sys.stderr.write(\'keyring: no qoder entry\')\n    sys.exit(4)\nif mode == \'read\':\n    blob = open(path, \'rb\').read()\n    if blob.lstrip().startswith(b\'{\'):\n        print(blob.decode(\'utf-8\'))\n        sys.exit(0)\n    if blob[:3] not in (b\'v11\', b\'v10\'):\n        sys.stderr.write(\'bad prefix\')\n        sys.exit(2)\n    body = blob[3:]\n    for key in ks:\n        try:\n            dec = Cipher(algorithms.AES(key), modes.CBC(IV)).decryptor()\n            raw = dec.update(body) + dec.finalize()\n            pad = raw[-1]\n            if pad < 1 or pad > 16:\n                raise ValueError(\'pad\')\n            raw = raw[:-pad]\n            print(json.dumps(json.loads(raw.decode(\'utf-8\'))))\n            sys.exit(0)\n        except Exception:\n            continue\n    sys.stderr.write(\'decrypt failed\')\n    sys.exit(3)\npayload = json.load(sys.stdin)\nraw = json.dumps(payload, ensure_ascii=False, separators=(\',\', \':\')).encode(\'utf-8\')\npad = 16 - len(raw) % 16\nraw += bytes([pad]) * pad\nenc = Cipher(algorithms.AES(ks[0]), modes.CBC(IV)).encryptor()\nblob = b\'v11\' + enc.update(raw) + enc.finalize()\nfd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + \'.tmp-\', dir=os.path.dirname(path))\nwith os.fdopen(fd, \'wb\') as f:\n    f.write(blob)\nos.chmod(tmp, 0o600)\nos.replace(tmp, path)\n';

  static String? authFile() {
    for (final root in _roots()) {
      for (final name in const ['com.qodercn.app.stable', 'com.qodercn.app.canary']) {
        final path = p.join(root, name, 'auth.v1.dat');
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  static List<String> _roots() => [
        p.join(AppPaths.home, '.config'),
        p.join(AppPaths.home, 'Library', 'Application Support'),
      ];

  /// 读当前登录态；失败返回 null（客户端未登录 / 钥匙环不可用）。
  static Future<Map<String, dynamic>?> read({bool refresh = false}) async {
    if (!supported) return null;
    final cached = _readCache;
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < _cacheTtl) {
      return cached.data;
    }
    final path = authFile();
    if (path == null) return null;
    Map<String, dynamic>? data;
    final run = await _python(['read', path]);
    if (run != null && run.code == 0) {
      try {
        final decoded = jsonDecode(run.out);
        if (decoded is Map) data = decoded.cast<String, dynamic>();
      } catch (_) {
        data = null;
      }
    }
    _readCache = (data: data, at: DateTime.now());
    return data;
  }

  /// 可用的 python 解释器：PATH 里的那个可能缺 secretstorage（conda 之外的发行版），
  /// 失败时退回系统 python3。
  static const _pythonCandidates = ['python3', '/usr/bin/python3', '/usr/local/bin/python3'];

  static Future<({int code, String out, String err})?> _python(
    List<String> args, {
    String? input,
  }) async {
    for (final exe in _pythonCandidates) {
      try {
        final process = await Process.start(exe, ['-c', _helper, ...args]);
        if (input != null) process.stdin.write(input);
        await process.stdin.close();
        final out = await process.stdout.transform(utf8.decoder).join();
        final err = await process.stderr.transform(utf8.decoder).join();
        final code = await process.exitCode;
        if (code == 0) return (code: code, out: out, err: err);
        final missing = err.contains('ModuleNotFoundError') ||
            err.contains('No module named') ||
            err.contains('No such file');
        if (!missing) return (code: code, out: out, err: err);
      } catch (_) {
        // 这个解释器跑不起来，换下一个。
      }
    }
    return null;
  }

  /// 读指定文件（测试 / 诊断用）。
  static Future<Map<String, dynamic>?> readFile(String path) async {
    try {
      final run = await Process.run('python3', ['-c', _helper, 'read', path]);
      if (run.exitCode != 0) return null;
      final decoded = jsonDecode(run.stdout.toString());
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 写到指定文件（测试 / 诊断用）；返回备份路径。
  static Future<String> writeTo(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 14);
    final backup = '$path.bak-$stamp';
    await File(path).copy(backup);
    final run = await _python(['write', path], input: jsonEncode(payload));
    if (run == null || run.code != 0) {
      throw QoderDesktopException('写入失败：${run?.err.trim() ?? '没有可用的 python3'}');
    }
    invalidate();
    return backup;
  }

  static Future<String> currentUid({bool refresh = false}) async {
    final data = await read(refresh: refresh);
    final user = (data?['user'] as Map?) ?? const {};
    return (user['id'] ?? '').toString();
  }

  /// 写入登录态：先备份 auth.v1.dat，再原子替换。
  static Future<String> write(Map<String, dynamic> payload) async {
    if (!supported) {
      throw const QoderDesktopException('Qoder 换号目前只支持 Linux');
    }
    final path = authFile();
    if (path == null) {
      throw const QoderDesktopException('没有找到 Qoder 桌面端 auth.v1.dat');
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp('[:.T-]'), '')
        .substring(0, 14);
    final backup = '$path.bak-$stamp';
    await File(path).copy(backup);
    try {
      final run = await _python(['write', path], input: jsonEncode(payload));
      if (run == null || run.code != 0) {
        throw QoderDesktopException(
          '写入 Qoder 登录态失败：${run?.err.trim() ?? '没有可用的 python3'}',
        );
      }
      invalidate();
      return backup;
    } catch (error) {
      try {
        await File(backup).copy(path);
      } catch (_) {
        // 忽略。
      }
      rethrow;
    }
  }

  static Future<List<int>> runningPids() async {
    if (!supported) return const [];
    try {
      final run = await Process.run('pgrep', ['-f', 'qoder-cn']);
      return run.stdout
          .toString()
          .split(RegExp(r"\s+"))
          .where((value) => int.tryParse(value) != null)
          .map(int.parse)
          .where(_isQoderProcess)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 真正的 Qoder 进程才算「在运行」。
  ///
  /// - 排除僵尸进程：被 kill 后父进程还没回收时 pgrep 仍会列出来；
  /// - 用 `/proc/<pid>/exe` 核对，避免命令行里恰好带 qoder-cn 的无关进程被误判。
  static bool _isQoderProcess(int pid) {
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      final close = stat.lastIndexOf(')');
      if (close >= 0 && close + 2 < stat.length && stat[close + 2] == 'Z') {
        return false;
      }
    } catch (_) {
      return false;
    }
    try {
      // 只看可执行文件路径：命令行里恰好带 qoder-cn 的无关进程（编辑器、脚本）不能被当成客户端。
      final exe =
          File('/proc/$pid/exe').resolveSymbolicLinksSync().toLowerCase();
      return exe.contains('qoder');
    } catch (_) {
      return false;
    }
  }

  /// 结束客户端：先 TERM 并轮询，超时再 KILL。
  ///
  /// 之前只等 600ms 就判定「仍在运行」，Electron 退出慢时会误报失败——客户端其实
  /// 已经关掉了，用户再点一次才成功。现在按真实退出情况返回。
  static Future<bool> stop({
    Duration graceful = const Duration(seconds: 6),
    Duration forced = const Duration(seconds: 3),
  }) async {
    var pids = await runningPids();
    if (pids.isEmpty) return true;
    _signal(pids, ProcessSignal.sigterm);
    if (await _waitGone(graceful)) return true;
    pids = await runningPids();
    if (pids.isNotEmpty) _signal(pids, ProcessSignal.sigkill);
    return _waitGone(forced);
  }

  /// 直接给确认过的 pid 发信号（比 pkill -f 精确，不会牵连命令行里恰好带关键字的进程）。
  static void _signal(List<int> pids, ProcessSignal signal) {
    for (final pid in pids) {
      try {
        Process.killPid(pid, signal);
      } catch (_) {
        // 进程刚好退出：忽略。
      }
    }
  }

  static Future<bool> _waitGone(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if ((await runningPids()).isEmpty) return true;
    }
    return (await runningPids()).isEmpty;
  }

  static Future<void> launch() async {
    for (final candidate in [?executablePath(), ..._executables]) {
      if (File(candidate).existsSync()) {
        await Process.start(candidate, const [], mode: ProcessStartMode.detached);
        return;
      }
    }
  }
}

class QoderDesktopException implements Exception {
  const QoderDesktopException(this.message);

  final String message;

  @override
  String toString() => message;
}
