#!/usr/bin/env node
import { buildAuthHeaders, requestJson, checkinResultName } from "./http.mjs";
import {
  defaultDatabasePath,
  openDatabase,
  getSession,
  saveCheckinLog,
  saveDeviceToken,
} from "./store.mjs";
import { fetchDeviceTokenWithOfficialSdk, resolveSdkDir } from "./turing-sdk.mjs";

const DEFAULT_ENDPOINT = "https://www.workbuddy.cn";

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

function appendDeviceHeaders(headers, tokenResult) {
  if (tokenResult?.token) headers["X-Device-Token"] = tokenResult.token;
  if (tokenResult?.error) headers["X-Device-Token-Error"] = tokenResult.error;
  return headers;
}

async function getOfficialTokenResult(args) {
  if (args["skip-device-token"]) return { token: undefined, error: "skipped" };
  try {
    const sdkDir = resolveSdkDir(args.sdk);
    const token = await fetchDeviceTokenWithOfficialSdk(sdkDir, {
      timeoutMs: Number(args["token-timeout-ms"] || 15000),
    });
    return { token, error: undefined };
  } catch (error) {
    return {
      token: undefined,
      error: String(error?.message || error).replace(/[^\x20-\x7e]/g, "").slice(0, 64),
      thrown: error,
    };
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args._[0] === "help" || args.help) {
    console.log(`用法：
  node checkin.mjs --sdk "C:\\...\\app.asar.unpacked\\native\\turing-sdk" \\
    [--db FILE] [--uid UID] [--endpoint URL] [--dry-run] [--skip-device-token]
`);
    return;
  }

  const endpoint = args.endpoint || DEFAULT_ENDPOINT;
  const db = openDatabase(args.db || defaultDatabasePath());
  const session = getSession(db, args.uid);
  if (!session) throw new Error("SQLite 中没有可用登录态，请先运行 login.mjs import-session");

  const tokenResult = await getOfficialTokenResult(args);
  if (args.uid && args.uid !== session.uid) {
    throw new Error(`指定的 uid=${args.uid} 与 SQLite 会话 uid=${session.uid} 不一致`);
  }
  if (tokenResult.token || tokenResult.error) {
    saveDeviceToken(db, session.uid, tokenResult);
  }
  console.log(`device token: ${tokenResult.token ? "ready" : `error=${tokenResult.error}`}`);

  const headers = appendDeviceHeaders(buildAuthHeaders(session), tokenResult);
  if (args["dry-run"]) {
    console.log(JSON.stringify({ endpoint, uid: session.uid, deviceTokenReady: Boolean(tokenResult.token) }, null, 2));
    return;
  }

  const statusResult = await requestJson(`${endpoint}/v2/billing/meter/checkin-activity-status`, {
    method: "POST",
    headers,
    body: JSON.stringify({}),
  });
  saveCheckinLog(db, session.uid, "activity-status", {
    status: statusResult.ok ? "http_ok" : "http_error",
    ...statusResult,
  });
  console.log("activity status:", JSON.stringify(statusResult, null, 2));
  if (!statusResult.ok) process.exitCode = 1;

  const activity = statusResult.body?.data;
  if (statusResult.body?.code !== 0 || !activity) {
    saveCheckinLog(db, session.uid, "daily-checkin", {
      status: "skipped",
      httpStatus: statusResult.status,
      businessCode: statusResult.body?.code,
      message: statusResult.body?.msg,
    });
    return;
  }
  if (activity.today_checked_in) {
    saveCheckinLog(db, session.uid, "daily-checkin", {
      status: "already_claimed",
      httpStatus: statusResult.status,
      businessCode: statusResult.body?.code,
    });
    console.log("今日已签到，跳过 daily-checkin。");
    return;
  }

  const checkinResult = await requestJson(`${endpoint}/v2/billing/meter/daily-checkin`, {
    method: "POST",
    headers,
    body: JSON.stringify({}),
  });
  const businessCode = checkinResult.body?.code;
  saveCheckinLog(db, session.uid, "daily-checkin", {
    status: checkinResult.ok ? checkinResultName(businessCode) : "http_error",
    ...checkinResult,
  });
  console.log("daily checkin:", JSON.stringify(checkinResult, null, 2));
  if (!checkinResult.ok || (businessCode !== undefined && businessCode !== 0 && businessCode !== 1001)) {
    process.exitCode = 1;
  }
}

await main().catch((error) => {
  console.error(`错误：${error?.stack || error?.message || error}`);
  process.exitCode = 1;
});
