import 'dart:convert';

import 'package:checkin_hub/src/services/trae/trae_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 Python 端 `trae_tool.py` 的加密容器逐字节互通的验证。
void main() {
  // 该字符串由 Python 版 TraeTool.encrypt 生成，明文见 _pythonPayload。
  const pythonEncoded =
      'dGMFEAAAh4WQyjhfwZeShRrJyKC1FqBNrQoGsyh9ch/iUE41F0cG1x7EOYisFGPRHiXUNK+ssW4tPsRdp6mJtBy3u4yRyMnsszNmBIQ7psntImJpE6UZpryvOj7WR06M3vX9ECV9/PhsMh0LS0sv3tWEUZvq17FJPUGWhx1luF86HO0Y2yxksou1LYUQqj1gCRYs9KFDhT5wQl98jtVlAdeUQy0B6iDTcSgxqwvRE6Q/ws/7Fob8cdzjMCxI7iydAH9Mii712HJtdsL1wlAbuedDk3ZtYdJ1GiGunbmLVRQ9Nit7B8qck5lVWqKKcDzl6ejp+DMHZa8XOJVO+NLRsD+6WSIL8A5MP1pckv8ykJsnsBmeNurP1bggYjq2S0ukLAIR74oSdTnkB16mVmOcX9VMcBYr7B9HIs4pl11xocnz9gQ08X5XrBdOVeBxYiIYSd9wPvmPOgyhgscxlEDSF10Grv1/zNcN/JHl15PM2bk6t+H1n54dAspDCYQYZ+GEHDl1SoIrfTi/2D1WGSjTJp2Uz9zuG1lc62/B9fOQqUSHUHTY7B/SVDSMsbbVJTM+Lwv5boT7';

  const pythonPayload = {
    'token': 'tok-abc-123',
    'refreshToken': 'ref-def-456',
    'expiredAt': '2030-01-02T03:04:05Z',
    'refreshExpiredAt': '2031-01-02T03:04:05Z',
    'tokenReleaseAt': '2026-01-01T00:00:00Z',
    'userId': 'u-42',
    'host': 'https://api.trae.cn',
    'userRegion': {'region': 'CN', '_aiRegion': 'CN'},
    'account': {'username': '示例用户 ünïcode', 'email': 'a@b.c'},
  };

  test('可以解密 Python 端生成的登录态', () {
    final decoded = TraeCrypto.decrypt(pythonEncoded);

    expect(decoded['token'], 'tok-abc-123');
    expect(decoded['refreshToken'], 'ref-def-456');
    expect(decoded['userId'], 'u-42');
    expect((decoded['account'] as Map)['username'], '示例用户 ünïcode');
    expect((decoded['userRegion'] as Map)['_aiRegion'], 'CN');
    expect(jsonEncode(decoded), jsonEncode(pythonPayload));
  });

  test('自加密后可自解密（含中文与嵌套结构）', () {
    final encoded = TraeCrypto.encrypt(pythonPayload);
    final decoded = TraeCrypto.decrypt(encoded);

    expect(decoded['token'], 'tok-abc-123');
    expect((decoded['account'] as Map)['email'], 'a@b.c');
    expect(decoded.keys.toSet(), pythonPayload.keys.toSet());
  });

  test('同一明文两次加密结果不同（随机块），但都能解回', () {
    final first = TraeCrypto.encrypt(pythonPayload);
    final second = TraeCrypto.encrypt(pythonPayload);

    expect(first, isNot(equals(second)));
    expect(TraeCrypto.decrypt(first)['userId'], TraeCrypto.decrypt(second)['userId']);
  });

  test('篡改密文会触发完整性校验失败', () {
    final encoded = TraeCrypto.encrypt(pythonPayload);
    final bytes = base64.decode(encoded);
    // 改动密文最后一个字节。
    bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0x01;
    final tampered = base64.encode(bytes);

    expect(() => TraeCrypto.decrypt(tampered), throwsA(anything));
  });

  test('PKCE code_challenge 符合 S256 规范', () {
    // RFC 7636 附录 B 的示例向量。
    const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    expect(TraeCrypto.codeChallenge(verifier), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  test('RSA 公钥以 SPKI/PEM 形式输出', () {
    final pem = RsaPem.generatePublicKeyPem(bits: 1024);
    expect(pem.startsWith('-----BEGIN PUBLIC KEY-----'), isTrue);
    expect(pem.contains('-----END PUBLIC KEY-----'), isTrue);
    // 去掉头尾与换行后应是合法 base64，且 DER 以 SEQUENCE 开头（0x30）。
    final body = pem
        .replaceAll('-----BEGIN PUBLIC KEY-----', '')
        .replaceAll('-----END PUBLIC KEY-----', '')
        .replaceAll('\n', '');
    final der = base64.decode(body);
    expect(der.first, 0x30);
  });
}
