#!/usr/bin/env node
"use strict";
/**
 * WorkBuddy 桌面端登录态 $wbEncrypted 信封 加解密实现
 *
 * 逆向来源：resources/app.asar!/main/app-lifetime-job.js（AtRestCrypto 等类）
 * 常量已与 bundle 逐项比对一致；AAD 字节序沿用 originals/switch.mjs 的实现。
 *
 * 信封结构（JSON，base64 后作为 $wbEncrypted 包裹值）：
 *   { suite:1, keyId, nonce(base64,12B), authTag(base64,16B), ciphertext(base64) }
 *
 * key    = SHA-256(atRestSecretKey)              // 32B，AES-256-GCM
 * keyId  = hex(SHA-256(key))[0:16]
 * AAD    = WB-AAD\0 ‖ 0x01 ‖ len("WBEV1") ‖ len("sym-v1") ‖ uint32(1) ‖ len(keyId) ‖ 0x02 ‖ 0x00 ‖ 0x00
 *
 * 用法：
 *   node workbuddy-envelope.js --secret <atRestSecretKey>      解密登录态（敏感字段打码）
 *   node workbuddy-envelope.js --bin <WorkBuddy.exe>           自动以探针取 key 再解密
 *   node workbuddy-envelope.js --file <workbuddy-desktop.info> 指定文件
 *   node workbuddy-envelope.js --raw                           完整输出
 *
 * 注：本机尚未实际执行过探针/解密，仅静态比对过常量。
 */
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const AAD_DOMAIN = Buffer.from("WB-AAD\0", "ascii");
const WRAP_DOMAIN = Buffer.from("WB-WRAP\0", "ascii");
const FRAMING_CODE = { file: 1, field: 2, record: 3, stream: 4 };
const FORMAT_ID = { file: "WBEF1", field: "WBEV1", record: "WBER1", stream: "WBES1" };
const SUITE = 1;
const SCHEME = "sym-v1";
const FRAMING = "field";
const NONCE_LEN = 12;
const TAG_LEN = 16;

const u32 = (n) => { const b = Buffer.allocUnsafe(4); b.writeUInt32BE(n, 0); return b; };
const lenPrefixed = (v) => { const b = Buffer.from(String(v), "utf8"); return Buffer.concat([u32(b.length), b]); };
const optU64 = (v) => {
  if (v === undefined) return Buffer.from([0]);
  const b = Buffer.allocUnsafe(9); b[0] = 1; b.writeBigUInt64BE(v, 1); return b;
};

function buildAad(keyId, suite = SUITE, framing = FRAMING, scheme = SCHEME) {
  return Buffer.concat([
    AAD_DOMAIN,
    Buffer.from([1]),
    lenPrefixed(FORMAT_ID[framing]),
    lenPrefixed(scheme),
    u32(suite),
    lenPrefixed(keyId),
    Buffer.from([FRAMING_CODE[framing]]),
    optU64(undefined),
    Buffer.from([0]),
  ]);
}

const deriveKey = (secret) => crypto.createHash("sha256").update(String(secret), "utf8").digest();
const keyIdOf = (key) => crypto.createHash("sha256").update(key).digest("hex").slice(0, 16);

function canonicalB64(v, field) {
  const d = Buffer.from(v, "base64");
  if (d.toString("base64") !== v) throw new Error(field + " 不是规范 base64");
  return d;
}

function parseEnvelope(b64) {
  const obj = JSON.parse(Buffer.from(b64, "base64").toString("utf8"));
  if (obj.suite !== SUITE) throw new Error("不支持的 suite " + obj.suite);
  return {
    keyId: obj.keyId,
    nonce: canonicalB64(obj.nonce, "nonce"),
    authTag: canonicalB64(obj.authTag, "authTag"),
    ciphertext: obj.ciphertext === "" ? Buffer.alloc(0) : canonicalB64(obj.ciphertext, "ciphertext"),
  };
}

/** 解出信封明文 */
function open(envelopeB64, key) {
  const e = parseEnvelope(envelopeB64);
  if (e.keyId !== keyIdOf(key)) throw new Error("keyId 不匹配: " + e.keyId);
  const d = crypto.createDecipheriv("aes-256-gcm", key, e.nonce, { authTagLength: TAG_LEN });
  d.setAAD(buildAad(e.keyId));
  d.setAuthTag(e.authTag);
  return Buffer.concat([d.update(e.ciphertext), d.final()]).toString("utf8");
}

/** 生成信封密文（base64） */
function seal(plain, key) {
  const keyId = keyIdOf(key);
  const nonce = crypto.randomBytes(NONCE_LEN);
  const c = crypto.createCipheriv("aes-256-gcm", key, nonce, { authTagLength: TAG_LEN });
  c.setAAD(buildAad(keyId));
  const ciphertext = Buffer.concat([c.update(Buffer.from(String(plain), "utf8")), c.final()]);
  const env = {
    suite: SUITE, keyId,
    nonce: nonce.toString("base64"),
    authTag: c.getAuthTag().toString("base64"),
    ciphertext: ciphertext.toString("base64"),
  };
  return Buffer.from(JSON.stringify(env), "utf8").toString("base64");
}

const isWrapped = (v) => Boolean(v && typeof v === "object" && typeof v.envelope === "string");
/** 字段可能被信封包裹，也可能本身就是明文 */
function unwrapField(v, key) {
  if (isWrapped(v)) return open(v.envelope, key);
  return v;
}
function wrapField(plain, key) {
  return { $wbEncrypted: 1, envelope: seal(plain, key) };
}

/* --------------------- 从客户端探针取 atRestSecretKey --------------------- */
const PROBE_SRC =
  'const n=process._linkedBinding("electron_browser_workbuddy_storage");' +
  "const o=JSON.parse(String(n.loggerGet()));" +
  'process.stdout.write("WB_PROBE_JSON:"+JSON.stringify({version:o.version,atRestSecretKey:o.atRestSecretKey}))';

function probeSecretKey(bin) {
  const r = spawnSync(bin, ["-e", PROBE_SRC], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
    encoding: "utf8", timeout: 60000, maxBuffer: 8 * 1024 * 1024,
  });
  if (r.error) throw new Error("启动主程序取密钥失败: " + r.error.message);
  const m = /WB_PROBE_JSON:(\{[^\n]*\})/.exec(r.stdout || "");
  if (!m) throw new Error("未取到密钥载荷 (stderr: " + String(r.stderr || "").slice(-300).trim() + ")");
  return JSON.parse(m[1]).atRestSecretKey;
}

function defaultBin() {
  const c = path.join(process.env.LOCALAPPDATA || "", "Programs", "WorkBuddy", "WorkBuddy.exe");
  return fs.existsSync(c) ? c : null;
}
function defaultInfo() {
  const c = path.join(process.env.LOCALAPPDATA || "", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info");
  return fs.existsSync(c) ? c : null;
}

/* --------------------------- CLI --------------------------- */
if (require.main === module) {
  const argv = process.argv.slice(2);
  const val = (n) => { const i = argv.indexOf(n); return i > -1 ? argv[i + 1] : null; };
  const raw = argv.includes("--raw");

  const info = val("--file") || defaultInfo();
  if (!info) { console.error("找不到 workbuddy-desktop.info（用 --file 指定）"); process.exit(2); }

  let secret = val("--secret");
  if (!secret) {
    const bin = val("--bin") || defaultBin();
    if (!bin) { console.error("需要 --secret <atRestSecretKey> 或 --bin <WorkBuddy.exe>"); process.exit(2); }
    console.log("以探针取 key:", bin);
    secret = probeSecretKey(bin);
  }
  const key = deriveKey(secret);

  const j = JSON.parse(fs.readFileSync(info, "utf8"));
  console.log("登录态文件 :", info);
  console.log("keyId      :", keyIdOf(key));

  const show = (label, v) => {
    try {
      const out = unwrapField(v, key);
      console.log("  " + label + " : " + (raw ? out : String(out).slice(0, 6) + "…(" + String(out).length + "B)"));
    } catch (e) {
      console.log("  " + label + " : 解密失败 - " + e.message);
    }
  };
  console.log("\n[account]");
  show("nickname", j.account && j.account.nickname);
  show("phoneNumber", j.account && j.account.phoneNumber);
  console.log("\n[auth]");
  show("accessToken", j.auth && j.auth.accessToken);
  show("refreshToken", j.auth && j.auth.refreshToken);
  console.log("\n明文项: uid=" + (j.account && j.account.uid) + "  domain=" + (j.auth && j.auth.domain) +
    "  expiresAt=" + (j.auth && j.auth.expiresAt));
}

module.exports = { open, seal, unwrapField, wrapField, buildAad, deriveKey, keyIdOf, probeSecretKey, FRAMING_CODE, FORMAT_ID, AAD_DOMAIN, WRAP_DOMAIN };
