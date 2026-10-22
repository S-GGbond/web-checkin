import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'dbus/secret_service.dart';

/// 读取浏览器登录态失败。
class QoderCookieException implements Exception {
  QoderCookieException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一份从浏览器里捞出来的 qoder 会话。
class QoderBrowserSession {
  const QoderBrowserSession({
    required this.cookie,
    required this.browser,
    required this.dbPath,
  });

  final String cookie;

  /// 浏览器显示名，例如 Chrome / Chromium。
  final String browser;

  /// 命中的 Cookies 库路径，便于在界面上说清来源。
  final String dbPath;
}

/// 从 Chrome 系浏览器的 Cookies 库解出 qoder.cn 的登录态。
///
/// 与 qoder-checkin/web_usage.py 同一套链路：
///   钥匙环里的 "Safe Storage" 口令 → PBKDF2-HMAC-SHA1(saltysalt, 1 轮, 16B)
///   → AES-128-CBC（IV 为 16 个空格）解密 v11 条目；v10 条目用固定口令 peanuts。
/// 明文前 32 字节是 SHA256(host_key)，取到后要去掉。
class QoderBrowserCookies {
  QoderBrowserCookies._();

  /// qoder 域下需要收集的 host。
  static const hosts = <String>[
    '.qoder.cn',
    'qoder.cn',
    '.qoder.com.cn',
    'qoder.com.cn',
  ];

  /// 只在这两个平台自动读取；Windows 的 DPAPI 需要另一套解密，暂不支持。
  static bool get supported => Platform.isLinux || Platform.isMacOS;

  static const _salt = 'saltysalt';
  static const _iv = '                '; // 16 个空格

  /// 扫描本机浏览器，返回第一个能解出 qoder_session_cookie 的会话。
  ///
  /// [keys] 只在测试里用：直接给口令，跳过钥匙环。
  static Future<QoderBrowserSession> load({
    String? profilePath,
    List<Uint8List>? keys,
  }) async {
    final sessions = await loadAll(profilePath: profilePath, keys: keys);
    return sessions.first;
  }

  /// 扫描本机所有浏览器配置，返回全部能解出 qoder 会话的库。
  ///
  /// 同一个浏览器的不同 Profile 可能登录着不同账号，登录后按 user_id 挑对应的那份。
  static Future<List<QoderBrowserSession>> loadAll({
    String? profilePath,
    List<Uint8List>? keys,
  }) async {
    if (!supported && keys == null) {
      throw QoderCookieException('当前平台不支持自动读取浏览器登录态，请手动填写 Cookie');
    }
    final secrets = keys ?? await _storageKeys();
    if (secrets.isEmpty) {
      throw QoderCookieException('未取到浏览器的 Safe Storage 口令，请先在本机浏览器登录 qoder.cn');
    }
    final candidates = profilePath == null
        ? await _defaultCandidates()
        : [(name: '自定义配置', path: profilePath)];
    if (candidates.isEmpty) {
      throw QoderCookieException('未找到 Chrome / Chromium / Edge 的 Cookies 库');
    }

    final failures = <String>[];
    final sessions = <QoderBrowserSession>[];
    for (final candidate in candidates) {
      try {
        final cookie = await _cookieFrom(candidate.path, secrets);
        if (cookie == null) {
          failures.add('${candidate.name}：没有 qoder.cn 的 Cookie');
          continue;
        }
        sessions.add(
          QoderBrowserSession(
            cookie: cookie,
            browser: candidate.name,
            dbPath: candidate.path,
          ),
        );
      } on QoderCookieException catch (error) {
        failures.add('${candidate.name}：${error.message}');
      } catch (error) {
        failures.add('${candidate.name}：$error');
      }
    }
    if (sessions.isEmpty) {
      throw QoderCookieException(
        failures.isEmpty
            ? '未找到可用的浏览器登录态'
            : '未找到可用的浏览器登录态：\n${failures.take(4).join('\n')}',
      );
    }
    return sessions;
  }

  /// 候选 Cookies 库：每个浏览器的 Default 与 Profile N。
  static Future<List<({String name, String path})>> _defaultCandidates() async {
    final home = Platform.environment['HOME'] ?? '';
    final roots = <({String name, String dir})>[];
    if (Platform.isMacOS) {
      final support = '$home/Library/Application Support';
      roots
        ..add((name: 'Chrome', dir: '$support/Google/Chrome'))
        ..add((name: 'Chrome Beta', dir: '$support/Google/Chrome Beta'))
        ..add((name: 'Chromium', dir: '$support/Chromium'))
        ..add((name: 'Edge', dir: '$support/Microsoft Edge'))
        ..add((name: 'Brave', dir: '$support/BraveSoftware/Brave-Browser'));
    } else {
      final env = Platform.environment['XDG_CONFIG_HOME'];
      final config = env != null && env.isNotEmpty ? env : '$home/.config';
      roots
        ..add((name: 'Chrome', dir: '$config/google-chrome'))
        ..add((name: 'Chrome Beta', dir: '$config/google-chrome-beta'))
        ..add((name: 'Chromium', dir: '$config/chromium'))
        ..add((name: 'Edge', dir: '$config/microsoft-edge'))
        ..add((name: 'Brave', dir: '$config/BraveSoftware/Brave-Browser'))
        ..add((name: 'Chromium (snap)', dir: '$home/snap/chromium/common/chromium'));
    }

    final found = <({String name, String path})>[];
    for (final root in roots) {
      final dir = Directory(root.dir);
      if (!dir.existsSync()) continue;
      for (final profile in _profileNames(dir)) {
        final cookies = File('${root.dir}/$profile/Cookies');
        if (cookies.existsSync()) {
          found.add((name: root.name, path: cookies.path));
        }
      }
    }
    return found;
  }

  static List<String> _profileNames(Directory root) {
    final names = <String>[];
    if (Directory('${root.path}/Default').existsSync()) names.add('Default');
    try {
      for (final entity in root.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final segments = entity.uri.pathSegments.where((s) => s.isNotEmpty);
        if (segments.isEmpty) continue;
        final name = segments.last;
        if (name.startsWith('Profile ')) names.add(name);
      }
    } catch (_) {
      // 读不到的目录直接跳过。
    }
    names.sort();
    return names;
  }

  /// 读 Cookies 库并拼出请求头；没有 qoder Cookie 时返回 null。
  static Future<String?> _cookieFrom(String path, List<Uint8List> keys) async {
    sqfliteFfiInit();
    final source = File(path);
    if (!source.existsSync()) {
      throw QoderCookieException('Cookies 库不存在：$path');
    }
    final tempDir = await Directory.systemTemp.createTemp('qoder-cookies-');
    final copy = File('${tempDir.path}/Cookies');
    try {
      await source.copy(copy.path);
      for (final suffix in const ['-wal', '-shm']) {
        final side = File('$path$suffix');
        if (side.existsSync()) {
          await side.copy('${copy.path}$suffix');
        }
      }

      final db = await databaseFactoryFfi.openDatabase(
        copy.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      late final List<Map<String, Object?>> rows;
      try {
        final placeholders = List.filled(hosts.length, '?').join(',');
        rows = await db.rawQuery(
          'SELECT host_key, name, value, encrypted_value, expires_utc FROM cookies '
          'WHERE host_key IN ($placeholders)',
          hosts,
        );
      } finally {
        await db.close();
      }
      if (rows.isEmpty) return null;

      // 同名 Cookie 保留「域名更长 / 过期更晚」的那条，和脚本一致。
      final jar = <String, ({int hostLength, int expires, String value})>{};
      for (final row in rows) {
        final host = (row['host_key'] ?? '').toString();
        final name = (row['name'] ?? '').toString();
        if (name.isEmpty) continue;
        final plain = (row['value'] ?? '').toString();
        String value;
        if (plain.isNotEmpty) {
          value = plain;
        } else {
          try {
            final decrypted = decrypt(
              Uint8List.fromList(_bytes(row['encrypted_value'])),
              keys,
            );
            value =
                utf8.decode(stripHostHash(host, decrypted), allowMalformed: true);
          } catch (_) {
            continue;
          }
        }
        final expires = (row['expires_utc'] as int?) ?? 0;
        final current = jar[name];
        final better = current == null ||
            host.length > current.hostLength ||
            (host.length == current.hostLength && expires > current.expires);
        if (better) {
          jar[name] = (hostLength: host.length, expires: expires, value: value);
        }
      }

      if (!jar.containsKey('qoder_session_cookie')) {
        throw QoderCookieException('解不出 qoder_session_cookie，请在浏览器重新登录 qoder.cn');
      }
      final names = jar.keys.toList()..sort();
      return names.map((name) => '$name=${jar[name]!.value}').join('; ');
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结果。
      }
    }
  }

  static List<int> _bytes(Object? value) {
    if (value is TypedData) {
      return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
    }
    if (value is List<int>) return value;
    if (value is String) return utf8.encode(value);
    return const [];
  }

  /// Chrome 系浏览器的 Safe Storage 口令（可能有多个，逐个尝试）。
  static Future<List<Uint8List>> _storageKeys() async {
    if (Platform.isMacOS) {
      return _macStorageKeys();
    }
    final SecretService service;
    try {
      service = await SecretService.connect();
    } on SecretServiceException catch (error) {
      throw QoderCookieException(error.message);
    }
    try {
      final keys = <Uint8List>[];
      for (final attributes in const [
        {'xdg:schema': 'chrome_libsecret_os_crypt_password_v2'},
        {'application': 'chrome'},
        {'application': 'chromium'},
      ]) {
        try {
          keys.addAll(await service.secretsFor(attributes));
        } on SecretServiceException {
          // 某个属性没命中就换下一个。
        }
      }
      return _unique(keys);
    } finally {
      await service.close();
    }
  }

  static Future<List<Uint8List>> _macStorageKeys() async {
    final keys = <Uint8List>[];
    for (final service in const [
      'Chrome Safe Storage',
      'Chromium Safe Storage',
    ]) {
      try {
        final result = await Process.run(
          'security',
          ['find-generic-password', '-w', '-s', service],
        );
        if (result.exitCode != 0) continue;
        final value = (result.stdout as String).trim();
        if (value.isNotEmpty) keys.add(Uint8List.fromList(utf8.encode(value)));
      } catch (_) {
        // 钥匙串里没有该条目。
      }
    }
    return _unique(keys);
  }

  static List<Uint8List> _unique(List<Uint8List> keys) {
    final seen = <String>{};
    return [
      for (final key in keys)
        if (seen.add(base64Encode(key))) key,
    ];
  }

  /// PBKDF2-HMAC-SHA1(口令, "saltysalt", 1 轮) → 16 字节 AES-128 密钥。
  static Uint8List deriveKey(List<int> secret) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
      ..init(Pbkdf2Parameters(utf8.encode(_salt), 1, 16));
    return derivator.process(Uint8List.fromList(secret));
  }

  /// 解密 Cookies 表里的 encrypted_value（v10 / v11 前缀）。
  ///
  /// [secrets] 是钥匙环里的 Safe Storage 口令明文，内部再派生成 AES 密钥。
  static Uint8List decrypt(Uint8List blob, List<Uint8List> secrets) {
    if (blob.length < 4) throw QoderCookieException('密文过短');
    final prefix = String.fromCharCodes(blob.sublist(0, 3));
    if (prefix != 'v10' && prefix != 'v11') {
      throw QoderCookieException('未知的加密前缀 $prefix');
    }
    final candidates = <List<int>>[
      if (prefix == 'v10') utf8.encode('peanuts'),
      ...secrets,
    ];
    final body = Uint8List.fromList(blob.sublist(3));
    Object? lastError;
    for (final secret in candidates) {
      try {
        return _unpad(_aesDecrypt(body, deriveKey(secret)));
      } catch (error) {
        lastError = error;
      }
    }
    throw QoderCookieException('Cookie 解密失败：$lastError');
  }

  /// 明文前 32 字节是 SHA256(host_key)，命中时去掉。
  static Uint8List stripHostHash(String host, Uint8List plain) {
    final digest = SHA256Digest().process(utf8.encode(host));
    if (plain.length < digest.length) return plain;
    for (var i = 0; i < digest.length; i++) {
      if (plain[i] != digest[i]) return plain;
    }
    return Uint8List.sublistView(plain, digest.length);
  }

  static Uint8List _aesDecrypt(Uint8List body, Uint8List key) {
    if (body.isEmpty || body.length % 16 != 0) {
      throw QoderCookieException('密文长度无效');
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), utf8.encode(_iv)));
    final output = Uint8List(body.length);
    for (var offset = 0; offset < body.length; offset += 16) {
      cipher.processBlock(body, offset, output, offset);
    }
    return output;
  }

  static Uint8List _unpad(Uint8List data) {
    if (data.isEmpty) throw QoderCookieException('密文为空');
    final pad = data.last;
    if (pad < 1 || pad > 16 || data.length < pad) {
      throw QoderCookieException('PKCS#7 填充无效');
    }
    for (var i = data.length - pad; i < data.length; i++) {
      if (data[i] != pad) throw QoderCookieException('PKCS#7 填充无效');
    }
    return Uint8List.sublistView(data, 0, data.length - pad);
  }
}
