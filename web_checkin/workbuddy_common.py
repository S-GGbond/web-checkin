"""WorkBuddy 登录态存储与 HTTP 调用的共享实现。"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable

from .paths import data_file


DEFAULT_ENDPOINT = "https://www.workbuddy.cn"
DEFAULT_DB = str(data_file("workbuddy-checkin.sqlite3"))
CLIENT_VERSION = "5.6.2"
USER_AGENT = f"WorkBuddy/{CLIENT_VERSION}"
AUTH_PREFIX = "/v2/plugin"
PENDING_TOKEN_CODE = 11217
PENDING_ACCOUNT_CODE = 12151
DEFAULT_HTTP_TIMEOUT = 20.0


class WorkBuddyError(RuntimeError):
    """工具级统一错误。"""


def now_ms() -> int:
    return int(time.time() * 1000)


def endpoint_origin(endpoint: str) -> str:
    endpoint = (endpoint or DEFAULT_ENDPOINT).rstrip("/")
    if "://" not in endpoint:
        endpoint = "https://" + endpoint
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise WorkBuddyError(f"无效 endpoint: {endpoint}")
    return f"{parsed.scheme}://{parsed.netloc}"


def base_headers(endpoint: str, account: dict[str, Any] | None = None) -> dict[str, str]:
    headers = {
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
        "X-IDE-Type": "WorkBuddy",
        "X-IDE-Name": "WorkBuddy",
        "X-IDE-Version": CLIENT_VERSION,
        "X-Product": "WorkBuddy",
        "X-Domain": (account or {}).get("domain") or urllib.parse.urlparse(endpoint_origin(endpoint)).hostname or "",
    }
    if not account or not account.get("uid"):
        headers.update(
            {
                "X-No-User-Id": "true",
                "X-No-Enterprise-Id": "true",
                "X-No-Department-Info": "true",
            }
        )
        return headers

    if account.get("uid"):
        headers["X-User-Id"] = str(account["uid"])
    enterprise_id = account.get("enterpriseId")
    if enterprise_id:
        headers["X-Enterprise-Id"] = str(enterprise_id)
        headers["X-Tenant-Id"] = str(enterprise_id)
    return headers


def request_json(
    endpoint: str,
    method: str,
    path: str,
    *,
    token: str | None = None,
    refresh_token: str | None = None,
    account: dict[str, Any] | None = None,
    body: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> tuple[int, dict[str, Any]]:
    """发送 JSON 请求；HTTP 错误也尽量解析成业务 envelope。"""
    url = endpoint_origin(endpoint) + path
    headers = base_headers(endpoint, account)
    raw_body = None
    if method.upper() == "POST":
        headers["Content-Type"] = "application/json"
        raw_body = json.dumps(body or {}, separators=(",", ":")).encode("utf-8")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    else:
        headers["X-No-Authorization"] = "true"
    if refresh_token:
        headers["X-Refresh-Token"] = refresh_token
        headers["X-Auth-Refresh-Source"] = "plugin"
    if extra_headers:
        headers.update(extra_headers)

    req = urllib.request.Request(url, data=raw_body, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            status = response.status
            payload = json.loads(response.read().decode("utf-8", "replace") or "{}")
    except urllib.error.HTTPError as exc:
        status = exc.code
        try:
            payload = json.loads(exc.read().decode("utf-8", "replace") or "{}")
        except Exception:
            payload = {"code": exc.code, "msg": str(exc.reason)}
    except Exception as exc:
        raise WorkBuddyError(f"请求失败: {method} {path}: {exc}") from exc

    if not isinstance(payload, dict):
        payload = {"code": -1, "msg": "响应不是 JSON 对象", "data": payload}
    return status, payload


def envelope_ok(payload: dict[str, Any]) -> bool:
    return payload.get("code") == 0


def token_is_usable(data: Any) -> bool:
    return isinstance(data, dict) and bool(data.get("accessToken"))


def calculate_expiry(auth: dict[str, Any]) -> dict[str, Any]:
    auth = dict(auth)
    auth.setdefault("lastRefreshTime", now_ms())
    if not auth.get("expiresAt") and auth.get("expiresIn"):
        auth["expiresAt"] = now_ms() + int(auth["expiresIn"]) * 1000
    if not auth.get("refreshExpiresAt") and auth.get("refreshExpiresIn"):
        auth["refreshExpiresAt"] = now_ms() + int(auth["refreshExpiresIn"]) * 1000
    return auth


def normalize_account(account: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in account.items() if value is not None}


def choose_account(
    account: dict[str, Any] | None,
    snapshot: dict[str, Any],
    prefer_uid: str | None = None,
) -> dict[str, Any]:
    accounts = snapshot.get("accounts") or []
    all_accounts = snapshot.get("allAccounts") or accounts
    candidates = all_accounts or accounts
    if prefer_uid:
        for item in candidates:
            if item.get("uid") == prefer_uid:
                return normalize_account({**item, **(account or {})})
    if account:
        return normalize_account(account)
    for item in candidates:
        if item.get("lastLogin"):
            return normalize_account(item)
    if candidates:
        return normalize_account(candidates[0])
    raise WorkBuddyError("服务端未返回可用账号")


def fetch_account_snapshot(
    endpoint: str,
    auth: dict[str, Any],
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> dict[str, Any]:
    status, payload = request_json(
        endpoint,
        "GET",
        f"{AUTH_PREFIX}/accounts",
        token=auth.get("accessToken"),
        account={},
        timeout=timeout,
    )
    if status != 200 or not envelope_ok(payload):
        raise WorkBuddyError(f"获取账号列表失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
    data = payload.get("data") or {}
    if not isinstance(data, dict):
        raise WorkBuddyError("账号列表响应格式异常")
    return data


def init_db(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id TEXT NOT NULL UNIQUE,
            label TEXT NOT NULL DEFAULT '',
            access_token TEXT NOT NULL,
            refresh_token TEXT,
            token_type TEXT,
            domain TEXT,
            expires_at INTEGER,
            refresh_expires_at INTEGER,
            account_json TEXT NOT NULL,
            accounts_json TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS checkin_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            action TEXT NOT NULL,
            ok INTEGER NOT NULL,
            code INTEGER,
            message TEXT,
            payload_json TEXT,
            created_at INTEGER NOT NULL,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        )
        """
    )
    conn.commit()
    try:
        os.chmod(db_path, 0o600)
    except OSError:
        pass
    return conn


def save_session(
    conn: sqlite3.Connection,
    endpoint: str,
    auth: dict[str, Any],
    account: dict[str, Any],
    snapshot: dict[str, Any] | None,
    label: str = "",
) -> int:
    del endpoint
    account_id = str(account.get("uid") or "")
    if not account_id:
        account_id = "token-" + hashlib.sha256(str(auth.get("accessToken", "")).encode("utf-8")).hexdigest()[:16]
    timestamp = now_ms()
    conn.execute(
        """
        INSERT INTO sessions (
            account_id, label, access_token, refresh_token, token_type, domain,
            expires_at, refresh_expires_at, account_json, accounts_json,
            enabled, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(account_id) DO UPDATE SET
            label = CASE WHEN excluded.label = '' THEN sessions.label ELSE excluded.label END,
            access_token = excluded.access_token,
            refresh_token = excluded.refresh_token,
            token_type = excluded.token_type,
            domain = excluded.domain,
            expires_at = excluded.expires_at,
            refresh_expires_at = excluded.refresh_expires_at,
            account_json = excluded.account_json,
            accounts_json = excluded.accounts_json,
            enabled = 1,
            updated_at = excluded.updated_at
        """,
        (
            account_id,
            label,
            auth.get("accessToken", ""),
            auth.get("refreshToken"),
            auth.get("tokenType"),
            auth.get("domain"),
            auth.get("expiresAt"),
            auth.get("refreshExpiresAt"),
            json.dumps(account, ensure_ascii=False, sort_keys=True),
            json.dumps(snapshot or {}, ensure_ascii=False, sort_keys=True),
            timestamp,
            timestamp,
        ),
    )
    conn.commit()
    row = conn.execute("SELECT id FROM sessions WHERE account_id = ?", (account_id,)).fetchone()
    return int(row["id"])


def list_sessions(
    conn: sqlite3.Connection,
    account_ids: Iterable[str] | None = None,
    enabled_only: bool = True,
) -> list[sqlite3.Row]:
    sql = "SELECT * FROM sessions"
    conditions: list[str] = []
    params: list[Any] = []
    if enabled_only:
        conditions.append("enabled = 1")
    ids = list(account_ids or [])
    if ids:
        placeholders = ",".join("?" for _ in ids)
        conditions.append(f"account_id IN ({placeholders})")
        params.extend(ids)
    if conditions:
        sql += " WHERE " + " AND ".join(conditions)
    sql += " ORDER BY updated_at DESC, id ASC"
    return list(conn.execute(sql, params))


def get_session(conn: sqlite3.Connection, account_id: str) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM sessions WHERE account_id = ?", (account_id,)).fetchone()


def refresh_session(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
    endpoint: str,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> sqlite3.Row:
    if not row["refresh_token"]:
        raise WorkBuddyError(f"账号 {row['account_id']} 没有 refresh_token，请重新 login")
    old_account = json.loads(row["account_json"] or "{}")
    status, payload = request_json(
        endpoint,
        "POST",
        f"{AUTH_PREFIX}/auth/token/refresh",
        refresh_token=row["refresh_token"],
        account={"domain": row["domain"]},
        timeout=timeout,
    )
    if status != 200 or not token_is_usable(payload.get("data")):
        raise WorkBuddyError(f"刷新登录态失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
    auth = calculate_expiry(payload["data"])
    auth["domain"] = auth.get("domain") or row["domain"]
    snapshot = fetch_account_snapshot(endpoint, auth, timeout)
    account = choose_account(old_account, snapshot, prefer_uid=row["account_id"])
    save_session(conn, endpoint, auth, account, snapshot, row["label"])
    updated = get_session(conn, row["account_id"])
    if not updated:
        raise WorkBuddyError("刷新登录态后无法读取数据库记录")
    return updated


def should_refresh(row: sqlite3.Row, skew_ms: int = 60_000) -> bool:
    if not row["refresh_token"] or not row["expires_at"]:
        return False
    return now_ms() + skew_ms >= int(row["expires_at"])


def ensure_session(conn: sqlite3.Connection, row: sqlite3.Row, endpoint: str) -> sqlite3.Row:
    return refresh_session(conn, row, endpoint) if should_refresh(row) else row


def auth_headers(row: sqlite3.Row, device_token: str | None = None) -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if device_token:
        headers["X-Device-Token"] = device_token
    return headers


def get_checkin_status(
    endpoint: str,
    row: sqlite3.Row,
    device_token: str | None = None,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> dict[str, Any]:
    account = json.loads(row["account_json"] or "{}")
    status, payload = request_json(
        endpoint,
        "POST",
        "/v2/billing/meter/checkin-activity-status",
        token=row["access_token"],
        account=account,
        body={},
        extra_headers=auth_headers(row, device_token),
        timeout=timeout,
    )
    if status in {401, 403}:
        raise WorkBuddyError(f"登录态无效: HTTP {status}")
    if status != 200 or not envelope_ok(payload):
        raise WorkBuddyError(f"查询签到状态失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
    return payload.get("data") or {}


def claim_daily_checkin(
    endpoint: str,
    row: sqlite3.Row,
    device_token: str | None = None,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> dict[str, Any]:
    account = json.loads(row["account_json"] or "{}")
    status, payload = request_json(
        endpoint,
        "POST",
        "/v2/billing/meter/daily-checkin",
        token=row["access_token"],
        account=account,
        body={},
        extra_headers=auth_headers(row, device_token),
        timeout=timeout,
    )
    data = payload.get("data")
    if status == 200 and envelope_ok(payload) and isinstance(data, dict):
        return data
    code = int(payload.get("code") or status or -1)
    message = str(payload.get("msg") or payload.get("message") or "签到失败")
    result = {"code": code, "msg": message, "requestId": payload.get("requestId")}
    if code in {10001, 10002} or "已签到" in message:
        return result
    raise WorkBuddyError(f"签到失败: HTTP {status} code={code} msg={message}")


def clean_number(value: float) -> int | float:
    return int(value) if value.is_integer() else round(value, 6)


def get_real_balance(
    endpoint: str,
    row: sqlite3.Row,
    timeout: float = DEFAULT_HTTP_TIMEOUT,
) -> dict[str, Any]:
    """查询真实资源余量，避免误用签到活动里的 total_credits。"""
    account = json.loads(row["account_json"] or "{}")
    enterprise_id = account.get("enterpriseId")
    path = "/v2/billing/meter/get-enterprise-user-usage" if enterprise_id else "/billing/meter/get-user-resource-summary"
    status, payload = request_json(
        endpoint,
        "POST",
        path,
        token=row["access_token"],
        account=account,
        body={},
        timeout=timeout,
    )
    if status in {401, 403}:
        raise WorkBuddyError(f"登录态无效: HTTP {status}")
    data = payload.get("data")
    if status != 200 or not envelope_ok(payload) or not isinstance(data, dict):
        raise WorkBuddyError(f"查询真实余额失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")

    if enterprise_id:
        usage = data.get("data") if isinstance(data.get("data"), dict) else data
        total = float(usage.get("limitNum") if usage.get("limitNum") is not None else usage.get("limit_num") or 0)
        used = float(usage.get("credit") if usage.get("credit") is not None else usage.get("used_num") or 0)
        unlimited = usage.get("limitNum") == -1 or usage.get("limit_num") == -1
        if unlimited:
            return {"source": "enterprise_user_usage", "creditsTotal": -1, "creditsLeft": -1, "creditsUsed": 0, "unlimited": True}
        return {
            "source": "enterprise_user_usage",
            "creditsTotal": clean_number(total),
            "creditsLeft": clean_number(max(0.0, total - used)),
            "creditsUsed": clean_number(used),
            "unlimited": False,
        }

    packages = []
    totals = [0.0, 0.0, 0.0]
    for raw in data.get("Packages") or []:
        if not isinstance(raw, dict):
            continue
        total = float(raw.get("CycleTotalCapacity") or raw.get("CycleTotal") or raw.get("CycleCapacitySizePrecise") or 0)
        remain = float(raw.get("CycleRemainCapacity") or raw.get("CycleRemain") or raw.get("CycleCapacityRemainPrecise") or 0)
        used = max(float(raw.get("CycleUsedCapacity") or raw.get("CycleUsed") or 0), total - remain)
        packages.append({"packageCode": raw.get("PackageCode") or "", "total": clean_number(total), "remain": clean_number(remain), "used": clean_number(used)})
        totals[0] += total
        totals[1] += remain
        totals[2] += used
    return {
        "source": "personal_resource_summary",
        "isPaidUser": bool(data.get("IsPaidUser")),
        "creditsTotal": clean_number(totals[0]),
        "creditsLeft": clean_number(totals[1]),
        "creditsUsed": clean_number(totals[2]),
        "unlimited": False,
        "packages": packages,
    }


def call_with_auth_retry(
    conn: sqlite3.Connection,
    row: sqlite3.Row,
    endpoint: str,
    func: Any,
    device_token: str | None,
    timeout: float,
) -> tuple[sqlite3.Row, Any]:
    """遇到登录态无效时刷新一次并重试。"""
    try:
        return row, func(row)
    except WorkBuddyError as exc:
        if "登录态无效" not in str(exc) or not row["refresh_token"]:
            raise
        row = refresh_session(conn, row, endpoint, timeout)
        return row, func(row)


def add_log(
    conn: sqlite3.Connection,
    session_id: int,
    action: str,
    ok: bool,
    code: int | None = None,
    message: str = "",
    payload: Any = None,
) -> None:
    conn.execute(
        """
        INSERT INTO checkin_logs
            (session_id, action, ok, code, message, payload_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            session_id,
            action,
            int(ok),
            code,
            message,
            json.dumps(payload, ensure_ascii=False, sort_keys=True) if payload is not None else None,
            now_ms(),
        ),
    )
    conn.commit()


def display_name(row: sqlite3.Row) -> str:
    try:
        account = json.loads(row["account_json"] or "{}")
    except Exception:
        account = {}
    return account.get("nickname") or account.get("displayName") or row["account_id"]
