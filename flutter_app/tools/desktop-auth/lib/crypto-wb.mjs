/**
 * WorkBuddy 桌面端登录态「$wbEncrypted」信封：加密 / 解密 / 取本机密钥
 *
 * 逆向自 resources/app.asar!/main/app-lifetime-job.js（AtRestCrypto 等类）。
 *
 * 信封：base64( JSON{ suite:1, keyId, nonce(12B), authTag(16B), ciphertext } )
 *   key    = SHA-256(atRestSecretKey)            // 32B，AES-256-GCM
 *   keyId  = hex(SHA-256(key))[0:16]
 *   AAD    = "WB-AAD\0" ‖ 0x01 ‖ len("WBEV1") ‖ len("sym-v1") ‖ uint32(1)
 *            ‖ len(keyId) ‖ 0x02 ‖ 0x00 ‖ 0x00
 *
 * 密钥只能由客户端自身的 `electron_browser_workbuddy_storage` 绑定给出：
 * 以 ELECTRON_RUN_AS_NODE=1 启动客户端主程序执行探针即可（无窗口、不联网）。
 */
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";

const AAD_DOMAIN = Buffer.from("WB-AAD\0", "ascii");
const FRAMING_CODE = { file: 1, field: 2, record: 3, stream: 4 };
const STANDARD_FORMAT_ID = { file: "WBEF1", field: "WBEV1", record: "WBER1", stream: "WBES1" };
const FRAMING = "field";
const SCHEME = "sym-v1";

function encodeUint32(value) {
  const buffer = Buffer.allocUnsafe(4);
  buffer.writeUInt32BE(value, 0);
  return buffer;
}

function encodeLengthPrefixed(value) {
  const body = Buffer.from(value, "utf8");
  return Buffer.concat([encodeUint32(body.length), body]);
}

function encodeOptionalUint64(value) {
  if (value === undefined) return Buffer.from([0]);
  const buffer = Buffer.allocUnsafe(9);
  buffer[0] = 1;
  buffer.writeBigUInt64BE(BigInt(value), 1);
  return buffer;
}

function buildAad(keyId, suite, framing = FRAMING) {
  return Buffer.concat([
    AAD_DOMAIN,
    Buffer.from([1]),
    encodeLengthPrefixed(STANDARD_FORMAT_ID[framing]),
    encodeLengthPrefixed(SCHEME),
    encodeUint32(suite),
    encodeLengthPrefixed(keyId),
    Buffer.from([FRAMING_CODE[framing]]),
    encodeOptionalUint64(undefined),
    Buffer.from([0]),
  ]);
}

function decodeCanonicalBase64(value) {
  const data = Buffer.from(value, "base64");
  if (data.toString("base64") !== value) throw new Error("envelope 中的 base64 不是规范编码");
  return data;
}

export function deriveKeyId(key) {
  return crypto.createHash("sha256").update(key).digest("hex").slice(0, 16);
}

export function parseEnvelope(encoded) {
  const object = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  if (object.suite !== 1) throw new Error(`不支持的 suite：${object.suite}`);
  return {
    suite: 1,
    keyId: object.keyId,
    nonce: decodeCanonicalBase64(object.nonce),
    authTag: decodeCanonicalBase64(object.authTag),
    ciphertext: object.ciphertext === "" ? Buffer.alloc(0) : decodeCanonicalBase64(object.ciphertext),
  };
}

export function openEnvelope(envelope, key) {
  if (envelope.keyId !== deriveKeyId(key)) throw new Error(`keyId 不匹配：${envelope.keyId}`);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, envelope.nonce, { authTagLength: 16 });
  decipher.setAAD(buildAad(envelope.keyId, envelope.suite));
  decipher.setAuthTag(envelope.authTag);
  return Buffer.concat([decipher.update(envelope.ciphertext), decipher.final()]);
}

export function sealEnvelope(plain, key) {
  const keyId = deriveKeyId(key);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
  cipher.setAAD(buildAad(keyId, 1));
  const ciphertext = Buffer.concat([cipher.update(plain), cipher.final()]);
  const envelope = {
    suite: 1,
    keyId,
    nonce: nonce.toString("base64"),
    authTag: cipher.getAuthTag().toString("base64"),
    ciphertext: ciphertext.toString("base64"),
  };
  return Buffer.from(JSON.stringify(envelope), "utf8").toString("base64");
}

export function isWrapped(value) {
  return Boolean(value && typeof value === "object" && typeof value.envelope === "string");
}

/** 解出字段明文；客户端也可能直接存明文，此时原样返回。 */
export function unwrapField(value, key) {
  if (isWrapped(value)) return openEnvelope(parseEnvelope(value.envelope), key).toString("utf8");
  return value;
}

/** 加密成客户端同款信封（键顺序与客户端一致）。 */
export function wrapField(plain, key) {
  return { $wbEncrypted: 1, envelope: sealEnvelope(Buffer.from(String(plain), "utf8"), key) };
}

const PROBE_SRC =
  'const n=process._linkedBinding("electron_browser_workbuddy_storage");' +
  "const o=JSON.parse(String(n.loggerGet()));" +
  'process.stdout.write("WB_PROBE_JSON:"+JSON.stringify({version:o.version,atRestSecretKey:o.atRestSecretKey}))';

/**
 * 通过客户端探针取本机 atRestSecretKey，返回 32B AES key。
 * 客户端主程序启动一次即退出，不打开窗口、不联网、不改动任何状态。
 */
export function readProtectorKey(bin) {
  if (!bin) throw new Error("未找到 WorkBuddy 主程序，无法读取解密密钥");
  const result = spawnSync(bin, ["-e", PROBE_SRC], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
    encoding: "utf8",
    timeout: 60000,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw new Error(`启动客户端取密钥失败：${result.error.message}`);
  const match = /WB_PROBE_JSON:(\{[^\n]*\})/.exec(result.stdout || "");
  if (!match) {
    throw new Error(`未取到密钥载荷（stderr：${String(result.stderr || "").slice(-300).trim()}）`);
  }
  const payload = JSON.parse(match[1]);
  if (payload.version !== 1 || typeof payload.atRestSecretKey !== "string") {
    throw new Error("密钥载荷格式异常");
  }
  return crypto.createHash("sha256").update(payload.atRestSecretKey, "utf8").digest();
}

/** 手机号按客户端习惯掩码落盘。 */
export function maskPhone(value) {
  if (typeof value !== "string" || value.includes("*")) return value;
  let digits = value.replace(/\D/g, "");
  if (digits.length === 13 && digits.startsWith("86")) digits = digits.slice(2);
  if (digits.length === 11) return `${digits.slice(0, 3)}****${digits.slice(7)}`;
  if (digits.length >= 7) return `${digits.slice(0, 3)}****${digits.slice(-4)}`;
  return value;
}

/** 账号对象中的敏感字段加密（昵称、手机号）。 */
export function wrapAccountFields(object, source, key) {
  if (object.nickname !== undefined) object.nickname = wrapField(source.nickname ?? "", key);
  if (object.phoneNumber !== undefined) object.phoneNumber = wrapField(maskPhone(source.phoneNumber ?? ""), key);
  return object;
}

export function wrapAuthFields(auth, key) {
  if (auth.accessToken) auth.accessToken = wrapField(auth.accessToken, key);
  if (auth.refreshToken) auth.refreshToken = wrapField(auth.refreshToken, key);
  return auth;
}
