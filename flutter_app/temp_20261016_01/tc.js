// Trae / iCube "tc" 登录态加密 —— 逆向自 resources/app/out/main.js
// 源模块: out-build/vs/base/common/byteCrypto.js (R1=encrypt, u2=decrypt)
// 自包含密钥：32 字节密钥随密文头存放，仅 XOR mask 混淆，无本机机器码参与
const crypto = require("crypto");
const fs = require("fs");

const BLOCK = 16, HASH = 64, HEAD = 32, MAGIC = 6;   // hN, Gh, d2, P1
const MAGIC_ARR = [116, 99, 5, 16, 0, 0];             // "tc" 05 10 00 00 00
const MASK_AES = Uint8Array.from([82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37])
  .map((v, i) => v ^ [31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125][i]);
const MASK_PRIV = Uint8Array.from([191,192,216,250,122,246,220,97,31,254,98,27,8,72,71,176,135,99,96,18,127,101,203,104,211,102,191,125,37,72,150,156,51,229,121,35,17,153,141,177,110,131,150,128,172,255,254,6,18,140,55,62,236,249,135,64,135,12,117,4,89,149,168,209])
  .map((v, i) => v ^ [246,204,26,232,232,70,129,109,223,146,169,242,23,241,105,145,50,196,165,42,254,120,3,54,244,207,209,85,53,6,138,106,175,148,31,204,186,186,165,182,87,142,49,10,39,110,26,154,86,56,173,125,18,64,198,225,99,99,83,82,191,134,76,170][i]);

const sha512 = (b) => new Uint8Array(crypto.createHash("sha512").update(b).digest());

function versionOf(t) {                                   // oje()
  if (t[0]===18 && t[1]===57 && t[2]===32 && t[3]===32 && t[4]===2 && t[5]===3) return "AES_PRIVATE";
  if (t[0]!==116 || t[1]!==99) return "UNKNOWN";
  if (t[2]===5 && t[3]===16 && t[4]===0 && t[5]===0) return "AES";
  if (t[2]===3 && t[3]<22) return `SS_V3${t[5]}`;
  if (t[2]===2 && t[3]<22) return "SS_V2";
  if (t[2]===1 && t[3]<22) return "SS_V1";
  return "UNKNOWN";
}

function kdf(salt, ver) {                                  // hle(): SHA512(salt)||mask → SHA512 → key|iv
  const mask = ver === "AES_PRIVATE" ? MASK_PRIV : MASK_AES;
  const s = new Uint8Array(HASH * 2);
  s.set(sha512(salt), 0);
  s.set(mask, HASH);
  const c = sha512(s);
  return { key: c.slice(0, 16), iv: c.slice(16, 32) };     // AES128, 16 字节 IV
}

function decrypt(b64) {                                    // u2() + cje()
  const raw = Uint8Array.from(Buffer.from(b64, "base64"));
  const ver = versionOf(raw);
  if (ver !== "AES" && ver !== "AES_PRIVATE") throw new Error("不支持的版本: " + ver);
  const salt = raw.slice(MAGIC, MAGIC + HEAD);             // 密钥藏在头部
  const { key, iv } = kdf(salt, ver);
  const d = crypto.createDecipheriv("aes-128-cbc", key, iv);
  const plain = Buffer.concat([d.update(raw.slice(MAGIC + HEAD)), d.final()]);
  const digest = sha512(plain.slice(HASH));                // 前 64 字节是 SHA-512 完整性校验
  if (!plain.slice(0, HASH).equals(Buffer.from(digest))) throw new Error("完整性校验失败");
  return plain.slice(HASH).toString("utf8");
}

module.exports = { decrypt };

if (require.main === module) {
  const p = "C:/Users/27490/AppData/Roaming/Trae CN/User/globalStorage/storage.json";
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  for (const k of Object.keys(s)) {
    if (!k.startsWith("iCubeAuthInfo://")) continue;
    const v = s[k];
    if (typeof v !== "string") { console.log(`\n[${k}] (对象，非 tc 密文)`); continue; }
    try {
      const out = decrypt(v);
      let shown = out;
      try {
        const j = JSON.parse(out);
        shown = JSON.stringify(j, (kk, vv) =>
          /token|secret|key|password|cookie/i.test(kk) && typeof vv === "string"
            ? `${vv.slice(0, 6)}…(${vv.length}B)` : vv, 2);
      } catch {}
      console.log(`\n[${k}]  版本 tc/AES  解密成功:\n${shown}`);
    } catch (e) {
      console.log(`\n[${k}]  解密失败: ${e.message}`);
    }
  }
}
