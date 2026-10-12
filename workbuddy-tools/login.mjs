#!/usr/bin/env node
import { createInterface } from "node:readline/promises";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { fetchDeviceTokenWithOfficialSdk, resolveSdkDir } from "./turing-sdk.mjs";
import { buildAuthHeaders, requestJson } from "./http.mjs";
import { defaultDatabasePath, openDatabase, getSession, saveSession } from "./store.mjs";

const DEFAULT_ENDPOINT = "https://www.workbuddy.cn";
const LOGIN_POLL_INTERVAL_MS = 1000;
const LOGIN_TIMEOUT_MS = 300000;

function parseArgs(argv) {
  const args = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!item.startsWith("--")) {
      args._.push(item);
      continue;
    }
    const key = item.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) args[key] = true;
    else {
      args[key] = next;
      index += 1;
    }
  }
  return args;
}

function normalizeSession(value) {
  const source = value?.data ?? value;
  const auth = source?.auth ?? {};
  const session = {
    uid: source?.account?.uid,
    accessToken: auth.accessToken,
    refreshToken: auth.refreshToken,
    expiresAt: auth.expiresAt,
    auth,
    domain: auth.domain,
    enterpriseId: source?.account?.enterpriseId,
    nickname: source?.account?.nickname,
  };
  if (!session.uid || !session.accessToken) {
    throw new Error("导入文件必须是解密后的 WorkBuddy session JSON，且包含 auth.accessToken 与 account.uid");
  }
  return session;
}

function endpointDomain(endpoint) {
  return new URL(endpoint).host;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isPending(body, code) {
  return body?.code === code || body?.response?.code === code;
}

function hasUsableAuthToken(value) {
  return Boolean(value && typeof value === "object" && typeof value.accessToken === "string" && value.accessToken);
}

function openBrowser(url) {
  if (process.platform === "win32") {
    spawn("explorer.exe", [url], { detached: true, stdio: "ignore" }).unref();
    return;
  }
  if (process.platform === "darwin") {
    spawn("open", [url], { detached: true, stdio: "ignore" }).unref();
    return;
  }
  spawn("xdg-open", [url], { detached: true, stdio: "ignore" }).unref();
}

async function importSession(args) {
  let value;
  if (args["auth-json"]) {
    value = JSON.parse(readFileSync(args["auth-json"], "utf8"));
  } else {
    const readline = createInterface({ input: process.stdin, output: process.stdout });
    const accessToken = await readline.question("accessToken: ");
    const uid = await readline.question("uid: ");
    const domain = await readline.question("auth.domain（可空）: ");
    const enterpriseId = await readline.question("enterpriseId（可空）: ");
    const nickname = await readline.question("nickname（可空）: ");
    readline.close();
    value = {
      auth: { accessToken, domain: domain || undefined },
      account: {
        uid,
        enterpriseId: enterpriseId || undefined,
        nickname: nickname || undefined,
      },
    };
  }
  const session = normalizeSession(value);
  const db = openDatabase(args.db || defaultDatabasePath());
  saveSession(db, session);
  console.log(`已保存登录态 uid=${session.uid}`);
}

async function deviceCode(args) {
  const endpoint = args.endpoint || DEFAULT_ENDPOINT;
  const result = await requestJson(`${endpoint}/v2/plugin/device/auth/code`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({}),
  });
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) process.exitCode = 1;
  const data = result.body?.data ?? result.body;
  const code = data?.deviceCode;
  if (code) {
    const loginUrl = new URL("/console/client-login", endpoint);
    loginUrl.searchParams.set("code", code);
    loginUrl.searchParams.set("target", args.target || "/");
    console.log(`\n在浏览器打开：\n${loginUrl}\n`);
    console.log("浏览器完成授权后，请从官方程序导出/诊断出的 session JSON，用 import-session 导入。");
  }
}

async function browserLogin(args) {
  const endpoint = args.endpoint || DEFAULT_ENDPOINT;
  const domain = endpointDomain(endpoint);
  const noAuthHeaders = {
    "X-Domain": domain,
    "X-Custom-Channel-Id": "unknown",
    "X-No-Authorization": "true",
    "X-No-User-Id": "true",
    "X-No-Enterprise-Id": "true",
    "X-No-Department-Info": "true",
  };

  if (!args["skip-device-token"]) {
    const sdkDir = resolveSdkDir(args.sdk);
    const token = await fetchDeviceTokenWithOfficialSdk(sdkDir, {
      timeoutMs: Number(args["token-timeout-ms"] || 15000),
    });
    noAuthHeaders["X-Device-Token"] = token;
    console.log("官方 device token 已就绪。");
  }

  const stateResponse = await requestJson(`${endpoint}/v2/plugin/auth/state?platform=workbuddy`, {
    method: "POST",
    headers: noAuthHeaders,
    body: JSON.stringify({}),
  });
  console.log("auth state:", JSON.stringify(stateResponse, null, 2));
  if (!stateResponse.ok) throw new Error(`请求登录 state 失败：HTTP ${stateResponse.status}`);
  const authState = stateResponse.body?.data;
  if (!authState?.authUrl || !authState?.state) throw new Error("登录响应缺少 authUrl/state");

  const authUrl = new URL(authState.authUrl, endpoint);
  const version = args.version || "5.7.7";
  authUrl.searchParams.set("version", version);
  if (args["no-open-browser"] !== true) openBrowser(authUrl.toString());
  console.log(`state=${authState.state}`);
  console.log(`在浏览器打开：${authUrl}`);

  const deadline = Date.now() + LOGIN_TIMEOUT_MS;
  let auth;
  while (Date.now() < deadline) {
    await sleep(LOGIN_POLL_INTERVAL_MS);
    const tokenResponse = await requestJson(`${endpoint}/v2/plugin/auth/token?state=${encodeURIComponent(authState.state)}`, {
      method: "GET",
      headers: noAuthHeaders,
    });
    if (hasUsableAuthToken(tokenResponse.body?.data)) {
      auth = { ...tokenResponse.body.data, lastRefreshTime: Date.now() };
      if (!auth.expiresAt && auth.expiresIn) auth.expiresAt = Date.now() + auth.expiresIn * 1000;
      break;
    }
    if (!isPending(tokenResponse.body, 11217)) {
      throw new Error(`登录 token 轮询失败：${JSON.stringify(tokenResponse.body)}`);
    }
  }
  if (!auth) throw new Error(`登录 token 轮询超时（${LOGIN_TIMEOUT_MS}ms）`);

  let account;
  while (Date.now() < deadline) {
    await sleep(LOGIN_POLL_INTERVAL_MS);
    const accountResponse = await requestJson(`${endpoint}/v2/plugin/login/account?state=${encodeURIComponent(authState.state)}`, {
      method: "GET",
      headers: {
        "X-Domain": auth.domain || domain,
        Authorization: `Bearer ${auth.accessToken}`,
        "X-No-User-Id": "true",
        "X-No-Enterprise-Id": "true",
        "X-No-Department-Info": "true",
      },
    });
    if (accountResponse.body?.data) {
      account = accountResponse.body.data;
      break;
    }
    if (!isPending(accountResponse.body, 12151)) {
      throw new Error(`登录账号轮询失败：${JSON.stringify(accountResponse.body)}`);
    }
  }
  if (!account) throw new Error("登录账号轮询超时");

  const session = normalizeSession({ auth, account });
  const db = openDatabase(args.db || defaultDatabasePath());
  saveSession(db, session);
  console.log(`登录成功，已保存 uid=${session.uid}`);
}

async function refreshSession(args) {
  const endpoint = args.endpoint || DEFAULT_ENDPOINT;
  const db = openDatabase(args.db || defaultDatabasePath());
  const session = getSession(db, args.uid);
  if (!session?.refreshToken) throw new Error("SQLite 会话缺少 refreshToken");
  const result = await requestJson(`${endpoint}/v2/plugin/auth/token/refresh`, {
    method: "POST",
    headers: {
      "X-Domain": session.domain || endpointDomain(endpoint),
      Authorization: `Bearer ${session.accessToken}`,
      "X-Refresh-Token": session.refreshToken,
      "X-Auth-Refresh-Source": "plugin",
    },
    body: JSON.stringify({}),
  });
  console.log(JSON.stringify(result, null, 2));
  const nextAuth = result.body?.data;
  if (!hasUsableAuthToken(nextAuth)) {
    process.exitCode = 1;
    return;
  }
  nextAuth.lastRefreshTime = Date.now();
  if (!nextAuth.expiresAt && nextAuth.expiresIn) nextAuth.expiresAt = Date.now() + nextAuth.expiresIn * 1000;
  saveSession(db, normalizeSession({
    auth: nextAuth,
    account: {
      uid: session.uid,
      enterpriseId: session.enterpriseId,
      nickname: session.nickname,
    },
  }));
}

async function verify(args) {
  const endpoint = args.endpoint || DEFAULT_ENDPOINT;
  const db = openDatabase(args.db || defaultDatabasePath());
  const session = getSession(db, args.uid);
  if (!session) throw new Error("SQLite 中没有可用登录态");
  const result = await requestJson(`${endpoint}/console/accounts`, {
    method: "GET",
    headers: buildAuthHeaders(session),
  });
  console.log(JSON.stringify(result, null, 2));
  if (!result.ok) process.exitCode = 1;
}

const args = parseArgs(process.argv.slice(2));
const command = args._[0] || "help";
try {
  if (command === "import-session") await importSession(args);
  else if (command === "browser-login") await browserLogin(args);
  else if (command === "refresh") await refreshSession(args);
  else if (command === "device-code") await deviceCode(args);
  else if (command === "verify") await verify(args);
  else {
    console.log(`用法：
  node login.mjs import-session [--db FILE] [--auth-json FILE]
  node login.mjs browser-login --sdk SDK_DIR [--db FILE] [--endpoint URL] [--no-open-browser]
  node login.mjs refresh [--uid UID] [--db FILE] [--endpoint URL]
  node login.mjs device-code [--endpoint URL] [--target PATH]
  node login.mjs verify [--uid UID] [--endpoint URL]
`);
  }
} catch (error) {
  console.error(`错误：${error?.stack || error?.message || error}`);
  process.exitCode = 1;
}
