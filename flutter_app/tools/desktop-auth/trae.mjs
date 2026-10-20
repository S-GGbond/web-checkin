#!/usr/bin/env node
/**
 * Trae CN 桌面端「换号」工具（Windows / Linux / macOS）
 *
 * 把 checkin-hub.sqlite3 中已保存的某个 Trae 账号，写回客户端登录态
 * （storage.json 的 iCubeAuthInfo://icube.cloudide），然后自动重启客户端，
 * 免去重新扫码登录。
 *
 * 用法：
 *   node trae.mjs list                       查看客户端当前账号与候选账号
 *   node trae.mjs switch --to 2              切换到第 2 个候选账号
 *   node trae.mjs switch --to 246444685...   按 userId（支持唯一前缀）切换
 *   node trae.mjs switch --to 2 --no-restart 只写登录态，不重启客户端
 *   node trae.mjs restore [备份名]            还原最近一次 / 指定备份
 *   node trae.mjs dump                       只读打印当前登录态（敏感字段打码）
 *
 * 可选参数：
 *   --hub <path>   指定 checkin-hub.sqlite3
 *   --file <path>  指定 storage.json（默认自动探测本机全部 Trae 变体）
 *   --bin <path>   指定客户端主程序，用于切换后重启
 *   --no-restart   切换后不自动启动客户端
 *
 * 注意：客户端运行时会覆盖登录态，脚本会先完全退出客户端再写入。
 */
import fs from "node:fs";
import path from "node:path";

import { parseArgs, loadAccounts, resolveHubDb, resolveTarget } from "./lib/accounts.mjs";
import {
  TRAE_AUTH_KEY,
  findTraeExe,
  launchClient,
  listBackups,
  backupFile,
  runningPids,
  stopClient,
  traeProcessMatchers,
  traeStorageFiles,
  writeFileAtomic,
} from "./lib/clients.mjs";
import { decrypt, encrypt, versionOf } from "./lib/crypto-trae.mjs";

const SENSITIVE = /token|secret|key|password|cookie|proof/i;
const USERTAG_KEY = "iCubeAuthInfo://usertag";

/**
 * 补齐客户端校验登录态时依赖的账号字段。
 *
 * 客户端 `UserInfoManager` 的第一道判断是 `if (!userInfo.account.scope) return`，
 * scope 为空会直接当成未登录（即使 token 有效）；而应用自己的登录流程走
 * GetUserInfo，部分账号不返回 Scope / LoginScope / StoreRegion / UserTag。
 */
function normalizeAuth(auth) {
  const account = auth?.account;
  if (!account || typeof account !== "object") return auth;
  const region = String(auth.userRegion?.region || auth.userRegion?._aiRegion || "CN");
  const fill = (key, value) => {
    if (account[key] == null || String(account[key]) === "") account[key] = value;
  };
  fill("scope", "marscode");
  fill("loginScope", "trae");
  fill("storeRegion", region);
  fill("storeCountryCode", "");
  fill("storeCountrySrc", "");
  fill("userTag", "cn");
  if (account.migrateToSG == null) account.migrateToSG = false;
  return auth;
}

/**
 * 同步 `iCubeAuthInfo://usertag`（userId → 地区）。
 * 客户端按这张表判断登录态属于哪个区，缺目标 userId 时即使 token 有效也会被当成未登录。
 */
function syncUsertag(storage, auth) {
  const raw = storage[USERTAG_KEY];
  const userId = auth?.userId != null ? String(auth.userId) : "";
  if (raw == null || !userId) return;
  const text = String(raw);
  const plain = text.trimStart().startsWith("{");
  let map;
  try {
    map = plain ? JSON.parse(text) : decrypt(text);
  } catch {
    return; // 解不开就不动，避免写坏
  }
  if (!map || typeof map !== "object" || Array.isArray(map)) return;
  let region = String(map[userId] ?? "").toLowerCase();
  if (!region && auth.userRegion && typeof auth.userRegion === "object" && auth.userRegion.region) {
    region = String(auth.userRegion.region).toLowerCase();
  }
  map[userId] = region || "cn";
  storage[USERTAG_KEY] = plain ? JSON.stringify(map) : encrypt(map);
}

function maskUser(userId, name) {
  return `${name || "未知昵称"}（${userId || "无 userId"}）`;
}

function currentAuth(file) {
  try {
    const storage = JSON.parse(fs.readFileSync(file, "utf8"));
    const raw = storage[TRAE_AUTH_KEY];
    if (raw == null) return null;
    const text = String(raw);
    return text.trimStart().startsWith("{") ? JSON.parse(text) : decrypt(text);
  } catch {
    return null;
  }
}

function storageFiles(explicit) {
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Error(`storage.json 不存在：${explicit}`);
    return [explicit];
  }
  return traeStorageFiles();
}

function printList(files, accounts) {
  if (!files.length) {
    console.log("未找到 Trae 客户端登录态文件（storage.json）。");
    console.log("可用 --file 指定，或先启动一次 Trae 客户端完成登录。");
  }
  for (const file of files) {
    const auth = currentAuth(file);
    console.log(`登录态文件：${file}`);
    console.log(`  客户端当前：${auth ? maskUser(auth.userId, auth.account?.username) : "未登录 / 无法解析"}`);
  }
  console.log(`\n候选账号（${accounts.length} 个，来自 ${resolveHubDb() ?? "未找到账号库"}）：`);
  accounts.forEach((account, index) => {
    console.log(`  [${index + 1}] ${maskUser(account.externalId, account.displayName)}${account.enabled ? "" : "  （已停用）"}`);
  });
}

function dump(files) {
  for (const file of files) {
    const auth = currentAuth(file);
    console.log(`\n[${path.basename(path.dirname(path.dirname(path.dirname(file))))}] ${file}`);
    if (!auth) {
      console.log("  未登录或格式未知");
      continue;
    }
    console.log(
      JSON.stringify(
        auth,
        (key, value) => (SENSITIVE.test(key) && typeof value === "string" ? `${value.slice(0, 6)}…(${value.length}B)` : value),
        2,
      ),
    );
  }
}

async function switchAccount({ files, exe, account, auth, restart }) {
  const matchers = traeProcessMatchers();
  const wasRunning = runningPids(matchers).length > 0;
  if (wasRunning) {
    console.log("正在退出 Trae 客户端…");
    const left = await stopClient(matchers);
    if (left.length) {
      throw new Error(`客户端仍在运行（pid ${left.join(", ")}），为避免登录态被覆盖已终止`);
    }
  }

  for (const file of files) {
    const original = fs.readFileSync(file, "utf8");
    const storage = JSON.parse(original);
    const backup = backupFile(file);
    storage[TRAE_AUTH_KEY] = encrypt(normalizeAuth(auth));
    syncUsertag(storage, auth);
    // 保持客户端原有的排版：单行 JSON 仍写单行。
    writeFileAtomic(file, original.includes("\n") ? JSON.stringify(storage, null, "\t") : JSON.stringify(storage));
    console.log(`已写入 ${file}`);
    console.log(`  备份：${backup}`);
  }

  if (!restart) {
    console.log("已跳过重启，请手动启动 Trae 客户端使登录态生效。");
    return;
  }
  if (!exe) {
    console.log("未找到 Trae 主程序，无法自动重启；请手动启动客户端。");
    return;
  }
  launchClient(exe);
  console.log(`已启动：${exe}`);
}

async function restore({ files, exe, spec, restart }) {
  const matchers = traeProcessMatchers();
  if (runningPids(matchers).length) {
    const left = await stopClient(matchers);
    if (left.length) throw new Error(`客户端仍在运行（pid ${left.join(", ")}）`);
  }
  for (const file of files) {
    const backups = listBackups(file);
    if (!backups.length) {
      console.log(`未找到备份：${file}.bak-*`);
      continue;
    }
    const chosen = spec && spec !== true ? backups.find((item) => item.includes(String(spec))) : backups[0];
    if (!chosen) {
      console.log(`未找到匹配「${spec}」的备份。现有备份：\n${backups.map((item) => `  ${path.basename(item)}`).join("\n")}`);
      continue;
    }
    backupFile(file);
    writeFileAtomic(file, fs.readFileSync(chosen, "utf8"));
    console.log(`已还原 ${file} ← ${path.basename(chosen)}`);
  }
  if (restart && exe) {
    launchClient(exe);
    console.log(`已启动：${exe}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] ?? "list";
  const files = storageFiles(typeof args.file === "string" ? args.file : undefined);
  const accounts = await loadAccounts(resolveHubDb(typeof args.hub === "string" ? args.hub : undefined), "trae");
  const exe = typeof args.bin === "string" ? args.bin : findTraeExe();
  const restart = args["no-restart"] !== true;

  if (command === "list") {
    printList(files, accounts);
    console.log(`主程序：${exe ?? "未找到（切换后需手动启动）"}`);
    return 0;
  }
  if (command === "dump") {
    dump(files);
    return 0;
  }
  if (command === "restore") {
    if (!files.length) throw new Error("未找到 storage.json，可用 --file 指定");
    await restore({ files, exe, spec: args._[1], restart });
    return 0;
  }
  if (command === "switch") {
    if (!files.length) throw new Error("未找到 storage.json，可用 --file 指定");
    if (!accounts.length) throw new Error("账号库中没有 Trae 账号，请先在客户端里添加并登录");
    const account = resolveTarget(accounts, args.to);
    const current = files.map((file) => currentAuth(file)?.userId).filter(Boolean);
    if (current.length && current.every((userId) => userId === account.externalId)) {
      console.log(`客户端当前已是 ${account.externalId}，无需切换。`);
      return 5;
    }
    // 校验 credential 是合法的 tc 容器，避免把坏数据写进客户端
    versionOf(Buffer.from(account.credential, "base64"));
    let auth;
    try {
      auth = decrypt(account.credential);
    } catch (error) {
      throw new Error(`账号库中的 Trae 登录态无法解密，请重新登录该账号：${error.message}`);
    }
    console.log(`切换到：${maskUser(account.externalId, account.displayName)}`);
    await switchAccount({ files, exe, account, auth, restart });
    return 0;
  }
  throw new Error(`未知命令「${command}」，支持 list / switch / restore / dump`);
}

main()
  .then((code) => process.exit(code))
  .catch((error) => {
    console.error(`失败：${error.message}`);
    process.exit(2);
  });
