import { DatabaseSync } from "node:sqlite";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";

export function defaultDatabasePath() {
  return process.env.WORKBUDDY_CHECKIN_DB
    || path.join(process.cwd(), "workbuddy-checkin.sqlite");
}

export function openDatabase(databasePath = defaultDatabasePath()) {
  mkdirSync(path.dirname(databasePath), { recursive: true });
  const db = new DatabaseSync(databasePath);
  db.exec(`
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS sessions (
      uid TEXT PRIMARY KEY,
      access_token TEXT NOT NULL,
      refresh_token TEXT,
      expires_at INTEGER,
      auth_json TEXT,
      domain TEXT,
      enterprise_id TEXT,
      nickname TEXT,
      updated_at TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1
    );
    CREATE TABLE IF NOT EXISTS device_tokens (
      uid TEXT PRIMARY KEY,
      token TEXT,
      error TEXT,
      fetched_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS checkin_logs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uid TEXT NOT NULL,
      action TEXT NOT NULL,
      status TEXT NOT NULL,
      http_status INTEGER,
      business_code INTEGER,
      message TEXT,
      response_json TEXT,
      created_at TEXT NOT NULL
    );
  `);
  const sessionColumns = db.prepare("PRAGMA table_info(sessions)").all().map((row) => row.name);
  for (const [column, type] of [
    ["refresh_token", "TEXT"],
    ["expires_at", "INTEGER"],
    ["auth_json", "TEXT"],
  ]) {
    if (!sessionColumns.includes(column)) {
      db.exec(`ALTER TABLE sessions ADD COLUMN ${column} ${type}`);
    }
  }
  try {
    chmodSync(databasePath, 0o600);
  } catch {}
  return db;
}

export function saveSession(db, session) {
  const required = ["uid", "accessToken"];
  for (const field of required) {
    if (!session[field]) {
      throw new Error(`登录态缺少 ${field}`);
    }
  }
  const now = new Date().toISOString();
  db.prepare(`
    INSERT INTO sessions (uid, access_token, refresh_token, expires_at, auth_json, domain, enterprise_id, nickname, updated_at, active)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
    ON CONFLICT(uid) DO UPDATE SET
      access_token = excluded.access_token,
      refresh_token = excluded.refresh_token,
      expires_at = excluded.expires_at,
      auth_json = excluded.auth_json,
      domain = excluded.domain,
      enterprise_id = excluded.enterprise_id,
      nickname = excluded.nickname,
      updated_at = excluded.updated_at,
      active = 1
  `).run(
    session.uid,
    session.accessToken,
    session.refreshToken ?? null,
    session.expiresAt ?? null,
    session.auth ? JSON.stringify(session.auth) : null,
    session.domain ?? null,
    session.enterpriseId ?? null,
    session.nickname ?? null,
    now,
  );
  return { uid: session.uid, updatedAt: now };
}

export function getSession(db, uid) {
  const row = uid
    ? db.prepare("SELECT * FROM sessions WHERE uid = ? AND active = 1").get(uid)
    : db.prepare("SELECT * FROM sessions WHERE active = 1 ORDER BY updated_at DESC LIMIT 1").get();
  if (!row) return undefined;
  return {
    uid: row.uid,
    accessToken: row.access_token,
    refreshToken: row.refresh_token ?? undefined,
    expiresAt: row.expires_at ?? undefined,
    auth: row.auth_json ? JSON.parse(row.auth_json) : undefined,
    domain: row.domain ?? undefined,
    enterpriseId: row.enterprise_id ?? undefined,
    nickname: row.nickname ?? undefined,
    updatedAt: row.updated_at,
  };
}

export function saveDeviceToken(db, uid, { token, error } = {}) {
  if (!token && !error) throw new Error("device token 和错误信息都为空");
  db.prepare(`
    INSERT INTO device_tokens (uid, token, error, fetched_at)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(uid) DO UPDATE SET
      token = excluded.token,
      error = excluded.error,
      fetched_at = excluded.fetched_at
  `).run(uid, token ?? null, error ?? null, new Date().toISOString());
}

export function saveCheckinLog(db, uid, action, record) {
  db.prepare(`
    INSERT INTO checkin_logs (uid, action, status, http_status, business_code, message, response_json, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    uid,
    action,
    record.status,
    record.httpStatus ?? null,
    record.businessCode ?? null,
    record.message ?? null,
    record.response ? JSON.stringify(record.response) : null,
    new Date().toISOString(),
  );
}
