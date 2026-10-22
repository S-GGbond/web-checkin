import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checkin_hub/src/services/qoder/qoder_browser_cookie.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 浏览器 Cookies 解密：与 web_usage.py 一致的 v10/v11 链路。
void main() {
  const secret = 'CYUoFec7xryWzbHx254AUg==';

  String hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List encrypt(String host, String value, List<int> password, {bool v10 = false}) {
    final key = QoderBrowserCookies.deriveKey(password);
    final plain = <int>[
      ...SHA256Digest().process(utf8.encode(host)),
      ...utf8.encode(value),
    ];
    final pad = 16 - plain.length % 16;
    plain.addAll(List.filled(pad, pad));

    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), utf8.encode('                ')));
    final out = Uint8List(plain.length);
    for (var offset = 0; offset < plain.length; offset += 16) {
      cipher.processBlock(Uint8List.fromList(plain), offset, out, offset);
    }
    return Uint8List.fromList([...utf8.encode(v10 ? 'v10' : 'v11'), ...out]);
  }

  test('PBKDF2 派生与脚本一致', () {
    expect(hex(QoderBrowserCookies.deriveKey(utf8.encode(secret))),
        '5dc741ded36f41d3345fefb77e073f7c');
    expect(hex(QoderBrowserCookies.deriveKey(utf8.encode('peanuts'))),
        'fd621fe5a2b402539dfa147ca9272778');
  });

  test('v11 密文可解出并去掉 host 摘要', () {
    final blob = encrypt('.qoder.cn', 'qoder-session-value', utf8.encode(secret));
    final plain = QoderBrowserCookies.decrypt(blob, [
      Uint8List.fromList(utf8.encode(secret)),
    ]);
    expect(utf8.decode(QoderBrowserCookies.stripHostHash('.qoder.cn', plain)),
        'qoder-session-value');
  });

  test('v10 用 peanuts 固定口令', () {
    final blob = encrypt('qoder.cn', 'legacy', utf8.encode('peanuts'), v10: true);
    // 传入无关口令也能解开，因为 v10 会先用 peanuts 试。
    final plain = QoderBrowserCookies.decrypt(blob, [
      Uint8List.fromList(utf8.encode('unrelated')),
    ]);
    expect(utf8.decode(QoderBrowserCookies.stripHostHash('qoder.cn', plain)), 'legacy');
  });

  test('未知前缀直接报错', () {
    final blob = Uint8List.fromList([...utf8.encode('v20'), 0, 0, 0, 0]);
    expect(
      () => QoderBrowserCookies.decrypt(blob, [Uint8List.fromList(utf8.encode(secret))]),
      throwsA(isA<QoderCookieException>()),
    );
  });

  test('从 Cookies 库挑出 qoder 会话并拼出请求头', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('qoder-cookie-test-');
    addTearDown(() => dir.delete(recursive: true));

    final dbPath = '${dir.path}/Cookies';
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, '
            'encrypted_value BLOB, expires_utc INTEGER)',
          );
        },
      ),
    );
    final password = Uint8List.fromList(utf8.encode(secret));
    await db.insert('cookies', {
      'host_key': '.qoder.cn',
      'name': 'qoder_session_cookie',
      'value': '',
      'encrypted_value': encrypt('.qoder.cn', 'session-v11', utf8.encode(secret)),
      'expires_utc': 100,
    });
    await db.insert('cookies', {
      'host_key': 'qoder.cn',
      'name': 'qoder_locale',
      'value': 'zh-CN',
      'encrypted_value': Uint8List(0),
      'expires_utc': 200,
    });
    // 不相关的域，不该出现在请求头里。
    await db.insert('cookies', {
      'host_key': '.example.com',
      'name': 'tracker',
      'value': 'x',
      'encrypted_value': Uint8List(0),
      'expires_utc': 300,
    });
    await db.close();

    final session = await QoderBrowserCookies.load(
      profilePath: dbPath,
      keys: [password],
    );
    expect(session.cookie, contains('qoder_session_cookie=session-v11'));
    expect(session.cookie, contains('qoder_locale=zh-CN'));
    expect(session.cookie, isNot(contains('tracker')));
  });

  test('没有 qoder_session_cookie 时报错提示重新登录', () async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('qoder-cookie-empty-');
    addTearDown(() => dir.delete(recursive: true));
    final dbPath = '${dir.path}/Cookies';
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, '
            'encrypted_value BLOB, expires_utc INTEGER)',
          );
        },
      ),
    );
    await db.insert('cookies', {
      'host_key': 'qoder.cn',
      'name': 'qoder_locale',
      'value': 'zh-CN',
      'encrypted_value': Uint8List(0),
      'expires_utc': 1,
    });
    await db.close();

    expect(
      () => QoderBrowserCookies.load(
        profilePath: dbPath,
        keys: [Uint8List.fromList(utf8.encode(secret))],
      ),
      throwsA(isA<QoderCookieException>().having(
        (error) => error.message,
        'message',
        contains('qoder_session_cookie'),
      )),
    );
  });
}
