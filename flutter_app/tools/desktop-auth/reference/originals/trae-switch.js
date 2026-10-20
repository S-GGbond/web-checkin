#!/usr/bin/env node
/**
 * Trae 桌面端换号（登录态热切换，无需重新登录）
 *
 * 原理：桌面端的登录态就是 storage.json 里的键 iCubeAuthInfo://icube.cloudide
 *   （值为 tc 格式密文，见 auth.js）。SQLite accounts 表里已由 weblogin.js 存好
 *   多个账号的同款密文。换号 = 把目标账号的密文覆盖写入该键，客户端下次启动即生效；
 *   同时同步 iCubeAuthInfo://usertag 的 user_id→地区 映射。
 *
 * 前置条件：
 *   1. 目标账号已用 weblogin.js 登录入库（没入库就得重新登录，本脚本无法凭空生成登录态）；
 *   2. Trae 桌面端已关闭 —— 客户端退出时会回写 storage.json，运行中写入会被覆盖。
 *
 * 用法：
 *   node switch.js                    列出账号并交互选择
 *   node switch.js --to <序号|userId>  直接切到指定账号
 *   node switch.js --list             仅列出账号与当前登录号
 *   node switch.js --restore [<备份>]  还原最近一次（或指定）备份
 *   node switch.js --yes              跳过二次确认
 *   node switch.js --force            客户端在运行时/校验失败时仍强制写入
 *   node switch.js --file <path>      指定 storage.json（默认自动定位）
 *
 * 安全：只写加密密文，不落盘明文，不打印任何令牌。
 */
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const readline = require("readline");
const { AUTH_KEY, decrypt, encrypt, scan } = require("./auth.js");
const { listAccounts, updateAuthEnc, addLog } = require("./db.js");
const { buildHeaders } = require("./lib.js");

const USERTAG_KEY = "iCubeAuthInfo://usertag";
const CLIENT_ID = "ono9krqynydwx5";
const NEAR_EXPIRY_MS = 30 * 60 * 1000;

function pick(res, ...keys) { for (const k of keys) if (res && res[k] != null) return res[k]; return undefined; }

/* ---------- storage.json 定位与读写 ---------- */
/** 优先用显式 --file；否则扫描本机候选，取第一个含登录态键的 */
function resolveStorage(explicit) {
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Error("指定的 storage.json 不存在: " + explicit);
    return explicit;
  }
  for (const s of scan()) {
    try {
      const j = JSON.parse(fs.readFileSync(s.path, "utf8"));
      if (j[AUTH_KEY]) return s.path;
    } catch { /* 该文件损坏，跳过 */ }
  }
  throw new Error("未找到含登录态的 storage.json（请确认已安装并登录 Trae 桌面端）");
}
function readStorage(p) { return JSON.parse(fs.readFileSync(p, "utf8")); }
/** 原子写入，避免客户端读到半截文件；缩进与客户端一致（4 空格） */
function writeStorage(p, obj) {
  const tmp = `${p}.tmp-switch-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 4));
  fs.renameSync(tmp, p);
}
/** 按原值形态编码：原为明文 JSON 则写明文，否则写 tc 密文 */
function encodeLike(raw, obj) {
  return String(raw).trim().startsWith("{") ? JSON.stringify(obj) : encrypt(obj);
}
/** 读取当前生效账号（userId/username），解不开返回 null */
function currentAccount(p) {
  const raw = readStorage(p)[AUTH_KEY];
  if (!raw) return null;
  try {
    const a = String(raw).trim().startsWith("{") ? JSON.parse(raw) : decrypt(raw);
    return { userId: String(a.userId || ""), username: (a.account && (a.account.username || a.account.email)) || "" };
  } catch { return null; }
}
/** 最佳努力检测桌面端是否在运行（退出时会回写 storage.json 覆盖本次改动） */
function clientRunning() {
  if (process.platform === "win32") {
    try {
      const out = execFileSync("tasklist", ["/NH"], { encoding: "utf8" });
      if (/^(Trae CN|Trae|TRAE SOLO CN|TRAE SOLO)\.exe/i.test(out.trim())) return true;
    } catch { /* 取不到进程列表就当作未运行 */ }
    return false;
  }
  for (const pat of ["trae-cn", "TRAE SOLO", "Trae CN"]) {
    try {
      if (execFileSync("pgrep", ["-f", pat], { encoding: "utf8" }).trim()) return true;
    } catch { /* 无匹配或 pgrep 不可用 */ }
  }
  return false;
}

/* ---------- 续期（与 balance/checkin-all 一致；轮换 refreshToken 必须回写） ---------- */
async function refreshAuth(auth) {
  const r = await fetch(`${auth.host}/cloudide/api/v3/trae/oauth/ExchangeToken`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({
      ClientID: CLIENT_ID,
      RefreshToken: auth.refreshToken,
      ClientSecret: "-",
      UserID: String(auth.userId || ""),
    }),
  });
  const j = await r.json().catch(() => ({}));
  const res = j && j.Result;
  const newToken = pick(res, "Token", "token");
  if (!newToken) throw new Error(`续期失败: ${j.message || j.Message || "HTTP " + r.status}`);
  auth.token = newToken;
  const nr = pick(res, "RefreshToken", "refreshToken");
  if (nr) auth.refreshToken = nr;
  const exp = pick(res, "TokenExpireAt", "tokenExpireAt");
  const dur = pick(res, "TokenExpireDuration", "tokenExpireDuration");
  if (exp != null) {
    const n = Number(exp);
    auth.expiredAt = (Number.isFinite(n) && n > Date.now())
      ? new Date(n).toISOString()
      : dur ? new Date(Date.now() + Number(dur)).toISOString() : auth.expiredAt;
  }
  auth._dirty = true;
  return auth;
}

/* ---------- 目标账号登录态可用性校验（查签到状态，只读） ---------- */
let _identity = null;
function identity() {
  if (_identity) return _identity;
  try { _identity = JSON.parse(fs.readFileSync(path.join(__dirname, "identity.json"), "utf8")); }
  catch { _identity = { machineId: "" }; }
  return _identity;
}
let _ver = null;
function clientVersion() {
  if (_ver) return _ver;
  try {
    const v = JSON.parse(fs.readFileSync("/usr/share/trae-cn/resources/app/package.json", "utf8")).version;
    if (v) { _ver = v; return _ver; }
  } catch { /* 读不到用默认 */ }
  _ver = "3.3.99"; return _ver;
}
async function verify(auth) {
  try {
    const r = await fetch(`${auth.host}/trae/api/v2/ug/checkin_credits/status`, {
      method: "POST",
      headers: buildHeaders(auth.token, String(auth.userId || ""), {
        machineId: identity().machineId || undefined,
        ideVersion: clientVersion(),
      }),
      body: JSON.stringify({}),
    });
    const j = await r.json().catch(() => ({}));
    if (r.status === 401) return { ok: false, message: "登录态已失效（401）" };
    if (!(j && j.code === 0)) return { ok: false, message: (j && j.message) || ("HTTP " + r.status) };
    return { ok: true };
  } catch (e) {
    return { ok: false, message: "校验请求失败: " + e.message };
  }
}

/* ---------- 交互 ---------- */
function ask(q) {
  return new Promise((res) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(q, (a) => { rl.close(); res(a.trim()); });
  });
}
function stamp() {
  const d = new Date(), p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/* ---------- 还原备份 ---------- */
function doRestore(storagePath, arg, force) {
  const dir = path.dirname(storagePath);
  const prefix = path.basename(storagePath) + ".bak-";
  let bak = arg && !arg.startsWith("-") ? arg : null;
  if (!bak) {
    const cands = fs.readdirSync(dir).filter((f) => f.startsWith(prefix)).sort();
    if (!cands.length) { console.log("未找到备份文件（" + prefix + "*）。"); process.exit(2); }
    bak = path.join(dir, cands[cands.length - 1]);
  }
  if (clientRunning() && !force) { console.log("Trae 桌面端正在运行，请先完全退出后再还原（或加 --force）。"); process.exit(3); }
  const cur = `${storagePath}.bak-before-restore-${stamp()}`;
  fs.copyFileSync(storagePath, cur);
  fs.copyFileSync(bak, storagePath);
  console.log(`已还原 : ${bak}`);
  console.log(`还原前已另存 : ${cur}`);
  console.log("请重新启动 Trae 桌面端。");
}

/* ---------- 同步 usertag（user_id → 地区） ---------- */
function syncUsertag(s, userId) {
  const raw = s[USERTAG_KEY];
  if (!raw) return;
  let map;
  try { map = String(raw).trim().startsWith("{") ? JSON.parse(raw) : decrypt(raw); }
  catch { return; }                                  // 解不开就不动，避免写坏
  if (!map || typeof map !== "object" || Array.isArray(map)) return;
  const region = String(map[userId] || "cn").toLowerCase();
  map[userId] = region;
  s[USERTAG_KEY] = encodeLike(raw, map);
}

/* ---------- 主流程 ---------- */
(async () => {
  const argv = process.argv.slice(2);
  const has = (f) => argv.includes(f);
  const argVal = (name) => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : null; };

  const storagePath = resolveStorage(argVal("--file"));

  if (has("--restore")) { doRestore(storagePath, argVal("--restore"), has("--force")); return; }

  const accounts = listAccounts({ enabledOnly: true });
  if (accounts.length === 0) { console.log("账号列表为空，请先执行 weblogin.js 登录入库。"); process.exit(2); }

  const cur = currentAccount(storagePath);
  console.log("== Trae 桌面端换号 ==");
  console.log("storage.json :", storagePath);
  console.log("当前登录账号 :", cur ? `${cur.username || "(无名)"} (${cur.userId})` : "(未识别)");
  console.log("\n已入库的账号（SQLite accounts）：");
  accounts.forEach((a, i) => {
    const active = cur && cur.userId === a.userId ? "  ← 当前" : "";
    console.log(`  [${i + 1}] ${a.username || "(无名)"}  uid=${a.userId}  更新于 ${a.updatedAt}${active}`);
  });

  if (has("--list")) return;

  // 选定目标账号
  let target = null;
  const to = argVal("--to");
  if (to != null) {
    target = accounts.find((a) => a.userId === String(to))
      || (/^\d+$/.test(to) && +to >= 1 && +to <= accounts.length ? accounts[+to - 1] : null);
    if (!target) { console.log(`\n未找到账号：${to}`); process.exit(2); }
  } else {
    const a = await ask("\n输入要切换到的账号序号（回车取消）: ");
    if (!a) { console.log("已取消。"); return; }
    target = /^\d+$/.test(a) && +a >= 1 && +a <= accounts.length
      ? accounts[+a - 1] : accounts.find((x) => x.userId === a);
    if (!target) { console.log("无效选择。"); process.exit(2); }
  }

  if (cur && cur.userId === target.userId && !has("--force")) {
    console.log(`\n当前已是 ${target.username || target.userId}，无需切换（--force 可强制重写）。`);
    return;
  }

  // 客户端运行中禁止写入：退出时会回写覆盖
  if (clientRunning() && !has("--force")) {
    console.log("\n检测到 Trae 桌面端正在运行：客户端退出时会回写 storage.json，将覆盖本次改动。");
    console.log("请先完全退出 Trae，再重新执行本脚本（或加 --force 强制写入，但可能被覆盖）。");
    process.exit(3);
  }

  if (!has("--yes")) {
    const a = await ask(`\n确认把桌面端登录账号从 ${cur ? (cur.username || cur.userId) : "(未登录)"} 切换为 ${target.username || target.userId} ？[y/N] `);
    if (!/^y(es)?$/i.test(a)) { console.log("已取消。"); return; }
  }

  // 1) 解密目标登录态
  let auth = decrypt(target.authEnc);
  auth.host = auth.host || target.host || "https://api.trae.cn";

  // 2) 临期则续期（轮换 refreshToken 回写 DB，否则旧 refresh 失效）
  const exp = auth.expiredAt ? new Date(auth.expiredAt).getTime() : 0;
  if (!exp || exp - Date.now() < NEAR_EXPIRY_MS) {
    if (!auth.refreshToken) { console.log("\n目标账号无 refreshToken，无法续期，请执行 weblogin.js 重新登录。"); process.exit(4); }
    await refreshAuth(auth);
  }
  if (auth._dirty) {
    const { _dirty, ...clean } = auth;
    updateAuthEnc(target.userId, encrypt(clean));
    auth = clean;
    console.log("\n已续期并回写新令牌到数据库。");
  }

  // 3) 校验登录态可用，避免把失效账号写进客户端
  const v = await verify(auth);
  if (!v.ok && !has("--force")) {
    console.log(`\n目标账号登录态不可用：${v.message}`);
    console.log("请先执行 weblogin.js 重新登录该账号，或加 --force 强制写入。");
    addLog({ userId: target.userId, username: target.username, action: "switch", ok: false, message: "登录态校验失败: " + v.message });
    process.exit(4);
  }
  if (!v.ok) console.log(`\n[警告] 登录态校验未通过（${v.message}），已按 --force 强制写入。`);

  // 4) 备份后覆盖写入
  const s = readStorage(storagePath);
  const bak = `${storagePath}.bak-${stamp()}`;
  fs.copyFileSync(storagePath, bak);
  s[AUTH_KEY] = encodeLike(s[AUTH_KEY], auth);
  syncUsertag(s, String(auth.userId));
  writeStorage(storagePath, s);

  addLog({ userId: target.userId, username: target.username, action: "switch", ok: true, message: `切至 ${target.userId}` });
  console.log("\n== 切换成功 ==");
  console.log(`新账号   : ${(auth.account && auth.account.username) || target.username || "(无名)"} (${auth.userId})`);
  console.log(`备份     : ${bak}`);
  console.log(`令牌到期 : ${auth.expiredAt}`);
  console.log("\n请重新启动 Trae 桌面端使新登录态生效。");
  console.log(`如需回滚：node switch.js --restore ${bak}`);
})().catch((e) => { console.error("错误：" + e.message); process.exit(1); });
