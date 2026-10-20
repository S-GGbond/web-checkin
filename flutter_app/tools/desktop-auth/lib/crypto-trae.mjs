/**
 * Trae CN 「tc」登录态容器：加密 / 解密
 *
 * 逆向自客户端 resources/app/out/main.js
 * （out-build/vs/base/common/byteCrypto.js 的 R1=encrypt、u2=decrypt）。
 *
 * 结构：base64( MAGIC(6) + RANDOM(32) + AES-128-CBC( SHA512(payload)(64) + payload ) )
 *   6B 魔数  74 69 05 10 00 00   → "tc" v5 tag16 ver0
 *   密钥     SHA512( SHA512(RANDOM) ‖ XOR 掩码(64B) ) 前 16B = key，后 16B = iv
 *   掩码     硬编码在 bundle 内，与机器码无关
 *   完整性   明文前置 SHA512(明文)，解密后逐字节比对
 */
import crypto from "node:crypto";

const BLOCK = 16;
const HASH = 64;
const HEAD = 32;
const MAGIC = 6;
const HEADER = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00];

const MASK_AES = Uint8Array.from([
  82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251, 124, 227, 57, 130, 155, 47,
  255, 135, 52, 142, 67, 68, 196, 222, 233, 203, 84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11,
  66, 250, 195, 78, 8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
]).map(
  (value, index) =>
    value ^
    [
      31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95, 96, 81, 127, 169, 25, 181,
      74, 13, 45, 229, 122, 159, 147, 201, 156, 239, 160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187,
      60, 131, 83, 153, 97, 23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
    ][index],
);

const MASK_PRIVATE = Uint8Array.from([
  191, 192, 216, 250, 122, 246, 220, 97, 31, 254, 98, 27, 8, 72, 71, 176, 135, 99, 96, 18, 127, 101, 203,
  104, 211, 102, 191, 125, 37, 72, 150, 156, 51, 229, 121, 35, 17, 153, 141, 177, 110, 131, 150, 128, 172,
  255, 254, 6, 18, 140, 55, 62, 236, 249, 135, 64, 135, 12, 117, 4, 89, 149, 168, 209,
]).map(
  (value, index) =>
    value ^
    [
      246, 204, 26, 232, 232, 70, 129, 109, 223, 146, 169, 242, 23, 241, 105, 145, 50, 196, 165, 42, 254,
      120, 3, 54, 244, 207, 209, 85, 53, 6, 138, 106, 175, 148, 31, 204, 186, 186, 165, 182, 87, 142, 49,
      10, 39, 110, 26, 154, 86, 56, 173, 125, 18, 64, 198, 225, 99, 99, 83, 82, 191, 134, 76, 170,
    ][index],
);

const sha512 = (buffer) => new Uint8Array(crypto.createHash("sha512").update(buffer).digest());

/** 版本判定与客户端 `oje()` 一致。 */
export function versionOf(bytes) {
  if (bytes[0] === 18 && bytes[1] === 57 && bytes[2] === 32 && bytes[3] === 32 && bytes[4] === 2 && bytes[5] === 3) {
    return "AES_PRIVATE";
  }
  if (bytes[0] !== 116 || bytes[1] !== 99) return "UNKNOWN";
  if (bytes[2] === 5 && bytes[3] === 16 && bytes[4] === 0 && bytes[5] === 0) return "AES";
  if (bytes[2] === 3 && bytes[3] < 22) return `SS_V3${bytes[5]}`;
  if (bytes[2] === 2 && bytes[3] < 22) return "SS_V2";
  if (bytes[2] === 1 && bytes[3] < 22) return "SS_V1";
  return "UNKNOWN";
}

function deriveKey(randomBlock, version) {
  const mask = version === "AES_PRIVATE" ? MASK_PRIVATE : MASK_AES;
  const seed = new Uint8Array(HASH * 2);
  seed.set(sha512(randomBlock), 0);
  seed.set(mask, HASH);
  const digest = sha512(seed);
  return { key: Buffer.from(digest.slice(0, BLOCK)), iv: Buffer.from(digest.slice(BLOCK, BLOCK * 2)) };
}

/** 明文对象 → base64 tc 容器（与客户端写入格式一致）。 */
export function encrypt(value) {
  const payload = Buffer.from(typeof value === "string" ? value : JSON.stringify(value), "utf8");
  const mac = Buffer.from(sha512(payload));
  const randomBlock = crypto.randomBytes(HEAD);
  const { key, iv } = deriveKey(randomBlock, "AES");
  const cipher = crypto.createCipheriv("aes-128-cbc", key, iv);
  const encrypted = Buffer.concat([cipher.update(Buffer.concat([mac, payload])), cipher.final()]);
  return Buffer.concat([Buffer.from(HEADER), randomBlock, encrypted]).toString("base64");
}

/** base64 tc 容器 → JSON 对象。 */
export function decrypt(encoded) {
  const raw = Buffer.from(String(encoded).trim(), "base64");
  const version = versionOf(raw);
  if (version !== "AES" && version !== "AES_PRIVATE") {
    throw new Error(`不支持的 Trae 登录态版本：${version}`);
  }
  const randomBlock = raw.subarray(MAGIC, MAGIC + HEAD);
  const { key, iv } = deriveKey(randomBlock, version);
  const decipher = crypto.createDecipheriv("aes-128-cbc", key, iv);
  const plain = Buffer.concat([decipher.update(raw.subarray(MAGIC + HEAD)), decipher.final()]);
  const storedMac = plain.subarray(0, HASH);
  const payload = plain.subarray(HASH);
  const actualMac = Buffer.from(sha512(payload));
  if (!storedMac.equals(actualMac)) throw new Error("Trae 登录态完整性校验失败");
  const text = payload.toString("utf8");
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export { MASK_AES, MASK_PRIVATE };
