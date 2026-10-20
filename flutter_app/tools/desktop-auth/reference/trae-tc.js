#!/usr/bin/env node
"use strict";
/**
 * Trae CN 桌面端登录态 "tc" 加解密实现
 *
 * 逆向来源：resources/app/out/main.js 内打包的模块
 *           out-build/vs/base/common/byteCrypto.js
 *           （客户端里的 R1 = 本文件 encrypt，u2 = 本文件 decrypt）
 *
 * 密文结构：
 *   [6B 魔数 74 69 05 10 00 00] [32B 伪装密钥] [AES-128-CBC(64B SHA-512 校验 ‖ 明文)]
 *
 * KDF：SHA-512( SHA-512(salt) ‖ XOR掩码64B ) → 前16B=AES key，后16B=IV
 * 密钥自包含在密文头部，不绑定机器码。
 *
 * 用法：
 *   node trae-tc.js                     解密并存当前 storage.json 里的登录态（敏感字段打码）
 *   node trae-tc.js --file <storage.json>
 *   node trae-tc.js --b64 <密文>         只解一段密文
 *   node trae-tc.js --raw                完整输出（含 token 明文，谨慎）
 */
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const BLOCK = 16;    // hN  AES 分组
const HASH = 64;     // Gh  SHA-512 摘要长度
const HEAD = 32;     // d2  伪装密钥长度
const MAGIC_LEN = 6; // P1  魔数长度

/* 客户端硬编码的 64 字节掩码素材，运行期按位异或得到实际掩码 */
const Sle = Uint8Array.from([82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251, 124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203, 84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78, 8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37]);
const ble = Uint8Array.from([31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95, 96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239, 160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97, 23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125]);
const _le = Uint8Array.from([191, 192, 216, 250, 122, 246, 220, 97, 31, 254, 98, 27, 8, 72, 71, 176, 135, 99, 96, 18, 127, 101, 203, 104, 211, 102, 191, 125, 37, 72, 150, 156, 51, 229, 121, 35, 17, 153, 141, 177, 110, 131, 150, 128, 172, 255, 254, 6, 18, 140, 55, 62, 236, 249, 135, 64, 135, 12, 117, 4, 89, 149, 168, 209]);
const yle = Uint8Array.from([246, 204, 26, 232, 232, 70, 129, 109, 223, 146, 169, 242, 23, 241, 105, 145, 50, 196, 165, 42, 254, 120, 3, 54, 244, 207, 209, 85, 53, 6, 138, 106, 175, 148, 31, 204, 186, 186, 165, 182, 87, 142, 49, 10, 39, 110, 26, 154, 86, 56, 173, 125, 18, 64, 198, 225, 99, 99, 83, 82, 191, 134, 76, 170]);
const MASK_AES = Sle.map((v, i) => v ^ ble[i]);   // 客户端 nje(): Sle[r]^ble[r]
const MASK_PRIV = _le.map((v, i) => v ^ yle[i]);  // 客户端 nje(): _le[r]^yle[r]

const MAGIC = Buffer.from([116, 99, 5, 16, 0, 0]);        // "tc" 05 10 00 00
const MAGIC_PRIV = Buffer.from([18, 57, 32, 32, 2, 3]);   // AES_PRIVATE 版

const sha512 = (b) => new Uint8Array(crypto.createHash("sha512").update(Buffer.from(b)).digest());

/** 客户端 oje()：按头部字节判定版本 */
function detectVersion(t) {
  if (t[0] === 18 && t[1] === 57 && t[2] === 32 && t[3] === 32 && t[4] === 2 && t[5] === 3) return "AES_PRIVATE";
  if (t[0] !== 116 || t[1] !== 99) return "UNKNOWN";
  if (t[2] === 5 && t[3] === 16 && t[4] === 0 && t[5] === 0) return "AES";
  if (t[2] === 3 && t[3] < 22) return "SS_V3" + t[5];
  if (t[2] === 2 && t[3] < 22) return "SS_V2";
  if (t[2] === 1 && t[3] < 22) return "SS_V1";
  return "UNKNOWN";
}

/** 客户端 hle()：盐 + 掩码 → AES-128 key / IV */
function kdf(salt, ver) {
  const mask = ver === "AES_PRIVATE" ? MASK_PRIV : MASK_AES;
  const s = new Uint8Array(HASH * 2);
  s.set(sha512(salt), 0);
  s.set(mask, HASH);
  const c = sha512(s);
  return { key: Buffer.from(c.slice(0, 16)), iv: Buffer.from(c.slice(16, 32)) };
}

/** 客户端 u2() + cje()：base64 密文 → 明文 */
function decrypt(b64) {
  const raw = Uint8Array.from(Buffer.from(String(b64).trim(), "base64"));
  const ver = detectVersion(raw);
  if (ver !== "AES" && ver !== "AES_PRIVATE") throw new Error("不支持的密文版本: " + ver);
  const salt = raw.slice(MAGIC_LEN, MAGIC_LEN + HEAD);
  const { key, iv } = kdf(salt, ver);
  const d = crypto.createDecipheriv("aes-128-cbc", key, iv);
  const plain = Buffer.concat([d.update(Buffer.from(raw.slice(MAGIC_LEN + HEAD))), d.final()]);
  const digest = Buffer.from(sha512(plain.slice(HASH)));   // 头部 64B = SHA-512(正文)
  if (!plain.slice(0, HASH).equals(digest)) throw new Error("完整性校验失败");
  return plain.slice(HASH).toString("utf8");
}

/** 客户端 R1() + hje()：明文 → base64 密文 */
function encrypt(text, ver = "AES") {
  const salt = crypto.randomBytes(HEAD);
  const { key, iv } = kdf(salt, ver);
  const body = Buffer.from(text, "utf8");
  const payload = Buffer.concat([Buffer.from(sha512(body)), body]);   // Gh 校验 ‖ 明文
  const c = crypto.createCipheriv("aes-128-cbc", key, iv);
  const ct = Buffer.concat([c.update(payload), c.final()]);
  const magic = ver === "AES_PRIVATE" ? MAGIC_PRIV : MAGIC;
  return Buffer.concat([magic, salt, ct]).toString("base64");
}

/* --------------------------- CLI --------------------------- */
function defaultStorage() {
  const home = require("os").homedir();
  return path.join(process.env.APPDATA || path.join(home, "AppData", "Roaming"),
    "Trae CN", "User", "globalStorage", "storage.json");
}

if (require.main === module) {
  const argv = process.argv.slice(2);
  const val = (n) => { const i = argv.indexOf(n); return i > -1 ? argv[i + 1] : null; };
  const raw = argv.includes("--raw");

  const b64 = val("--b64");
  if (b64) { console.log(decrypt(b64)); process.exit(0); }

  const file = val("--file") || defaultStorage();
  if (!fs.existsSync(file)) { console.error("找不到 storage.json: " + file); process.exit(2); }
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  console.log("storage.json :", file);
  for (const k of Object.keys(s)) {
    if (!k.startsWith("iCubeAuthInfo://")) continue;
    const v = s[k];
    if (typeof v !== "string") { console.log("\n[" + k + "] 对象（非 tc 密文）"); continue; }
    try {
      const out = decrypt(v);
      let shown = out;
      if (!raw) {
        try {
          shown = JSON.stringify(JSON.parse(out), (kk, vv) =>
            /token|secret|key|password|cookie/i.test(kk) && typeof vv === "string"
              ? vv.slice(0, 6) + "…(" + vv.length + "B)" : vv, 2);
        } catch { /* 非 JSON 就原样 */ }
      }
      console.log("\n[" + k + "] 解密成功:\n" + shown);
    } catch (e) {
      console.log("\n[" + k + "] 解密失败: " + e.message);
    }
  }
}

module.exports = { decrypt, encrypt, detectVersion };
