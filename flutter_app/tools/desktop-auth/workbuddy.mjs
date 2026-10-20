#!/usr/bin/env node
/**
 * WorkBuddy 桌面端「换号」工具（Windows / Linux / macOS）
 *
 * 把 checkin-hub.sqlite3 中已保存的某个 WorkBuddy 账号，写回客户端登录态
 * （workbuddy-desktop.info，敏感字段用 $wbEncrypted 信封重新加密），
 * 然后自动重启客户端，不需要再走浏览器授权。
 *
 * 用法：
 *   node workbuddy.mjs list                       查看客户端当前账号与候选账号
 *   node workbuddy.mjs switch --to 2              切换到第 2 个候选账号
 *   node workbuddy.mjs switch --to f9d35b32-...   按 uid（支持唯一前缀）切换
 *   node workbuddy.mjs switch --to 2 --no-restart 只写登录态，不重启客户端
 *   node workbuddy.mjs restore [备份名]            还原最近一次 / 指定备份
 *   node workbuddy.mjs dump                       只读打印当前登录态（敏感字段打码）
 *
 * 可选参数：
 *   --hub <path>   指定 checkin-hub.sqlite3
 *   --file <path>  指定 workbuddy-desktop.info
 *   --bin <path>   指定客户端主程序（用于取本机密钥、切换后重启）
 *   --no-restart   切换后不自动启动客户端
 *
 * 注意：客户端运行时会覆盖登录态，脚本会先完全退出客户端再写入。
 */
import fs from "node:fs";
import path from "node:path";

import { parseArgs, loadAccounts, resolveHubDb, resolveTarget } from "./lib/accounts.mjs";
import {
  findWorkbuddyExe,
  launchClient,
  listBackups,
  backupFile,
  runningPids,
  stopClient,
  workbuddyAuthFiles,
  workbuddyProcessMatchers,
  writeFileAtomic,
} from "./lib/clients.mjs";
import {
  isWrapped,
  maskPhone,
  readProtectorKey,
  unwrapField,
  wrapAccountFields,
  wrapAuthFields,
} from "./lib/crypto-wb.mjs";

function safeParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function describe(entry, key) {
  const nickname = entry?.nickname;
  const phone = entry?.phoneNumber;
  let name = typeof nickname === "string" ? nickname : null;
  let number = typeof phone === "string" ? phone : null;
  if (key) {
    if (isWrapped(nickname)) {
      try {
        name = unwrapField(nickname, key);
      } catch {
        // 保留原始状态
      }
    }
    if (isWrapped(phone)) {
      try {
        number = unwrapField(phone, key);
      } catch {
        // 同上
      }
    }
  }
  return { name, phone: number ? maskPhone(number) : null };
}

function unionInto(template, override) {
  const result = {};
  for (const key of Object.keys(template || {})) {
    result[key] = override?.[key] !== undefined ? override[key] : template[key];
  }
  for (const key of Object.keys(override || {})) {
    if (!(key in result)) result[key] = override[key];
  }
  return result;
}

function buildAccount(target, template, key) {
  const source = template && typeof template === "object" ? template : target;
  const result = unionInto(source, target);
  result.uid = target.uid;
  result.lastLogin = true;
  return wrapAccountFields(result, target, key);
}

function buildSlimAccount(target, template, key) {
  const hasTemplate = template && typeof template === "object";
  const source = hasTemplate ? template : target;
  const result = {};
  // 有模板时严格按模板的键集合输出（客户端写入列表时本身会裁掉 deployStatus / sso 等键）
  for (const property of Object.keys(source)) {
    result[property] = target[property] !== undefined ? target[property] : source[property];
  }
  if (!hasTemplate) {
    for (const property of Object.keys(target)) if (!(property in result)) result[property] = target[property];
  }
  result.uid = target.uid;
  result.lastLogin = true;
  return wrapAccountFields(result, target, key);
}

function buildAuth(target, template, key) {
  const result = unionInto(template, target);
  result.accessToken = target.accessToken;
  if (target.refreshToken) result.refreshToken = target.refreshToken;
  else delete result.refreshToken;
  result.lastRefreshTime = target.lastRefreshTime ?? template?.lastRefreshTime ?? Date.now();
  return wrapAuthFields(result, key);
}

function replaceEntries(list, oldUid, slim) {
  if (!Array.isArray(list) || list.length === 0) return [slim];
  let replaced = false;
  const result = list.map((entry) => {
    if (entry && typeof entry === "object" && entry.uid === oldUid) {
      replaced = true;
      return slim;
    }
    return entry && typeof entry === "object" ? { ...entry, lastLogin: false } : entry;
  });
  if (!replaced) result.unshift(slim);
  return result;
}

function buildNextInfo(live, { account, auth, snapshot }, key) {
  const templateSlim =
    (Array.isArray(live.accounts) ? live.accounts.find((entry) => entry?.uid === live.account?.uid) : null) ??
    (Array.isArray(live.accounts) ? live.accounts[0] : null) ??
    (Array.isArray(live.allAccounts) ? live.allAccounts[0] : null) ??
    snapshot?.accounts?.[0] ??
    null;

  const next = { ...live };
  next.account = buildAccount(account, live.account, key);
  next.auth = buildAuth(auth, live.auth, key);
  next.accounts = replaceEntries(live.accounts, live.account?.uid, buildSlimAccount(account, templateSlim, key));
  next.allAccounts = replaceEntries(live.allAccounts, live.account?.uid, buildSlimAccount(account, templateSlim, key));
  return next;
}

function authFile(explicit) {
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Error(`登录态文件不存在：${explicit}`);
    return explicit;
  }
  const found = workbuddyAuthFiles();
  if (!found.length) throw new Error("未找到 workbuddy-desktop.info，可用 --file 指定");
  return found[0];
}

function printList(file, live, accounts, key, bin) {
  const current = describe(live?.account, key);
  console.log(`登录态文件：${file}`);
  console.log(`客户端当前：${live?.account?.uid ?? "未登录"}  ${current.name ?? "(昵称未解密)"}`);
  console.log(`主程序：${bin ?? "未找到（无法解密昵称 / 手机号）"}`);
  console.log(`\n候选账号（${accounts.length} 个，来自 ${resolveHubDb() ?? "未找到账号库"}）：`);
  accounts.forEach((account, index) => {
    const info = describe(account.parsed?.account, key);
    const expiresAt = Number(account.parsed?.auth?.expiresAt ?? 0);
    const expired = expiresAt && expiresAt < Date.now() ? "  [令牌已过期，客户端会自动续期]" : "";
    const currentMark = account.externalId === live?.account?.uid ? "  ← 当前账号" : "";
    console.log(
      `  [${index + 1}] ${account.externalId}  ${info.name ?? "(昵称未解密)"}  ${info.phone ?? ""}${expired}${currentMark}`,
    );
  });
}

function dump(file, key) {
  const text = fs.readFileSync(file, "utf8");
  const live = safeParse(text);
  if (!live) {
    console.log("登录态文件不是合法 JSON");
    return;
  }
  const shown = { ...live };
  for (const field of ["account", "auth"]) {
    if (!live[field] || typeof live[field] !== "object") continue;
    shown[field] = {};
    for (const [property, value] of Object.entries(live[field])) {
      if (!isWrapped(value)) {
        shown[field][property] = value;
        continue;
      }
      if (!key) {
        shown[field][property] = "<$wbEncrypted，需客户端主程序才能解密>";
        continue;
      }
      try {
        const plain = unwrapField(value, key);
        shown[field][property] = /token|secret/i.test(property) ? `${plain.slice(0, 6)}…(${plain.length}B)` : plain;
      } catch (error) {
        shown[field][property] = `<解密失败：${error.message}>`;
      }
    }
  }
  console.log(JSON.stringify(shown, null, 2));
}

async function switchAccount({ file, live, target, key, bin, restart }) {
  const matchers = workbuddyProcessMatchers();
  if (runningPids(matchers).length) {
    console.log("正在退出 WorkBuddy 客户端…");
    const left = await stopClient(matchers);
    if (left.length) throw new Error(`客户端仍在运行（pid ${left.join(", ")}），为避免登录态被覆盖已终止`);
  }

  const original = fs.readFileSync(file, "utf8");
  const next = buildNextInfo(live, target.parsed, key);
  const backup = backupFile(file);
  writeFileAtomic(file, original.includes("\n") ? JSON.stringify(next, null, 2) : JSON.stringify(next));
  console.log(`已写入 ${file}`);
  console.log(`  备份：${backup}`);

  if (!restart) {
    console.log("已跳过重启，请手动启动 WorkBuddy 客户端使登录态生效。");
    return;
  }
  if (!bin) {
    console.log("未找到 WorkBuddy 主程序，无法自动重启；请手动启动客户端。");
    return;
  }
  launchClient(bin);
  console.log(`已启动：${bin}`);
}

async function restore({ file, bin, spec, restart }) {
  const matchers = workbuddyProcessMatchers();
  if (runningPids(matchers).length) {
    const left = await stopClient(matchers);
    if (left.length) throw new Error(`客户端仍在运行（pid ${left.join(", ")}）`);
  }
  const backups = listBackups(file);
  if (!backups.length) throw new Error(`未找到备份：${path.basename(file)}.bak-*`);
  const chosen = spec && spec !== true ? backups.find((item) => item.includes(String(spec))) : backups[0];
  if (!chosen) {
    throw new Error(`未找到匹配「${spec}」的备份。现有备份：\n${backups.map((item) => `  ${path.basename(item)}`).join("\n")}`);
  }
  backupFile(file);
  writeFileAtomic(file, fs.readFileSync(chosen, "utf8"));
  console.log(`已还原 ${file} ← ${path.basename(chosen)}`);
  if (restart && bin) {
    launchClient(bin);
    console.log(`已启动：${bin}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] ?? "list";
  const file = authFile(typeof args.file === "string" ? args.file : undefined);
  const bin = typeof args.bin === "string" ? args.bin : findWorkbuddyExe();
  const restart = args["no-restart"] !== true;
  const live = safeParse(fs.readFileSync(file, "utf8"));
  if (!live) throw new Error("登录态文件不是合法 JSON");
  const accounts = await loadAccounts(resolveHubDb(typeof args.hub === "string" ? args.hub : undefined), "workbuddy");
  const key = bin ? readProtectorKey(bin) : null;

  if (command === "list") {
    printList(file, live, accounts, key, bin);
    return 0;
  }
  if (command === "dump") {
    dump(file, key);
    return 0;
  }
  if (command === "restore") {
    await restore({ file, bin, spec: args._[1], restart });
    return 0;
  }
  if (command === "switch") {
    if (!key) throw new Error("未找到 WorkBuddy 主程序，无法加密写入（可用 --bin 指定）");
    if (!accounts.length) throw new Error("账号库中没有 WorkBuddy 账号，请先添加并登录");
    const target = resolveTarget(accounts, args.to);
    if (!target.parsed?.account?.uid || !target.parsed?.auth?.accessToken) {
      throw new Error("账号库中的该账号缺少令牌，请重新登录");
    }
    if (target.externalId === live.account?.uid) {
      console.log(`客户端当前已是 ${target.externalId}，无需切换。`);
      return 5;
    }
    console.log(`切换到：${target.externalId}  ${target.displayName}`);
    await switchAccount({ file, live, target, key, bin, restart });
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
