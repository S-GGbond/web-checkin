import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// SQLCipher v4 页格式的加解密（Trae 会话库 database.db）。
///
/// 布局（page_size = 4096，reserve = 80）：
/// - 文件头前 16 字节是 salt，第 1 页密文从偏移 16 开始，其余页整页密文
/// - 每页 IV 在 4016..4032，HMAC-SHA512 在 4032..4096
/// - hmac_key = PBKDF2-HMAC-SHA512(key, salt 逐字节⊕0x3a, 2 轮, 32 字节)
/// - 页 MAC 覆盖 密文||IV||小端页号（第 1 页密文从偏移 16 起算）
///
/// key 是 32 字节原始密钥，免 PBKDF2 拉伸。
class TraeDbCipher {
  TraeDbCipher._();

  static const int pageSize = 4096;
  static const int ivOffset = 4016;
  static const int macOffset = 4032;
  static const int usable = 4016;
  static const int reserve = 80;

  static const int _hmacSaltMask = 0x3a;
  static final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
  static final Uint8List magic = Uint8List.fromList([
    ...latin1.encode('SQLite format 3'),
    0,
  ]);

  static bool isKey(String? value) => value != null && _hex64.hasMatch(value);

  static Uint8List hexBytes(String hex) {
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// hmac_key = PBKDF2-HMAC-SHA512(key, salt⊕0x3a, 2 轮, 32B)
  static Uint8List hmacKeyOf(Uint8List key, Uint8List salt) {
    final masked = Uint8List(salt.length);
    for (var i = 0; i < salt.length; i++) {
      masked[i] = salt[i] ^ _hmacSaltMask;
    }
    final derivator = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))
      ..init(Pbkdf2Parameters(masked, 2, 32));
    return derivator.process(key);
  }

  static Uint8List _le32(int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setUint32(0, value, Endian.little);
    return bytes;
  }

  /// 逐页 MAC：覆盖 密文||IV||LE(pgno)，第 1 页密文从偏移 16 起算。
  static Uint8List pageMac(
    Uint8List hmacKey,
    Uint8List page,
    int pageOffset,
    int pgno,
  ) {
    final from = pageOffset + (pgno == 1 ? 16 : 0);
    final data = Uint8List.sublistView(page, from, pageOffset + macOffset);
    final hmac = HMac(SHA512Digest(), 128)..init(KeyParameter(hmacKey));
    hmac.update(data, 0, data.length);
    hmac.update(_le32(pgno), 0, 4);
    final mac = Uint8List(64);
    hmac.doFinal(mac, 0);
    return mac;
  }


  /// 解一页到 [target] 的 [targetOffset]，不校验 MAC（读路径用，快）。
  static void decryptPageInto(
    Uint8List key,
    Uint8List source,
    int sourceOffset,
    int pgno,
    Uint8List target,
    int targetOffset,
  ) {
    final iv = Uint8List.sublistView(
      source,
      sourceOffset + ivOffset,
      sourceOffset + ivOffset + 16,
    );
    final from = pgno == 1 ? 16 : 0;
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    for (var offset = from; offset < usable; offset += 16) {
      cipher.processBlock(
        source,
        sourceOffset + offset,
        target,
        targetOffset + offset,
      );
    }
    if (pgno == 1) target.setRange(targetOffset, targetOffset + 16, magic);
  }

  /// 解一页并校验 MAC（自校验用）。
  static Uint8List decryptPageVerified(
    Uint8List key,
    Uint8List hmacKey,
    Uint8List page,
    int pageOffset,
    int pgno,
  ) {
    final actual = pageMac(hmacKey, page, pageOffset, pgno);
    final expected = Uint8List.sublistView(
      page,
      pageOffset + macOffset,
      pageOffset + pageSize,
    );
    for (var i = 0; i < 64; i++) {
      if (actual[i] != expected[i]) {
        throw StateError('第 $pgno 页 HMAC 校验失败（key 不对或文件损坏）');
      }
    }
    final out = Uint8List(pageSize);
    decryptPageInto(key, page, pageOffset, pgno, out, 0);
    return out;
  }

  /// 加密一页写入 [target] 的 [targetOffset]。
  static void encryptPageInto({
    required Uint8List key,
    required Uint8List hmacKey,
    required Uint8List plain,
    required int plainOffset,
    required int pgno,
    required Uint8List salt,
    required Uint8List target,
    required int targetOffset,
    required Random random,
  }) {
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i += 4) {
      ByteData.sublistView(iv).setUint32(i, random.nextInt(1 << 32));
    }
    final from = pgno == 1 ? 16 : 0;
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    for (var offset = from; offset < usable; offset += 16) {
      cipher.processBlock(
        plain,
        plainOffset + offset,
        target,
        targetOffset + offset,
      );
    }
    if (pgno == 1) {
      target.setRange(targetOffset, targetOffset + 16, salt);
    }
    target.setRange(targetOffset + ivOffset, targetOffset + ivOffset + 16, iv);
    final mac = pageMac(hmacKey, target, targetOffset, pgno);
    target.setRange(targetOffset + macOffset, targetOffset + pageSize, mac);
  }

  /// 校验 key：解真实库第 1 页，检查 SQLite 头特征（页大小、读写版本）。
  static bool validateKey(String keyHex, String dbPath) {
    if (!isKey(keyHex)) return false;
    RandomAccessFile? file;
    try {
      file = File(dbPath).openSync();
      final page = Uint8List(pageSize);
      if (file.readIntoSync(page) < pageSize) return false;
      final head = Uint8List(pageSize);
      decryptPageInto(hexBytes(keyHex), page, 0, 1, head, 0);
      final size = (head[16] << 8) | head[17];
      return size >= 512 &&
          size <= 65536 &&
          (size & (size - 1)) == 0 &&
          head[18] == head[19] &&
          head[18] >= 1 &&
          head[18] <= 2;
    } catch (_) {
      return false;
    } finally {
      try {
        file?.closeSync();
      } catch (_) {
        // 忽略。
      }
    }
  }

  /// 明文库字节 → 加密库字节（保留原 salt，逐页重新生成 IV 与 MAC）。
  static Uint8List encryptDatabase(
    Uint8List plain,
    String keyHex,
    Uint8List salt, {
    Random? random,
  }) {
    if (plain.length % pageSize != 0) {
      throw StateError('明文库大小不是页对齐');
    }
    if (plain.length < pageSize || plain[20] != reserve) {
      throw StateError('明文库不是 SQLCipher 布局（页保留区不是 80 字节）');
    }
    final key = hexBytes(keyHex);
    final hmacKey = hmacKeyOf(key, salt);
    final rng = random ?? Random.secure();
    final out = Uint8List(plain.length);
    for (var pgno = 1; pgno <= plain.length ~/ pageSize; pgno++) {
      encryptPageInto(
        key: key,
        hmacKey: hmacKey,
        plain: plain,
        plainOffset: (pgno - 1) * pageSize,
        pgno: pgno,
        salt: salt,
        target: out,
        targetOffset: (pgno - 1) * pageSize,
        random: rng,
      );
    }
    return out;
  }

  /// 校验 [encrypted] 解出来是否逐字节等于 [plain]（自校验用，不额外整库拷贝）。
  static bool matchesPlain(
    Uint8List encrypted,
    Uint8List plain,
    String keyHex,
  ) {
    if (encrypted.length != plain.length) return false;
    final key = hexBytes(keyHex);
    final salt = Uint8List.sublistView(encrypted, 0, 16);
    final hmacKey = hmacKeyOf(key, salt);
    final pages = plain.length ~/ pageSize;
    for (var pgno = 1; pgno <= pages; pgno++) {
      final decrypted = decryptPageVerified(
        key,
        hmacKey,
        encrypted,
        (pgno - 1) * pageSize,
        pgno,
      );
      final start = (pgno - 1) * pageSize;
      for (var i = 0; i < pageSize; i++) {
        if (decrypted[i] != plain[start + i]) return false;
      }
    }
    return true;
  }

  /// 加密库字节 → 明文字节（逐页校验 MAC）。
  static Uint8List decryptDatabase(Uint8List encrypted, String keyHex) {
    final key = hexBytes(keyHex);
    final salt = Uint8List.sublistView(encrypted, 0, 16);
    final hmacKey = hmacKeyOf(key, salt);
    final pages = encrypted.length ~/ pageSize;
    final out = Uint8List(pages * pageSize);
    for (var pgno = 1; pgno <= pages; pgno++) {
      final plain = decryptPageVerified(
        key,
        hmacKey,
        encrypted,
        (pgno - 1) * pageSize,
        pgno,
      );
      out.setRange((pgno - 1) * pageSize, pgno * pageSize, plain);
    }
    return out;
  }
}
