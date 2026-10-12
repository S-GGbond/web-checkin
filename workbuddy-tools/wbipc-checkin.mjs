#!/usr/bin/env node
// -*- coding: utf-8 -*-
/**
 * WorkBuddy 每日签到（WBIPC 宿主通道版，纯 Node 标准库，无第三方依赖）
 *
 * 背景：WorkBuddy 桌面端 5.3.8+ 将本地登录态改为加密信封，旧式「读明文 token
 * 直连接口」的脚本会失效。本脚本改走客户端宿主通道（WBIPC）：只提交
 * method + path，鉴权头由 WorkBuddy 客户端注入，进程内不接触 accessToken。
 *
 * 协议实现与官方 workbuddy_ipc Python 模块（vendor 副本）逐字节对齐：
 *   1. 发现：读 {WORKBUDDY_CONFIG_DIR|~/.workbuddy}/wbipc/endpoint.json
 *      （0600 文件，含 endpoint 与 ticket）
 *   2. 连接 endpoint（unix socket），双向 HMAC-SHA256 握手（服务端先自证）
 *   3. broker/GetPipe 取 wb.request 管道，invoke http.fetch
 *   4. 查询签到状态 → 未签则领取（幂等）→ 复核
 *
 * 用法：
 *   node checkin.mjs                 # 查询 + 必要时领取（推荐）
 *   node checkin.mjs --check-only    # 仅查询，不领取
 *   node checkin.mjs --diagnose      # 环境自检
 *   node checkin.mjs --version
 *
 * 退出码：0 = 成功或今日已签；1 = 失败；2 = 环境不满足（endpoint 缺失等）
 */

import net from "node:net";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const VERSION = "3.2.0-cross-platform";
const PROTOCOL_VERSION = 1;
const MAX_FRAME_BYTES = 1024 * 1024;
const HANDSHAKE_TIMEOUT_S = 5.0;
const CALL_TIMEOUT_S = 60.0;

// 接口路径：主路径优先，失败依次降级
const STATUS_PATHS = [
  "/v2/billing/meter/checkin-activity-status",
  "/v2/billing/meter/checkin-status",
  "/v1/billing/meter/checkin-activity-status",
];
const CHECKIN_PATHS = [
  "/v2/billing/meter/daily-checkin",
  "/v2/billing/meter/checkin",
  "/v1/billing/meter/daily-checkin",
];

// ---------------- 工具 ----------------

function b64url(buf) {
  return Buffer.from(buf).toString("base64url");
}

function ticketId(ticket) {
  return crypto.createHash("sha256").update(ticket, "utf8").digest("hex").slice(0, 16);
}

function encodeTranscript(role, protocol, endpoint, clientNonce, serverNonce) {
  const domain = role === "server" ? "wbipc-s" : "wbipc-c";
  const parts = [domain, String(protocol), endpoint, clientNonce, serverNonce];
  const chunks = [];
  for (const part of parts) {
    const buf = Buffer.from(part, "utf8");
    const len = Buffer.alloc(4);
    len.writeUInt32BE(buf.length, 0);
    chunks.push(len, buf);
  }
  return Buffer.concat(chunks);
}

function proof(ticket, role, protocol, endpoint, clientNonce, serverNonce) {
  const mac = crypto.createHmac("sha256", Buffer.from(ticket, "utf8"))
    .update(encodeTranscript(role, protocol, endpoint, clientNonce, serverNonce))
    .digest();
  return b64url(mac);
}

function maskToken(t) {
  return (t && t.length > 10) ? t.slice(0, 6) + "..." + t.slice(-4) : "<empty>";
}

// ---------------- 发现与连接 ----------------

function configDir() {
  return (process.env.WORKBUDDY_CONFIG_DIR || "").trim() ||
    path.join(os.homedir(), ".workbuddy");
}

function discoveryPath() {
  return path.join(configDir(), "wbipc", "endpoint.json");
}

function loadDiscovery() {
  // 环境变量优先（便于测试/手动指定）
  const envEndpoint = (process.env.WBIPC_ENDPOINT || "").trim();
  const envTicket = (process.env.WBIPC_TICKET || "").trim();
  if (envEndpoint && envTicket) {
    return { endpoint: envEndpoint, ticket: envTicket, source: "env" };
  }
  const p = discoveryPath();
  let raw;
  try {
    raw = fs.readFileSync(p, "utf8");
  } catch {
    const err = new Error(
      `未找到 WBIPC 端点发现文件 ${p}（不在 WorkBuddy 环境中或客户端未运行）`);
    err.code = "E_NOT_WORKBUDDY";
    throw err;
  }
  let found;
  try {
    found = JSON.parse(raw);
  } catch (e) {
    const err = new Error(`发现文件格式错误 ${p}: ${e.message}`);
    err.code = "E_TICKET_INVALID";
    throw err;
  }
  const endpoint = (found.endpoint || "").trim();
  const ticket = (found.ticket || "").trim();
  if (!endpoint || !ticket) {
    const err = new Error(`发现文件缺少 endpoint/ticket: ${p}`);
    err.code = "E_TICKET_INVALID";
    throw err;
  }
  return { endpoint, ticket, source: p };
}

function socketPathOf(endpoint) {
  if (endpoint.startsWith("unix:")) return endpoint.slice("unix:".length);
  if (endpoint.startsWith("pipe:")) return `\\\\.\\pipe\\${endpoint.slice("pipe:".length)}`;
  return endpoint;
}

function socketOptionsOf(endpoint) {
  if (endpoint.startsWith("tcp:")) {
    const url = new URL(endpoint);
    return { host: url.hostname, port: Number(url.port || 443) };
  }
  return { path: socketPathOf(endpoint) };
}

class WbipcClient {
  constructor(sock, endpoint, pipes, connectionEpoch, initialBuffer) {
    this._sock = sock;
    this._endpoint = endpoint;
    this.pipes = pipes || [];
    this.connectionEpoch = connectionEpoch || "";
    this._nextId = 1;
    this._pending = new Map();
    this._closed = false;
    this._buffer = initialBuffer || Buffer.alloc(0);
    sock.on("data", (chunk) => this._onData(chunk));
    sock.on("error", () => this._failAll(new Error("E_REVOKED: socket error")));
    sock.on("close", () => this._failAll(new Error("E_REVOKED: connection closed by host")));
  }

  _onData(chunk) {
    this._buffer = Buffer.concat([this._buffer, chunk]);
    for (;;) {
      const nl = this._buffer.indexOf(0x0a);
      if (nl < 0) {
        if (this._buffer.length > MAX_FRAME_BYTES) {
          this._failAll(new Error("E_PROTOCOL_MISMATCH: frame exceeds limit"));
          return;
        }
        return;
      }
      const line = this._buffer.subarray(0, nl).toString("utf8");
      this._buffer = this._buffer.subarray(nl + 1);
      if (!line) continue;
      let frame;
      try {
        frame = JSON.parse(line);
      } catch {
        this._failAll(new Error("E_PROTOCOL_MISMATCH: malformed json frame"));
        return;
      }
      this._onFrame(frame);
    }
  }

  _onFrame(frame) {
    const id = frame.id;
    if (id == null) return;
    const entry = this._pending.get(id);
    if (!entry) return;
    clearTimeout(entry.timer);
    this._pending.delete(id);
    if (frame.error) entry.reject(new Error(`${frame.error.code || "E_INTERNAL"}: ${frame.error.message || "request failed"}`));
    else entry.resolve(frame.result);
  }

  _failAll(err) {
    if (this._closed) return;
    this._closed = true;
    for (const [, entry] of this._pending) {
      clearTimeout(entry.timer);
      entry.reject(err);
    }
    this._pending.clear();
    try { this._sock.destroy(); } catch { /* ignore */ }
  }

  request(method, params, { mode = null, timeoutS = CALL_TIMEOUT_S } = {}) {
    if (this._closed) return Promise.reject(new Error("E_REVOKED: connection closed"));
    const id = this._nextId++;
    const frame = { jsonrpc: "2.0", id, method, params: params || {} };
    if (mode !== null) frame.mode = mode;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        // 尽力补发取消
        try {
          this._sock.write(JSON.stringify({
            jsonrpc: "2.0", method: "$/cancel", params: { id },
          }) + "\n");
        } catch { /* ignore */ }
        reject(new Error(`E_TIMEOUT: wbipc request timed out after ${timeoutS}s: ${method}`));
      }, timeoutS * 1000);
      this._pending.set(id, { resolve, reject, timer });
      try {
        const payload = JSON.stringify(frame) + "\n";
        if (Buffer.byteLength(payload) > MAX_FRAME_BYTES) {
          throw new Error("E_BAD_REQUEST: request frame exceeds 1MB");
        }
        this._sock.write(payload);
      } catch (e) {
        clearTimeout(timer);
        this._pending.delete(id);
        reject(new Error("E_REVOKED: wbipc write failed: " + e.message));
      }
    });
  }

  async listPipes() {
    const r = await this.request("broker/ListPipes", {});
    return (r && r.pipes) || [];
  }

  async getPipe(name) {
    const r = await this.request("broker/GetPipe", { pipe: name });
    if (!r || !r.channel) throw new Error("E_INTERNAL: GetPipe returned no channel");
    return { name, channel: r.channel, methods: r.methods || [] };
  }

  close() {
    this._failAll(new Error("E_REVOKED: connection closed"));
  }
}

function connectWbipc(endpoint, ticket) {
  return new Promise((resolve, reject) => {
    const sock = net.connect(socketOptionsOf(endpoint));
    sock.setTimeout(HANDSHAKE_TIMEOUT_S * 1000);
    let stage = "connect";
    let buffer = Buffer.alloc(0);

    const fail = (err) => {
      try { sock.destroy(); } catch { /* ignore */ }
      reject(err);
    };

    const readFrame = () => new Promise((res, rej) => {
      const grab = () => {
        const nl = buffer.indexOf(0x0a);
        if (nl < 0) return false;
        const line = buffer.subarray(0, nl).toString("utf8");
        buffer = buffer.subarray(nl + 1);
        try { res(JSON.parse(line)); } catch (e) { rej(e); }
        return true;
      };
      if (grab()) return;
      const onData = (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        if (grab()) {
          sock.removeListener("data", onData);
          sock.removeListener("close", onClose);
        }
      };
      const onClose = () => {
        sock.removeListener("data", onData);
        rej(new Error("E_ENDPOINT_UNTRUSTED: wbipc endpoint closed during handshake"));
      };
      sock.on("data", onData);
      sock.on("close", onClose);
    });

    sock.on("timeout", () => fail(new Error("E_ENDPOINT_UNTRUSTED: wbipc handshake timed out")));
    sock.on("error", (e) => {
      const err = new Error(
        stage === "connect"
          ? `E_NOT_WORKBUDDY: wbipc endpoint is not accepting connections (${e.message})`
          : `E_ENDPOINT_UNTRUSTED: ${e.message}`);
      fail(err);
    });

    sock.on("connect", async () => {
      try {
        stage = "hello";
        const clientNonce = b64url(crypto.randomBytes(16));
        const hello = {
          type: "session_hello",
          protocol_min: PROTOCOL_VERSION,
          protocol_max: PROTOCOL_VERSION,
          client_nonce: clientNonce,
          ticket_id: ticketId(ticket),
          client: { kind: "skill", id: "workbuddy-daily-checkin-fixed" },
        };
        sock.write(JSON.stringify(hello) + "\n");

        stage = "challenge";
        const challenge = await readFrame();
        if (challenge.type === "session_hello_error") {
          throw new Error("E_TICKET_INVALID: wbipc handshake rejected: " +
            (challenge.code || "rejected"));
        }
        if (challenge.type !== "session_challenge") {
          throw new Error("E_ENDPOINT_UNTRUSTED: unexpected handshake frame: " + challenge.type);
        }
        const serverNonce = challenge.server_nonce || "";
        const expected = proof(ticket, "server", PROTOCOL_VERSION, endpoint,
          clientNonce, serverNonce);
        const provided = challenge.server_proof || "";
        if (!serverNonce || expected.length !== provided.length ||
            !crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(provided))) {
          throw new Error("E_ENDPOINT_UNTRUSTED: wbipc endpoint failed to prove ticket possession");
        }

        stage = "prove";
        sock.write(JSON.stringify({
          type: "session_prove",
          client_proof: proof(ticket, "client", PROTOCOL_VERSION, endpoint,
            clientNonce, serverNonce),
        }) + "\n");

        const ack = await readFrame();
        if (ack.type !== "session_hello_ack") {
          throw new Error("E_TICKET_INVALID: wbipc handshake rejected: " +
            (ack.code || "rejected"));
        }
        sock.setTimeout(0);
        // 残留 buffer 交给客户端读循环
        const client = new WbipcClient(sock, endpoint, ack.pipes,
          ack.connection_epoch, buffer);
        resolve(client);
      } catch (e) {
        fail(e);
      }
    });
  });
}

// ---------------- 签到主流程 ----------------

function pickData(body) {
  if (!body || typeof body !== "object") return {};
  const d = body.data;
  return (d && typeof d === "object" && !Array.isArray(d)) ? d : body;
}

function extractBalance(body) {
  const keys = ["total_credits", "total_credit", "credit_balance", "balance",
    "credits", "available_credits", "remain_credits", "points"];
  const sources = [pickData(body), body || {}];
  for (const src of sources) {
    for (const k of keys) {
      const v = src[k];
      if (typeof v === "number") return v;
    }
  }
  return null;
}

function isSigned(data, body) {
  if (data && data.today_checked_in === true) return true;
  if (body && typeof body === "object") {
    if (body.today_checked_in === true) return true;
    if (["10001", "10002"].includes(String(body.code))) return true;
  }
  return false;
}

function errMsg(body, httpCode) {
  if (body && typeof body === "object") {
    for (const k of ["msg", "message", "error"]) {
      if (body[k]) return String(body[k]);
    }
  }
  return `HTTP ${httpCode}（无业务错误信息）`;
}

async function fetchJson(pipe, method, urlPath, bodyObj) {
  const params = { method: method.toUpperCase(), path: urlPath };
  if (bodyObj !== undefined) {
    params.headers = { "Content-Type": "application/json" };
    params.body_b64 = Buffer.from(JSON.stringify(bodyObj), "utf8").toString("base64");
  }
  const resp = await pipe.invokeHttp(params);
  const status = parseInt(resp && resp.status, 10) || 0;
  let parsed = {};
  try {
    const raw = Buffer.from((resp && resp.body_b64) || "", "base64").toString("utf8");
    parsed = JSON.parse(raw);
  } catch { /* keep {} */ }
  return [status, parsed];
}

// 给 pipe 挂一个便捷方法（invoke http.fetch）
function withHttpFetch(pipe, client) {
  pipe.invokeHttp = (params) =>
    client.request(`${pipe.channel}/http.fetch`, params, { mode: "call" });
  return pipe;
}

async function queryStatus(client, pipe, result) {
  let last = null;
  for (const p of STATUS_PATHS) {
    const [code, body] = await fetchJson(pipe, "POST", p, {});
    const data = pickData(body);
    const okShape = ["today_checked_in", "checkin_dates", "streak_days",
      "total_credits", "activity_name"].some((k) => k in data);
    if (code >= 200 && code < 300 && okShape) {
      result.detail.status_path = p;
      result.detail.status_http = code;
      return [data, body];
    }
    last = `HTTP ${code}`;
  }
  throw new Error(`状态查询失败（已尝试 ${STATUS_PATHS.length} 个路径）: ${last}`);
}

async function runCheckin({ checkOnly }) {
  const result = {
    status: "unknown", action: null, points: null, balance: null,
    streak_days: null, msg: "", detail: {},
  };

  let disc;
  try {
    disc = loadDiscovery();
    result.detail.endpoint = disc.endpoint;
    result.detail.ticket_masked = maskToken(disc.ticket);
  } catch (e) {
    result.status = "error";
    result.msg = e.message;
    result.detail.exit_code = e.code === "E_NOT_WORKBUDDY" ? 2 : 1;
    return result;
  }

  let client;
  try {
    client = await connectWbipc(disc.endpoint, disc.ticket);
    result.detail.pipes = client.pipes;
    const pipe = withHttpFetch(await client.getPipe("wb.request"), client);
    result.detail.pipe_methods = pipe.methods;

    // 1. 查询状态
    const [data, body] = await queryStatus(client, pipe, result);
    result.balance = extractBalance(body);
    result.streak_days = data.streak_days ?? null;
    result.detail.total_credits = data.total_credits ?? null;
    result.detail.activity = data.activity_name ?? null;
    result.detail.season = data.season ?? null;

    if (data.active === false) {
      result.status = "error";
      result.action = "inactive";
      result.msg = "签到活动当前未开启（active=false），无需领取";
      return result;
    }

    const signed = isSigned(data, body);
    result.detail.today_checked_in = signed;

    if (checkOnly) {
      result.status = "ok";
      result.action = "skip_check_only";
      result.msg = `状态查询成功（未执行领取），今日${signed ? "已签" : "未签"}`;
      return result;
    }

    if (signed) {
      result.status = "ok";
      result.action = "skip_already_signed";
      result.msg = "今日已签到，无需重复领取";
      return result;
    }

    // 2. 领取（主备路径降级）
    let ok = false;
    let cmsg = "";
    let already = false;
    for (const p of CHECKIN_PATHS) {
      const [ccode, cbody] = await fetchJson(pipe, "POST", p, {});
      result.detail.checkin_path = p;
      result.detail.checkin_http = ccode;
      result.detail.checkin_resp = cbody;
      const bcode = cbody && typeof cbody === "object" ? String(cbody.code ?? "") : "";
      cmsg = errMsg(cbody, ccode);
      if (bcode === "10001" || (cmsg || "").includes("已签到")) {
        ok = true;
        already = true;
        cmsg = "今日已签到（接口幂等保护）";
        break;
      }
      if (ccode >= 200 && ccode < 300 && ["", "0", "200"].includes(bcode)) {
        ok = true;
        cmsg = cmsg || "领取成功";
        break;
      }
      if (ccode === 404 && p !== CHECKIN_PATHS[CHECKIN_PATHS.length - 1]) continue;
      ok = false;
      break;
    }

    // 3. 复核：领取后再查一次状态，防「假成功」
    let verified = null;
    try {
      const [vdata, vbody] = await queryStatus(client, pipe, result);
      verified = isSigned(vdata, vbody);
      result.detail.verified = verified;
      const bal = extractBalance(vbody);
      if (bal !== null) result.balance = bal;
      if (vdata.streak_days != null) result.streak_days = vdata.streak_days;
      result.detail.total_credits = vdata.total_credits ?? result.detail.total_credits;
    } catch (e) {
      result.detail.verify_error = e.message;
    }

    if (verified === false && !already) {
      result.status = "error";
      result.action = "verify_failed";
      result.msg = `领取接口返回成功，但复核发现今日仍未签到：${cmsg}`;
      return result;
    }

    if (ok || verified) {
      const credit = data.daily_credit ?? data.today_credit ?? null;
      const balTxt = result.balance != null ? `，当前积分余额 ${result.balance}` : "";
      result.status = "ok";
      result.action = already ? "skip_already_signed" : "clicked";
      result.points = credit;
      result.msg = (cmsg || "领取成功")
        + (credit ? `，+${credit} 积分` : "")
        + (result.streak_days ? `，连续第 ${result.streak_days} 天` : "")
        + balTxt;
      return result;
    }

    result.status = "error";
    result.action = "failed";
    result.msg = cmsg || "领取失败";
    return result;
  } catch (e) {
    result.status = "error";
    result.msg = `宿主通道调用异常: ${e.message}`;
    return result;
  } finally {
    if (client) client.close();
  }
}

// ---------------- 自检 ----------------

async function diagnose() {
  const rep = { version: VERSION, node: process.version, config_dir: configDir() };
  const p = discoveryPath();
  rep.discovery_path = p;
  rep.discovery_exists = fs.existsSync(p);
  try {
    const disc = loadDiscovery();
    rep.endpoint = disc.endpoint;
    rep.source = disc.source;
    const client = await connectWbipc(disc.endpoint, disc.ticket);
    rep.pipes = await client.listPipes();
    const pipe = withHttpFetch(await client.getPipe("wb.request"), client);
    rep.pipe_methods = pipe.methods;
    const [code, body] = await fetchJson(pipe, "POST", STATUS_PATHS[0], {});
    rep.status_http = code;
    rep.today_checked_in = pickData(body).today_checked_in ?? null;
    rep.total_credits = pickData(body).total_credits ?? null;
    client.close();
  } catch (e) {
    rep.error = `${e.code || e.name || "Error"}: ${e.message}`;
  }
  return rep;
}

// ---------------- 日志与入口 ----------------

function writeLog(res) {
  try {
    const scriptDir = path.dirname(fileURLToPath(import.meta.url));
    const logDir = path.join(scriptDir, "logs");
    fs.mkdirSync(logDir, { recursive: true });
    const line = `${new Date().toLocaleString("sv-SE").replace("T", " ")} | status=${res.status} | action=${res.action} | streak=${res.streak_days} | balance=${res.balance} | msg=${res.msg}\n`;
    fs.appendFileSync(path.join(logDir, "checkin.log"), line, "utf8");
  } catch { /* 日志失败不影响结果 */ }
}

function usage() {
  return `WorkBuddy 每日签到助手（WBIPC 宿主通道版）v${VERSION}

用法：
  node wbipc-checkin.mjs                 # 查询 + 必要时领取（推荐）
  node wbipc-checkin.mjs --check-only    # 仅查询，不领取
  node wbipc-checkin.mjs --diagnose      # 环境自检
  node wbipc-checkin.mjs --version

退出码：0 = 成功或今日已签；1 = 失败；2 = 环境不满足（如 endpoint 缺失）`;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(usage());
    process.exit(0);
  }
  if (argv.includes("--version")) {
    console.log(`workbuddy-checkin-wbipc ${VERSION}`);
    process.exit(0);
  }
  if (argv.includes("--diagnose")) {
    console.log(JSON.stringify(await diagnose(), null, 2));
    process.exit(0);
  }
  const res = await runCheckin({ checkOnly: argv.includes("--check-only") });
  console.log(JSON.stringify(res, null, 2));
  writeLog(res);
  process.exit(res.status === "ok" ? 0 : (res.detail.exit_code || 1));
}

main().catch((e) => {
  console.log(JSON.stringify({
    status: "error", action: null, points: null, balance: null,
    streak_days: null, msg: `脚本未捕获异常: ${e.message}`, detail: {},
  }, null, 2));
  process.exit(1);
});
