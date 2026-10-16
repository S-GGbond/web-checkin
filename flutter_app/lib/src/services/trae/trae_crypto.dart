import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Trae 登录态加密容器，逐字节对齐 Python 版 `trae_tool.py` 的
/// `decrypt` / `encrypt`，确保与官方客户端、Python 端产物互通。
///
/// 结构：`base64( HEADER(6) + RANDOM_BLOCK(32) + AES-128-CBC( PKCS7 ) )`
/// 明文：`SHA512(payload)(64) + payload`
/// 密钥：`SHA512(SHA512(randomBlock) + SALT)` 的 [0:16] 与 [16:32] 作为 key / iv
class TraeCrypto {
  TraeCrypto._();

  static const List<int> _header = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00];
  static const int randomBlockLength = 32;
  static const int macLength = 64;

  static const List<int> _saltA = [
    82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251, 124, 227, 57, 130,
    155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203, 84, 123, 148, 50, 166, 194, 35, 61,
    238, 76, 149, 11, 66, 250, 195, 78, 8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109,
    139, 209, 37,
  ];

  static const List<int> _saltB = [
    31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95, 96, 81, 127, 169, 25,
    181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239, 160, 224, 59, 77, 174, 42, 245, 176,
    200, 235, 187, 60, 131, 83, 153, 97, 23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99,
    85, 33, 12, 125,
  ];

  static final Uint8List _salt = _buildSalt();

  static final SecureRandom _random = _createRandom();

  static Uint8List _buildSalt() {
    final salt = Uint8List(_saltA.length);
    for (var i = 0; i < _saltA.length; i++) {
      salt[i] = (_saltA[i] ^ _saltB[i]) & 0xFF;
    }
    return salt;
  }

  static SecureRandom _createRandom() {
    final seed = Uint8List(32);
    final rng = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = rng.nextInt(256);
    }
    return FortunaRandom()..seed(KeyParameter(seed));
  }

  static Uint8List randomBytes(int length) => _random.nextBytes(length);

  /// 供 RSA 密钥生成复用的安全随机源（pointycastle 的 `SecureRandom()`
  /// 工厂依赖全局注册表，这里显式传入已播种的 Fortuna 实例）。
  static SecureRandom get secureRandom => _random;

  static Uint8List sha512(List<int> data) =>
      Uint8List.fromList(SHA512Digest().process(Uint8List.fromList(data)));

  static (Uint8List key, Uint8List iv) _deriveKey(List<int> randomBlock) {
    if (randomBlock.length != randomBlockLength) {
      throw ArgumentError('随机块长度必须为 $randomBlockLength');
    }
    final inner = sha512(randomBlock);
    final finalHash = sha512([...inner, ..._salt]);
    return (finalHash.sublist(0, 16), finalHash.sublist(16, 32));
  }

  static PaddedBlockCipher _cipher(bool forEncryption, Uint8List key, Uint8List iv) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(
      forEncryption,
      PaddedBlockCipherParameters<CipherParameters?, CipherParameters?>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
    return cipher;
  }

  static String encrypt(Map<String, dynamic> auth) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(auth)));
    final mac = sha512(payload);
    final randomBlock = randomBytes(randomBlockLength);
    final (key, iv) = _deriveKey(randomBlock);
    final encrypted = _cipher(true, key, iv).process(Uint8List.fromList([...mac, ...payload]));
    return base64.encode([..._header, ...randomBlock, ...encrypted]);
  }

  static Map<String, dynamic> decrypt(String encoded) {
    final data = Uint8List.fromList(base64.decode(encoded));
    if (data.length < 6 + randomBlockLength + 16) {
      throw const FormatException('Trae 登录态数据过短');
    }
    for (var i = 0; i < _header.length; i++) {
      if (data[i] != _header[i]) {
        throw const FormatException('未知的 Trae 登录态加密格式');
      }
    }
    final randomBlock = data.sublist(6, 6 + randomBlockLength);
    final encrypted = data.sublist(6 + randomBlockLength);
    final (key, iv) = _deriveKey(randomBlock);
    final plain = _cipher(false, key, iv).process(encrypted);
    if (plain.length <= macLength) {
      throw const FormatException('Trae 登录态明文过短');
    }
    final storedMac = plain.sublist(0, macLength);
    final payload = plain.sublist(macLength);
    final actualMac = sha512(payload);
    for (var i = 0; i < macLength; i++) {
      if (storedMac[i] != actualMac[i]) {
        throw const FormatException('Trae 登录态完整性校验失败');
      }
    }
    final decoded = jsonDecode(utf8.decode(payload));
    if (decoded is! Map) {
      throw const FormatException('Trae 登录态内容不是 JSON 对象');
    }
    return decoded.cast<String, dynamic>();
  }

  /// PKCE code_verifier → S256 code_challenge。
  static String codeChallenge(String verifier) {
    final digest = SHA256Digest().process(Uint8List.fromList(utf8.encode(verifier)));
    return base64Url.encode(digest).replaceAll('=', '');
  }

  static String randomUrlSafe(int byteLength) {
    final bytes = randomBytes(byteLength);
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

/// 生成 RSA 公钥的 SPKI/PEM，用于 Trae `DeviceInfo.DevicePublicKey`。
/// 官方客户端会生成一对 2048 位 RSA 密钥并上送公钥。
class RsaPem {
  RsaPem._();

  static String generatePublicKeyPem({int bits = 2048}) {
    final generator = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), bits, 64),
        TraeCrypto.secureRandom,
      ));
    final pair = generator.generateKeyPair();
    final publicKey = pair.publicKey as RSAPublicKey;
    final modulus = publicKey.modulus;
    if (modulus == null) {
      throw StateError('RSA 公钥生成失败');
    }
    final spki = _subjectPublicKeyInfo(modulus, publicKey.publicExponent ?? BigInt.from(65537));
    return _pem('PUBLIC KEY', spki);
  }

  static Uint8List _subjectPublicKeyInfo(BigInt modulus, BigInt exponent) {
    // RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    final rsaPublicKey = _sequence([_integer(modulus), _integer(exponent)]);
    // AlgorithmIdentifier ::= SEQUENCE { OID rsaEncryption, NULL }
    final algorithm = _sequence([
      _oid([1, 2, 840, 113549, 1, 1, 1]),
      [0x05, 0x00],
    ]);
    // BIT STRING（首字节 0x00 表示无未使用位）
    final bitString = _bitString(rsaPublicKey);
    return _sequence([algorithm, bitString]);
  }

  static Uint8List _sequence(List<List<int>> parts) => _tagged(0x30, _concat(parts));

  static Uint8List _bitString(List<int> content) => _tagged(0x03, [0x00, ...content]);

  static Uint8List _integer(BigInt value) {
    var bytes = _unsignedBigEndian(value);
    if (bytes.isEmpty) bytes = [0x00];
    if ((bytes.first & 0x80) != 0) bytes = [0x00, ...bytes];
    return _tagged(0x02, bytes);
  }

  static Uint8List _oid(List<int> arcs) {
    final encoded = <int>[arcs[0] * 40 + arcs[1]];
    for (final arc in arcs.sublist(2)) {
      final stack = <int>[arc & 0x7F];
      var value = arc >> 7;
      while (value > 0) {
        stack.insert(0, (value & 0x7F) | 0x80);
        value >>= 7;
      }
      encoded.addAll(stack);
    }
    return _tagged(0x06, encoded);
  }

  static Uint8List _tagged(int tag, List<int> content) {
    return Uint8List.fromList([tag, ..._encodeLength(content.length), ...content]);
  }

  static List<int> _encodeLength(int length) {
    if (length < 0x80) return [length];
    final bytes = <int>[];
    var value = length;
    while (value > 0) {
      bytes.insert(0, value & 0xFF);
      value >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  static List<int> _unsignedBigEndian(BigInt value) {
    if (value == BigInt.zero) return [0x00];
    final bytes = <int>[];
    var current = value;
    final mask = BigInt.from(0xFF);
    while (current > BigInt.zero) {
      bytes.insert(0, (current & mask).toInt());
      current = current >> 8;
    }
    return bytes;
  }

  static List<int> _concat(List<List<int>> parts) {
    final out = <int>[];
    for (final part in parts) {
      out.addAll(part);
    }
    return out;
  }

  static String _pem(String label, List<int> der) {
    final base64Body = base64.encode(der);
    final buffer = StringBuffer('-----BEGIN $label-----\n');
    for (var i = 0; i < base64Body.length; i += 64) {
      final end = (i + 64 < base64Body.length) ? i + 64 : base64Body.length;
      buffer.write(base64Body.substring(i, end));
      buffer.write('\n');
    }
    buffer.write('-----END $label-----\n');
    return buffer.toString();
  }
}
