#!/usr/bin/env node
/**
 * switch.mjs — WorkBuddy 桌面端「换号」脚本（免重新登录）
 *
 * 作用：把 WorkBuddy 客户端当前的桌面端登录态，直接换成本机数据库中已保存的另一个账号；
 *       客户端完全退出后重新启动即以目标账号登录，不需要再走浏览器授权。
 *
 * 原理：客户端登录态保存在 workbuddy-desktop.info（明文 JSON），其中
 *       account.nickname / account.phoneNumber / auth.accessToken / auth.refreshToken
 *       由 $wbEncrypted 信封保护（AES-256-GCM + 特定 AAD）。本脚本从本机
 *       checkin-hub.sqlite3 / workbuddy-checkin.sqlite3 读取目标账号的明文令牌，
 *       用相同方式重新加密后原子写回该文件，因此客户端无需重新登录。
 *
 * 用法：
 *   node workbuddy-tools/switch.mjs --list                   # 列出候选账号与当前账号
 *   node workbuddy-tools/switch.mjs --to 2                   # 切换到第 2 个账号（按序号）
 *   node workbuddy-tools/switch.mjs --to f9d35b32-512a-...   # 按 uid 切换（支持唯一前缀）
 *   node workbuddy-tools/switch.mjs --to 2 --yes             # 跳过交互确认
 *   node workbuddy-tools/switch.mjs --restore                # 还原最近一次备份
 *   node workbuddy-tools/switch.mjs --restore 20261016-15    # 还原指定备份（按文件名片段）
 *
 * 可选参数：
 *   --file <path>  指定 workbuddy-desktop.info 路径
 *   --hub <path>   指定 checkin-hub.sqlite3 路径
 *   --db <path>    指定 workbuddy-checkin.sqlite3 路径
 *   --bin <path>   指定 WorkBuddy 客户端主程序路径
 *   --force        客户端运行中时也强制写入（默认拒绝）
 *
 * 注意：写入前请完全退出 WorkBuddy 客户端（脚本会自动检测并拒绝，--force 可强制）。
 *       读密钥需临时以 ELECTRON_RUN_AS_NODE=1 启动客户端主程序（无窗口，不联网，
 *       不改动客户端状态），仅用于取本机 atRestSecretKey。
 */
import { execFileSync, spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline/promises";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

/* ------------------------------------------------------------------ *
 * 一、$wbEncrypted 信封（来自客户端 bundle 的逆向实现，field 策略）
 * ------------------------------------------------------------------ */
const AAD_DOMAIN = Buffer.from("WB-AAD\0", "ascii");
const FRAMING_CODE = { file: 1, field: 2, record: 3, stream: 4 };
const STANDARD_FORMAT_ID = { file: "WBEF1", field: "WBEV1", record: "WBER1", stream: "WBES1" };
const FRAMING = "field";
const SCHEME = "sym-v1";

function encodeUint32(n) {
  const b = Buffer.allocUnsafe(4);
  b.writeUInt32BE(n, 0);
  return b;
}
function encodeLengthPrefixed(v) {
  const b = Buffer.from(v, "utf8");
  return Buffer.concat([encodeUint32(b.length), b]);
}
function encodeOptionalUint64(v) {
  if (v === undefined) return Buffer.from([0]);
  const b = Buffer.allocUnsafe(9);
  b[0] = 1;
  b.writeBigUInt64BE(v, 1);
  return b;
}
function buildAad(keyId, suite, framing, scheme) {
  return Buffer.concat([
    AAD_DOMAIN,
    Buffer.from([1]),
    encodeLengthPrefixed(STANDARD_FORMAT_ID[framing]),
    encodeLengthPrefixed(scheme),
    encodeUint32(suite),
    encodeLengthPrefixed(keyId),
    Buffer.from([FRAMING_CODE[framing]]),
    encodeOptionalUint64(undefined),
    Buffer.from([0]),
  ]);
}
function decodeCanonicalB64(v) {
  const d = Buffer.from(v, "base64");
  if (d.toString("base64") !== v) throw new Error("non-canonical base64");
  return d;
}
function deriveKeyId(key) {
  return crypto.createHash("sha256").update(key).digest("hex").slice(0, 16);
}
function parseEnvelope(b64) {
  const obj = JSON.parse(Buffer.from(b64, "base64").toString("utf8"));
  if (obj.suite !== 1) throw new Error("unsupported suite " + obj.suite);
  return {
    suite: 1,
    keyId: obj.keyId,
    nonce: decodeCanonicalB64(obj.nonce),
    authTag: decodeCanonicalB64(obj.authTag),
    ciphertext: obj.ciphertext === "" ? Buffer.alloc(0) : decodeCanonicalB64(obj.ciphertext),
  };
}
function openEnvelope(envelope, key) {
  if (envelope.keyId !== deriveKeyId(key)) throw new Error("keyId mismatch: " + envelope.keyId);
  const d = crypto.createDecipheriv("aes-256-gcm", key, envelope.nonce, { authTagLength: 16 });
  d.setAAD(buildAad(envelope.keyId, envelope.suite, FRAMING, SCHEME));
  d.setAuthTag(envelope.authTag);
  return Buffer.concat([d.update(envelope.ciphertext), d.final()]);
}
function sealEnvelope(plain, key) {
  const keyId = deriveKeyId(key);
  const nonce = crypto.randomBytes(12);
  const c = crypto.createCipheriv("aes-256-gcm", key, nonce, { authTagLength: 16 });
  c.setAAD(buildAad(keyId, 1, FRAMING, SCHEME));
  const ciphertext = Buffer.concat([c.update(plain), c.final()]);
  const env = {
    suite: 1,
    keyId,
    nonce: nonce.toString("base64"),
    authTag: c.getAuthTag().toString("base64"),
    ciphertext: ciphertext.toString("base64"),
  };
  return Buffer.from(JSON.stringify(env), "utf8").toString("base64");
}
function isWrapped(v) {
  return Boolean(v && typeof v === "object" && typeof v.envelope === "string");
}
/** 解出字段明文；非信封（客户端也可能直接存明文）时原样返回 */
function unwrapField(v, key) {
  if (isWrapped(v)) return openEnvelope(parseEnvelope(v.envelope), key).toString("utf8");
  return v;
}
/** 加密成客户端同款信封（键顺序与客户端一致） */
function wrapField(plain, key) {
  return { $wbEncrypted: 1, envelope: sealEnvelope(Buffer.from(String(plain), "utf8"), key) };
}

/* ------------------------------------------------------------------ *
 * 二、定位客户端主程序 / 读取 protector key
 * ------------------------------------------------------------------ */
function locateWbBin(explicit) {
  const cands = [];
  if (explicit) cands.push(explicit);
  if (process.env.WORKBUDDY_BIN) cands.push(process.env.WORKBUDDY_BIN);
  const home = os.homedir();
  if (process.platform === "darwin") {
    cands.push(
      "/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy",
      "/Applications/WorkBuddy.app/Contents/MacOS/Electron",
      path.join(home, "Applications", "WorkBuddy.app", "Contents", "MacOS", "WorkBuddy"),
    );
  } else if (process.platform === "win32") {
    cands.push(
      path.join(process.env.LOCALAPPDATA || "", "Programs", "WorkBuddy", "WorkBuddy.exe"),
      path.join(process.env.PROGRAMFILES || "", "WorkBuddy", "WorkBuddy.exe"),
    );
  } else {
    cands.push(
      "/opt/workbuddy/workbuddy",
      "/opt/WorkBuddy/workbuddy",
      "/usr/lib/workbuddy/workbuddy",
      "/usr/share/workbuddy/workbuddy",
      "/usr/local/workbuddy/workbuddy",
      path.join(home, ".local", "opt", "workbuddy", "workbuddy"),
    );
  }
  for (const c of cands) if (c && fs.existsSync(c)) return c;
  try {
    const p = execFileSync("which", ["workbuddy"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    if (p && fs.existsSync(p)) return p;
  } catch {}
  // 兜底：有限深度搜索（Linux 上用 apm 转制的安装路径层级较深）
  const roots = process.platform === "linux"
    ? [["/var/lib/apm", 12], ["/opt", 5], ["/usr/lib", 5], ["/usr/share", 5], [path.join(home, ".local"), 6]]
    : [];
  for (const [root, maxdepth] of roots) {
    if (!fs.existsSync(root)) continue;
    // find 遇到无权限目录会返回非 0，故用 spawnSync 取 stdout，忽略退出码
    const r = spawnSync(
      "find",
      [root, "-maxdepth", String(maxdepth), "-type", "f", "-name", "workbuddy", "-perm", "-u+x"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 20000, maxBuffer: 4 * 1024 * 1024 },
    );
    const hit = String(r.stdout || "").split("\n").map((s) => s.trim()).find((p) => p && !p.endsWith(".sh"));
    if (hit) return hit;
  }
  return null;
}

const PROBE_SRC =
  'const n=process._linkedBinding("electron_browser_workbuddy_storage");' +
  "const o=JSON.parse(String(n.loggerGet()));" +
  'process.stdout.write("WB_PROBE_JSON:"+JSON.stringify({version:o.version,atRestSecretKey:o.atRestSecretKey}))';

let cachedProtectorKey = null;
function protectorKey(bin) {
  if (cachedProtectorKey) return cachedProtectorKey;
  if (!bin) throw new Error("未找到 WorkBuddy 主程序，无法读取解密密钥（可用 --bin 指定）");
  const r = spawnSync(bin, ["-e", PROBE_SRC], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
    encoding: "utf8",
    timeout: 60000,
    maxBuffer: 8 * 1024 * 1024,
  });
  if (r.error) throw new Error("启动 WorkBuddy 主程序取密钥失败：" + r.error.message);
  const m = /WB_PROBE_JSON:(\{[^\n]*\})/.exec(r.stdout || "");
  if (!m) throw new Error("未取到密钥载荷（stderr: " + String(r.stderr || "").slice(-300).trim() + "）");
  const obj = JSON.parse(m[1]);
  if (obj.version !== 1 || typeof obj.atRestSecretKey !== "string") throw new Error("密钥载荷异常");
  cachedProtectorKey = crypto.createHash("sha256").update(obj.atRestSecretKey, "utf8").digest();
  return cachedProtectorKey;
}

/* ------------------------------------------------------------------ *
 * 三、定位登录态文件 / 客户端运行检测
 * ------------------------------------------------------------------ */
function locateAuthFile(explicit) {
  const home = os.homedir();
  const cands = [
    explicit,
    process.env.WORKBUDDY_AUTH_FILE,
    path.join(home, "Library", "Application Support", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
    path.join(home, ".local", "share", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
    path.join(home, ".config", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
    path.join(process.env.APPDATA || "", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
    path.join(process.env.LOCALAPPDATA || "", "CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info"),
  ].filter(Boolean);
  for (const c of cands) if (fs.existsSync(c)) return c;
  throw new Error("未找到客户端登录态文件 workbuddy-desktop.info，可用 --file 指定");
}

/** 返回客户端主程序进程 PID 列表（只认主程序本身，避免误判本脚本自身） */
function runningPids(bin) {
  const pids = new Set();
  if (process.platform === "win32") {
    try {
      const out = execFileSync("tasklist", ["/FI", "IMAGENAME eq WorkBuddy.exe", "/NH"], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"],
      });
      for (const line of out.split("\n")) {
        const m = /^WorkBuddy\.exe\s+(\d+)/i.exec(line.trim());
        if (m) pids.add(Number(m[1]));
      }
    } catch {}
    return [...pids];
  }
  for (const pat of ["opt/workbuddy/workbuddy", "WorkBuddy.app/Contents/MacOS", "WorkBuddy.exe"]) {
    try {
      const out = execFileSync("pgrep", ["-f", pat], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      for (const s of out.split("\n")) if (s.trim()) pids.add(Number(s.trim()));
    } catch {}
  }
  pids.delete(process.pid);
  return [...pids].filter((pid) => {
    try {
      const exe = fs.readlinkSync(`/proc/${pid}/exe`);
      const base = path.basename(exe);
      // 只保留 WorkBuddy 主程序（node 进程会读到 node 的可执行文件，直接排除）
      return bin ? base === path.basename(bin) || /workbuddy/i.test(base) : /workbuddy/i.test(base);
    } catch {
      return true;
    }
  });
}

/* ------------------------------------------------------------------ *
 * 四、候选账号：checkin-hub.sqlite3 + workbuddy-checkin.sqlite3
 * ------------------------------------------------------------------ */
function maskPhone(v) {
  if (typeof v !== "string" || v.includes("*")) return v;
  const digits = v.replace(/\D/g, "");
  if (digits.length === 11) return digits.slice(0, 3) + "****" + digits.slice(7);
  if (digits.length >= 7) return digits.slice(0, 3) + "****" + digits.slice(-4);
  return v;
}

function safeParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function loadCandidates({ hubDb, sessionsDb }) {
  const byUid = new Map();

  // 1) checkin-hub.sqlite3：credential = 明文 {account, auth, snapshot}
  if (fs.existsSync(hubDb)) {
    try {
      const db = new DatabaseSync(hubDb, { readOnly: true });
      const rows = db.prepare("SELECT id, credential, enabled FROM accounts WHERE provider = 'workbuddy'").all();
      for (const r of rows) {
        const cred = safeParse(r.credential);
        const account = cred?.account;
        const auth = cred?.auth;
        if (!account?.uid || !auth?.accessToken) continue;
        byUid.set(account.uid, {
          uid: account.uid,
          account,
          auth,
          slim: cred.snapshot?.accounts?.[0] ?? null,
          source: `checkin-hub#${r.id}`,
          enabled: r.enabled,
        });
      }
      db.close();
    } catch (e) {
      console.warn(`[警告] 读取 checkin-hub 失败：${e.message}`);
    }
  }

  // 2) workbuddy-checkin.sqlite3：sessions 表（明文 account_json / tokens）
  if (fs.existsSync(sessionsDb)) {
    try {
      const db = new DatabaseSync(sessionsDb, { readOnly: true });
      const rows = db.prepare("SELECT * FROM sessions").all();
      for (const r of rows) {
        const account = safeParse(r.account_json);
        if (!account?.uid || !r.access_token) continue;
        const auth = {
          accessToken: r.access_token,
          refreshToken: r.refresh_token || undefined,
          tokenType: r.token_type || undefined,
          domain: r.domain || undefined,
          expiresAt: r.expires_at || undefined,
          refreshExpiresAt: r.refresh_expires_at || undefined,
        };
        const existing = byUid.get(account.uid);
        if (existing) {
          // hub 为主，缺令牌时用 sessions 补
          if (!existing.auth.accessToken) existing.auth = auth;
        } else {
          byUid.set(account.uid, {
            uid: account.uid,
            account,
            auth,
            slim: safeParse(r.accounts_json) ?? null,
            source: "workbuddy-checkin.sessions",
            enabled: r.enabled,
          });
        }
      }
      db.close();
    } catch (e) {
      console.warn(`[警告] 读取 workbuddy-checkin 失败：${e.message}`);
    }
  }

  return [...byUid.values()];
}

/* ------------------------------------------------------------------ *
 * 五、组装目标登录态（保留原文件结构，只替换账号相关字段）
 * ------------------------------------------------------------------ */
function unionInto(template, override) {
  const out = {};
  for (const k of Object.keys(template || {})) {
    out[k] = override?.[k] !== undefined ? override[k] : template[k];
  }
  for (const k of Object.keys(override || {})) {
    if (!(k in out)) out[k] = override[k];
  }
  return out;
}

function buildAccount(target, template, key) {
  const src = template && typeof template === "object" ? template : target.account;
  const out = unionInto(src, target.account);
  out.uid = target.uid;
  out.lastLogin = true;
  applyEncryptedFields(out, target, key);
  return out;
}

function buildAuth(target, template, key) {
  const out = unionInto(template, target.auth);
  out.accessToken = target.auth.accessToken;
  if (target.auth.refreshToken) out.refreshToken = target.auth.refreshToken;
  else delete out.refreshToken;
  out.lastRefreshTime = target.auth.lastRefreshTime ?? template?.lastRefreshTime ?? Date.now();
  applyEncryptedAuth(out, key);
  return out;
}

function buildSlimAccount(target, template, key) {
  const hasTemplate = template && typeof template === "object";
  const src = hasTemplate ? template : target.account;
  const out = {};
  // 有模板时严格按模板的键集合输出（客户端写入列表时本身会裁掉 deployStatus/sso 等键）
  for (const k of Object.keys(src)) {
    out[k] = target.account[k] !== undefined ? target.account[k] : src[k];
  }
  if (!hasTemplate) {
    for (const k of Object.keys(target.account)) if (!(k in out)) out[k] = target.account[k];
  }
  out.uid = target.uid;
  out.lastLogin = true;
  applyEncryptedFields(out, target, key);
  return out;
}

/** 加密账号对象里的敏感字段（昵称/手机号与客户端一致：手机号按掩码形态落盘） */
function applyEncryptedFields(obj, target, key) {
  if (obj.nickname !== undefined) obj.nickname = wrapField(target.account.nickname ?? "", key);
  if (obj.phoneNumber !== undefined) obj.phoneNumber = wrapField(maskPhone(target.account.phoneNumber ?? ""), key);
}
function applyEncryptedAuth(auth, key) {
  auth.accessToken = wrapField(auth.accessToken, key);
  if (auth.refreshToken) auth.refreshToken = wrapField(auth.refreshToken, key);
}

function replaceEntries(arr, oldUid, slim) {
  if (!Array.isArray(arr) || arr.length === 0) return [slim];
  let replaced = false;
  const out = arr.map((e) => {
    if (e && typeof e === "object" && e.uid === oldUid) {
      replaced = true;
      return slim;
    }
    return e && typeof e === "object" ? { ...e, lastLogin: false } : e;
  });
  if (!replaced) out.unshift(slim);
  return out;
}

function buildNextInfo(live, target, key) {
  const templateAccount = live.account;
  const templateAuth = live.auth;
  const templateSlim =
    (Array.isArray(live.accounts) ? live.accounts.find((e) => e?.uid === live.account?.uid) : null)
    ?? (Array.isArray(live.accounts) ? live.accounts[0] : null)
    ?? (Array.isArray(live.allAccounts) ? live.allAccounts[0] : null)
    ?? target.slim;

  const next = { ...live };
  next.account = buildAccount(target, templateAccount, key);
  next.auth = buildAuth(target, templateAuth, key);
  next.accounts = replaceEntries(live.accounts, live.account?.uid, buildSlimAccount(target, templateSlim, key));
  next.allAccounts = replaceEntries(live.allAccounts, live.account?.uid, buildSlimAccount(target, templateSlim, key));
  return next;
}

/* ------------------------------------------------------------------ *
 * 六、写文件 / 备份 / 还原
 * ------------------------------------------------------------------ */
const STAMP = () => new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "Z").replace("T", "-");

function writeAuthFile(authFile, text) {
  const tmp = `${authFile}.tmp-${process.pid}`;
  const mode = (() => {
    try {
      return fs.statSync(authFile).mode & 0o777;
    } catch {
      return 0o600;
    }
  })();
  fs.writeFileSync(tmp, text, { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, authFile);
}

function listBackups(authFile) {
  const dir = path.dirname(authFile);
  const base = path.basename(authFile) + ".bak-";
  return fs.readdirSync(dir)
    .filter((f) => f.startsWith(base))
    .sort()
    .reverse()
    .map((f) => path.join(dir, f));
}

/* ------------------------------------------------------------------ *
 * 七、参数解析与主流程
 * ------------------------------------------------------------------ */
function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (!item.startsWith("--")) {
      args._.push(item);
      continue;
    }
    const key = item.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) args[key] = true;
    else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function resolveTarget(cands, spec) {
  if (/^\d+$/.test(String(spec))) {
    const idx = Number(spec);
    if (idx >= 1 && idx <= cands.length) return cands[idx - 1];
    throw new Error(`序号 ${idx} 超出范围（共 ${cands.length} 个候选账号）`);
  }
  const exact = cands.find((c) => c.uid === spec);
  if (exact) return exact;
  const prefixed = cands.filter((c) => c.uid.startsWith(String(spec)));
  if (prefixed.length === 1) return prefixed[0];
  if (prefixed.length > 1) throw new Error(`uid 前缀 "${spec}" 匹配到多个账号，请写全`);
  throw new Error(`未找到账号 "${spec}"`);
}

function fmtTime(ms) {
  if (!ms) return "未知";
  const d = new Date(Number(ms));
  if (Number.isNaN(d.getTime())) return "未知";
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function describe(cand, key) {
  const nickRaw = cand.account?.nickname;
  const phoneRaw = cand.account?.phoneNumber;
  let nick = typeof nickRaw === "string" ? nickRaw : null;
  let phone = typeof phoneRaw === "string" ? phoneRaw : null;
  if (key) {
    for (const [raw, set] of [[nickRaw, (v) => (nick = v)], [phoneRaw, (v) => (phone = v)]]) {
      if (isWrapped(raw)) {
        try {
          set(unwrapField(raw, key));
        } catch {}
      }
    }
  }
  return { nick, phone: phone ? maskPhone(phone) : null, expiresAt: cand.auth?.expiresAt };
}

const HELP = `WorkBuddy 桌面端换号脚本

  node switch.mjs --list                列出候选账号与当前账号
  node switch.mjs --to <序号|uid>       切换到目标账号（免重新登录）
  node switch.mjs --to <序号|uid> --yes 跳过交互确认
  node switch.mjs --restore [备份名]    还原备份（默认最近一次）

可选：--file <info>  --hub <db>  --db <db>  --bin <主程序>  --force
换号后需完全退出并重新启动 WorkBuddy 客户端才会生效。`;

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help || args.h) {
    console.log(HELP);
    return 0;
  }

  const authFile = locateAuthFile(typeof args.file === "string" ? args.file : undefined);
  const begin = fs.readFileSync(authFile, "utf8");
  const live = JSON.parse(begin);
  const bin = locateWbBin(typeof args.bin === "string" ? args.bin : undefined);
  const hubDb = (typeof args.hub === "string" && args.hub) || process.env.CHECKIN_HUB_DB || path.join(SCRIPT_DIR, "..", "checkin-hub.sqlite3");
  const sessionsDb = (typeof args.db === "string" && args.db) || process.env.WORKBUDDY_CHECKIN_DB || path.join(SCRIPT_DIR, "..", "workbuddy-checkin.sqlite3");

  const currentUid = live.account?.uid;
  const cands = loadCandidates({ hubDb, sessionsDb });
  const key = bin ? protectorKey(bin) : null;

  /* ---------- --list ---------- */
  if (args.list === true) {
    const curD = describe({ account: live.account, auth: live.auth }, key);
    console.log(`登录态文件：${authFile}`);
    console.log(`客户端当前账号：${currentUid}  ${curD.nick ?? "(昵称未解密)"}`);
    console.log(`主程序：${bin || "(未找到，昵称/手机号无法解密)"}`);
    console.log(`\n候选账号（${cands.length} 个）：`);
    cands.forEach((c, i) => {
      const d = describe(c, key);
      const expired = c.auth.expiresAt && Number(c.auth.expiresAt) < Date.now() ? " [令牌已过期，客户端会自动续期]" : "";
      console.log(`  [${i + 1}] ${c.uid}`);
      console.log(`      ${d.nick ?? "(昵称未解密)"}  ${d.phone ?? ""}  令牌到期 ${fmtTime(d.expiresAt)}${expired}  来源 ${c.source}${c.uid === currentUid ? "  ← 当前账号" : ""}`);
    });
    return 0;
  }

  /* ---------- --restore ---------- */
  if (args.restore !== undefined) {
    const pids = runningPids(bin);
    if (pids.length && args.force !== true) {
      console.error(`检测到 WorkBuddy 客户端正在运行（pid ${pids.join(", ")}），为避免登录态被覆盖已终止。请完全退出后重试，或用 --force 强制。`);
      return 3;
    }
    const backups = listBackups(authFile);
    if (!backups.length) {
      console.error(`未找到备份（${path.basename(authFile)}.bak-*）`);
      return 2;
    }
    const want = typeof args.restore === "string" ? args.restore : null;
    const chosen = want ? backups.find((p) => p.includes(want)) : backups[0];
    if (!chosen) {
      console.error(`未找到匹配 "${want}" 的备份。现有备份：\n${backups.map((p) => "  " + path.basename(p)).join("\n")}`);
      return 2;
    }
    const back = `${authFile}.bak-${STAMP()}`;
    fs.copyFileSync(authFile, back);
    writeAuthFile(authFile, fs.readFileSync(chosen, "utf8"));
    console.log(`已还原：${path.basename(chosen)}`);
    console.log(`还原前状态已另行备份：${path.basename(back)}`);
    console.log("请完全退出并重新启动 WorkBuddy 客户端使其生效。");
    return 0;
  }

  /* ---------- 换号 ---------- */
  if (typeof args.to !== "string" || !args.to) {
    console.error("请用 --to <序号|uid> 指定目标账号，或 --list 查看候选、--restore 还原备份。");
    console.log(HELP);
    return 2;
  }
  if (!cands.length) {
    console.error("未从数据库读到任何 workbuddy 账号，请确认 checkin-hub.sqlite3 / workbuddy-checkin.sqlite3 路径（--hub / --db）");
    return 2;
  }
  if (!key) {
    console.error("未找到 WorkBuddy 主程序，无法加密写入（可用 --bin 指定主程序路径）");
    return 2;
  }

  const target = resolveTarget(cands, args.to);
  if (target.uid === currentUid) {
    console.log(`当前已是该账号（${target.uid}），无需切换。`);
    return 5;
  }

  const pids = runningPids(bin);
  if (pids.length && args.force !== true) {
    console.error(`检测到 WorkBuddy 客户端正在运行（pid ${pids.join(", ")}），运行中写入会被客户端覆盖，已终止。请完全退出客户端后重试，或用 --force 强制。`);
    return 3;
  }

  const cur = describe({ account: live.account, auth: live.auth }, key);
  const dst = describe(target, key);
  const next = buildNextInfo(live, target, key);
  const text = JSON.stringify(next, null, 2);

  console.log("即将切换 WorkBuddy 桌面端登录态：");
  console.log(`  当前：${currentUid}  ${cur.nick ?? ""}  ${cur.phone ?? ""}`);
  console.log(`  切换：${target.uid}  ${dst.nick ?? ""}  ${dst.phone ?? ""}  （令牌到期 ${fmtTime(dst.expiresAt)}）`);
  console.log(`  来源：${target.source}`);
  console.log(`  文件：${authFile}`);

  if (target.auth.expiresAt && Number(target.auth.expiresAt) < Date.now()) {
    console.log("  提示：目标账号 accessToken 已过期，客户端启动时会用 refreshToken 自动续期。");
  }
  if (text === begin) {
    console.log("目标登录态与当前文件内容一致，无需写入。");
    return 5;
  }

  if (args.yes !== true) {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    const answer = await rl.question("确认写入？[y/N] ");
    rl.close();
    if (!/^y(es)?$/i.test(answer.trim())) {
      console.log("已取消。");
      return 1;
    }
  }

  const backup = `${authFile}.bak-${STAMP()}`;
  fs.copyFileSync(authFile, backup);
  writeAuthFile(authFile, text);

  // 自校验：重新读回并解密，确认关键字段可解且 uid 正确
  const check = JSON.parse(fs.readFileSync(authFile, "utf8"));
  const gotUid = check.account?.uid;
  const gotNick = unwrapField(check.account?.nickname, key);
  const gotToken = unwrapField(check.auth?.accessToken, key);
  const ok = gotUid === target.uid && gotToken === target.auth.accessToken;
  console.log(`\n已写入。备份：${path.basename(backup)}`);
  console.log(`自校验：uid=${gotUid}（${gotUid === target.uid ? "✔" : "✘"}）昵称=${gotNick} 令牌${ok ? "解密一致 ✔" : "异常 ✘"}`);
  if (!ok) {
    console.error("自校验未通过，建议执行 --restore 还原备份。");
    return 4;
  }
  console.log("请完全退出并重新启动 WorkBuddy 客户端，即以目标账号登录。");
  return 0;
}

try {
  process.exitCode = await main();
} catch (e) {
  console.error(String((e && e.message) || e));
  process.exitCode = 2;
}
