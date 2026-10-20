import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// WorkBuddy 桌面端 `$wbEncrypted` 信封（AES-256-GCM）。
///
/// 逆向自 `app.asar!/main/app-lifetime-job.js`（AtRestCrypto），
/// 与 `tools/desktop-auth/lib/crypto-wb.mjs` 保持同一实现：
///
/// ```text
/// key    = SHA-256(atRestSecretKey)
/// keyId  = hex(SHA-256(key))[0:16]
/// AAD    = "WB-AAD\0" | 0x01 | lp("WBEV1") | lp("sym-v1") | uint32be(1) | lp(keyId) | 0x02 | 0x00 | 0x00
/// 信封   = base64( json{ suite:1, keyId, nonce, authTag, ciphertext } )
/// ```
class WbEnvelope {
  WbEnvelope._();

  static const String _formatId = 'WBEV1';
  static const String _scheme = 'sym-v1';
  static const int _framingField = 2;
  static const int _suite = 1;
  static const int _nonceLength = 12;
  static const int _tagLength = 16;

  static final Uint8List _aadDomain = Uint8List.fromList(ascii.encode('WB-AAD\x00'));

  static final Random _random = Random.secure();

  /// `atRestSecretKey` → 32 字节 AES key。
  static Uint8List deriveKey(String atRestSecretKey) =>
      _sha256(Uint8List.fromList(utf8.encode(atRestSecretKey)));

  static String deriveKeyId(Uint8List key) =>
      _hex(_sha256(key)).substring(0, 16);

  static Uint8List _sha256(Uint8List data) =>
      Uint8List.fromList(SHA256Digest().process(data));

  static String _hex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _uint32(int value) {
    final buffer = ByteData(4)..setUint32(0, value);
    return buffer.buffer.asUint8List();
  }

  static Uint8List _lengthPrefixed(String value) {
    final bytes = Uint8List.fromList(utf8.encode(value));
    return Uint8List.fromList([..._uint32(bytes.length), ...bytes]);
  }

  static Uint8List buildAad(String keyId) => Uint8List.fromList([
        ..._aadDomain,
        0x01,
        ..._lengthPrefixed(_formatId),
        ..._lengthPrefixed(_scheme),
        ..._uint32(_suite),
        ..._lengthPrefixed(keyId),
        _framingField,
        0x00, // optional uint64 缺失
        0x00,
      ]);

  /// 加密成客户端同款信封值：`{"$wbEncrypted":1,"envelope":"..."}`。
  static Map<String, Object?> seal(String plain, Uint8List key) {
    final keyId = deriveKeyId(key);
    final nonce = Uint8List.fromList(List<int>.generate(_nonceLength, (_) => _random.nextInt(256)));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), _tagLength * 8, nonce, buildAad(keyId)));
    final sealed = cipher.process(Uint8List.fromList(utf8.encode(plain)));
    final tagStart = sealed.length - _tagLength;
    final envelope = <String, Object?>{
      'suite': _suite,
      'keyId': keyId,
      'nonce': base64.encode(nonce),
      'authTag': base64.encode(sealed.sublist(tagStart)),
      'ciphertext': base64.encode(sealed.sublist(0, tagStart)),
    };
    return {
      '\$wbEncrypted': 1,
      'envelope': base64.encode(utf8.encode(jsonEncode(envelope))),
    };
  }

  static bool isWrapped(Object? value) =>
      value is Map && value['envelope'] is String && value.containsKey('\$wbEncrypted');

  /// 解出信封明文；非信封值原样返回。
  static String? unwrap(Object? value, Uint8List? key) {
    if (!isWrapped(value)) return value?.toString();
    if (key == null) return null;
    final envelope = jsonDecode(
      utf8.decode(base64.decode((value as Map)['envelope'] as String)),
    ) as Map<String, dynamic>;
    final keyId = envelope['keyId'] as String;
    if (keyId != deriveKeyId(key)) throw const FormatException('keyId 不匹配');
    final nonce = base64.decode(envelope['nonce'] as String);
    final tag = base64.decode(envelope['authTag'] as String);
    final ciphertext = base64.decode(envelope['ciphertext'] as String);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), _tagLength * 8, nonce, buildAad(keyId)));
    final plain = cipher.process(Uint8List.fromList([...ciphertext, ...tag]));
    return utf8.decode(plain);
  }

  /// 与客户端一致：手机号按掩码形态落盘。
  static String maskPhone(String value) {
    if (value.contains('*')) return value;
    var digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 13 && digits.startsWith('86')) digits = digits.substring(2);
    if (digits.length == 11) return '${digits.substring(0, 3)}****${digits.substring(7)}';
    if (digits.length >= 7) return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
    return value;
  }
}
