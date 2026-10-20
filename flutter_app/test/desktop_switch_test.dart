import 'dart:convert';

import 'package:checkin_hub/src/services/desktop/desktop_switch_service.dart';
import 'package:checkin_hub/src/services/desktop/wb_envelope.dart';
import 'package:checkin_hub/src/services/trae/trae_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const usertagKey = 'iCubeAuthInfo://usertag';

  group('Trae 登录态归一化', () {
    test('补齐客户端判定登录态所必需的字段', () {
      final auth = <String, dynamic>{
        'userId': '1729960883004504',
        'userRegion': {'region': 'CN', '_aiRegion': 'CN'},
        'account': {
          'username': '用户0074481987',
          'scope': '',
          'loginScope': '',
          'storeRegion': '',
          'userTag': '',
        },
      };

      DesktopSwitchService.normalizeTraeAuth(auth);

      final account = auth['account'] as Map<String, dynamic>;
      expect(account['scope'], 'marscode');
      expect(account['loginScope'], 'trae');
      expect(account['storeRegion'], 'CN');
      expect(account['userTag'], 'cn');
      expect(account['migrateToSG'], false);
      expect(account['username'], '用户0074481987');
    });

    test('已有值不被覆盖', () {
      final auth = <String, dynamic>{
        'userRegion': {'region': 'US'},
        'account': {'scope': 'saas', 'storeRegion': 'US', 'userTag': 'usttp'},
      };

      DesktopSwitchService.normalizeTraeAuth(auth);

      final account = auth['account'] as Map<String, dynamic>;
      expect(account['scope'], 'saas');
      expect(account['storeRegion'], 'US');
      expect(account['userTag'], 'usttp');
    });
  });

  group('Trae usertag 同步', () {
    test('明文 usertag 补上目标账号，保留已有映射', () {
      final storage = <dynamic, dynamic>{
        usertagKey: jsonEncode({'2464446851333947': 'cn'}),
      };
      DesktopSwitchService.syncTraeUsertag(storage, {
        'userId': '1729960883004504',
        'userRegion': {'region': 'CN'},
      });

      final map = jsonDecode(storage[usertagKey] as String) as Map<String, dynamic>;
      expect(map['1729960883004504'], 'cn');
      expect(map['2464446851333947'], 'cn');
    });

    test('加密 usertag 写入后仍是加密容器', () {
      final storage = <dynamic, dynamic>{
        usertagKey: TraeCrypto.encrypt({'2464446851333947': 'cn'}),
      };
      DesktopSwitchService.syncTraeUsertag(storage, {
        'userId': '1729960883004504',
        'userRegion': {'region': 'CN'},
      });

      final value = storage[usertagKey] as String;
      expect(value.trimLeft().startsWith('{'), isFalse);
      final map = TraeCrypto.decrypt(value);
      expect(map['1729960883004504'], 'cn');
      expect(map['2464446851333947'], 'cn');
    });

    test('解不开的 usertag 保持原样，避免写坏客户端', () {
      final storage = <dynamic, dynamic>{usertagKey: 'not-a-container'};
      DesktopSwitchService.syncTraeUsertag(storage, {'userId': '1'});
      expect(storage[usertagKey], 'not-a-container');
    });
  });

  group('WbEnvelope', () {
    final key = WbEnvelope.deriveKey('test-secret');

    test('keyId 与客户端实现一致', () {
      expect(WbEnvelope.deriveKeyId(key), 'ffa162c03b605b4a');
    });

    test('能解开 Node 侧生成的信封（AAD 字节序互通）', () {
      const encoded =
          'eyJzdWl0ZSI6MSwia2V5SWQiOiJmZmExNjJjMDNiNjA1YjRhIiwibm9uY2UiOiI2dEhMSU1vb0dDekFVS0piIiwiYXV0aFRhZyI6'
          'Ik1zS0ZZcFJoK2F6NkxNZjUzd2puZlE9PSIsImNpcGhlcnRleHQiOiJUWmlsZGkwb0Zzcko1bExHWkd2NSJ9';
      final wrapped = {'\$wbEncrypted': 1, 'envelope': encoded};

      expect(WbEnvelope.isWrapped(wrapped), isTrue);
      expect(WbEnvelope.unwrap(wrapped, key), 'hello-workbuddy');
      // 密钥不匹配时应拒绝解密
      expect(() => WbEnvelope.unwrap(wrapped, WbEnvelope.deriveKey('other')), throwsA(anything));
    });

    test('本端加密的信封可自行解开', () {
      final sealed = WbEnvelope.seal('13800001111', key);
      expect(WbEnvelope.isWrapped(sealed), isTrue);
      expect(WbEnvelope.unwrap(sealed, key), '13800001111');
    });

    test('手机号掩码与客户端一致', () {
      expect(WbEnvelope.maskPhone('13800001111'), '138****1111');
      expect(WbEnvelope.maskPhone('138****1111'), '138****1111');
      expect(WbEnvelope.maskPhone('+86 13800001111'), '138****1111');
    });
  });
}
