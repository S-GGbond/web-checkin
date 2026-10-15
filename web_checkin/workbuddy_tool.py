#!/usr/bin/env python3
"""WorkBuddy 签到工具类：登录、刷新、状态查询和领取全部封装在类中。"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from typing import Any

from .account_store import AccountStore


DEFAULT_ENDPOINT = "https://www.workbuddy.cn"
CLIENT_VERSION = "5.6.2"
USER_AGENT = f"WorkBuddy/{CLIENT_VERSION}"
AUTH_PREFIX = "/v2/plugin"
PENDING_TOKEN_CODE = 11217
PENDING_ACCOUNT_CODE = 12151


class WorkBuddyTool:
    def __init__(self, store: AccountStore, poll_interval: float = 1.0):
        self.store = store
        self.poll_interval = poll_interval
        self._login_sessions: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _now_ms() -> int:
        return int(time.time() * 1000)

    @staticmethod
    def _endpoint_origin(endpoint: str) -> str:
        endpoint = (endpoint or DEFAULT_ENDPOINT).rstrip("/")
        if "://" not in endpoint:
            endpoint = "https://" + endpoint
        parsed = urllib.parse.urlparse(endpoint)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"无效 endpoint: {endpoint}")
        return f"{parsed.scheme}://{parsed.netloc}"

    def _headers(self, endpoint: str, account: dict[str, Any] | None = None) -> dict[str, str]:
        account = account or {}
        headers = {
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
            "X-IDE-Type": "WorkBuddy",
            "X-IDE-Name": "WorkBuddy",
            "X-IDE-Version": CLIENT_VERSION,
            "X-Product": "WorkBuddy",
            "X-Domain": account.get("domain") or urllib.parse.urlparse(self._endpoint_origin(endpoint)).hostname or "",
        }
        if account.get("uid"):
            headers["X-User-Id"] = str(account["uid"])
        else:
            headers.update(
                {
                    "X-No-User-Id": "true",
                    "X-No-Enterprise-Id": "true",
                    "X-No-Department-Info": "true",
                }
            )
        enterprise_id = account.get("enterpriseId")
        if enterprise_id:
            headers["X-Enterprise-Id"] = str(enterprise_id)
            headers["X-Tenant-Id"] = str(enterprise_id)
        return headers

    def _request_json(
        self,
        endpoint: str,
        method: str,
        path: str,
        *,
        token: str | None = None,
        refresh_token: str | None = None,
        account: dict[str, Any] | None = None,
        body: dict[str, Any] | None = None,
        timeout: float = 20.0,
    ) -> tuple[int, dict[str, Any]]:
        url = self._endpoint_origin(endpoint) + path
        headers = self._headers(endpoint, account)
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

        request = urllib.request.Request(url, data=raw_body, headers=headers, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.status
                payload = json.loads(response.read().decode("utf-8", "replace") or "{}")
        except urllib.error.HTTPError as exc:
            status = exc.code
            try:
                payload = json.loads(exc.read().decode("utf-8", "replace") or "{}")
            except Exception:
                payload = {"code": exc.code, "msg": str(exc.reason)}
        except Exception as exc:
            raise RuntimeError(f"请求失败: {method} {path}: {exc}") from exc
        if not isinstance(payload, dict):
            payload = {"code": -1, "msg": "响应不是 JSON 对象", "data": payload}
        return status, payload

    @staticmethod
    def _calculate_expiry(auth: dict[str, Any]) -> dict[str, Any]:
        auth = dict(auth)
        auth.setdefault("lastRefreshTime", WorkBuddyTool._now_ms())
        if not auth.get("expiresAt") and auth.get("expiresIn"):
            auth["expiresAt"] = WorkBuddyTool._now_ms() + int(auth["expiresIn"]) * 1000
        if not auth.get("refreshExpiresAt") and auth.get("refreshExpiresIn"):
            auth["refreshExpiresAt"] = WorkBuddyTool._now_ms() + int(auth["refreshExpiresIn"]) * 1000
        return auth

    @staticmethod
    def _choose_account(account: dict[str, Any] | None, snapshot: dict[str, Any], prefer_uid: str | None = None) -> dict[str, Any]:
        accounts = snapshot.get("accounts") or []
        all_accounts = snapshot.get("allAccounts") or accounts
        candidates = all_accounts or accounts
        if prefer_uid:
            for item in candidates:
                if item.get("uid") == prefer_uid:
                    merged = {**item, **(account or {})}
                    return {key: value for key, value in merged.items() if value is not None}
        if account:
            return {key: value for key, value in account.items() if value is not None}
        for item in candidates:
            if item.get("lastLogin"):
                return item
        if candidates:
            return candidates[0]
        raise RuntimeError("服务端未返回可用账号")

    def _fetch_snapshot(self, endpoint: str, auth: dict[str, Any], timeout: float = 20.0) -> dict[str, Any]:
        status, payload = self._request_json(
            endpoint, "GET", f"{AUTH_PREFIX}/accounts", token=auth.get("accessToken"), account={}, timeout=timeout
        )
        if status != 200 or payload.get("code") != 0 or not isinstance(payload.get("data"), dict):
            raise RuntimeError(f"获取账号列表失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
        return payload["data"]

    def _save_credential(self, row: Any, auth: dict[str, Any], account: dict[str, Any], snapshot: dict[str, Any]) -> None:
        credential = {
            "auth": auth,
            "account": account,
            "snapshot": snapshot,
        }
        self.store.update_account(
            int(row["id"]),
            credential=json.dumps(credential, ensure_ascii=False, sort_keys=True),
            display_name=account.get("nickname") or account.get("displayName") or None,
        )

    def refresh(self, row: Any, timeout: float = 20.0) -> dict[str, Any]:
        credential = json.loads(row["credential"])
        auth = credential["auth"]
        if not auth.get("refreshToken"):
            raise RuntimeError("没有 refresh_token，请重新登录")
        status, payload = self._request_json(
            row["endpoint"],
            "POST",
            f"{AUTH_PREFIX}/auth/token/refresh",
            refresh_token=auth["refreshToken"],
            account={"domain": auth.get("domain")},
            timeout=timeout,
        )
        data = payload.get("data")
        if status != 200 or payload.get("code") != 0 or not isinstance(data, dict) or not data.get("accessToken"):
            raise RuntimeError(f"刷新登录态失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
        new_auth = self._calculate_expiry(data)
        new_auth["domain"] = new_auth.get("domain") or auth.get("domain")
        snapshot = self._fetch_snapshot(row["endpoint"], new_auth, timeout)
        account = self._choose_account(credential.get("account"), snapshot, prefer_uid=row["external_id"])
        credential.update({"auth": new_auth, "account": account, "snapshot": snapshot})
        self.store.update_account(
            int(row["id"]),
            credential=json.dumps(credential, ensure_ascii=False, sort_keys=True),
            display_name=account.get("nickname") or account.get("displayName") or None,
        )
        return credential

    def _ensure_fresh(self, row: Any) -> tuple[Any, dict[str, Any]]:
        credential = json.loads(row["credential"])
        auth = credential["auth"]
        expires_at = auth.get("expiresAt")
        if auth.get("refreshToken") and expires_at and self._now_ms() + 60_000 >= int(expires_at):
            credential = self.refresh(row)
        return row, credential

    @staticmethod
    def _number(value: Any) -> float:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return 0.0
        return max(0.0, parsed)

    @staticmethod
    def _clean_number(value: float) -> int | float:
        return int(value) if value.is_integer() else round(value, 6)

    def _parse_personal_usage(self, data: dict[str, Any]) -> dict[str, Any]:
        packages: list[dict[str, Any]] = []
        totals = {"creditsTotal": 0.0, "creditsLeft": 0.0, "creditsUsed": 0.0}
        for raw in data.get("Packages") or []:
            if not isinstance(raw, dict):
                continue
            item = {
                "packageCode": raw.get("PackageCode") or raw.get("packageCode") or "",
                "total": self._number(raw.get("CycleTotalCapacity") or raw.get("CycleTotal") or raw.get("CycleCapacitySizePrecise")),
                "remain": self._number(raw.get("CycleRemainCapacity") or raw.get("CycleRemain") or raw.get("CycleCapacityRemainPrecise")),
                "used": self._number(raw.get("CycleUsedCapacity") or raw.get("CycleUsed")),
            }
            item["used"] = max(item["used"], item["total"] - item["remain"])
            packages.append(item)
            totals["creditsTotal"] += item["total"]
            totals["creditsLeft"] += item["remain"]
            totals["creditsUsed"] += item["used"]
        return {
            "source": "personal_resource_summary",
            "isPaidUser": bool(data.get("IsPaidUser")),
            "unlimited": False,
            "creditsTotal": self._clean_number(totals["creditsTotal"]),
            "creditsLeft": self._clean_number(totals["creditsLeft"]),
            "creditsUsed": self._clean_number(totals["creditsUsed"]),
            "packages": packages,
        }

    def _parse_enterprise_usage(self, data: dict[str, Any]) -> dict[str, Any]:
        # 企业接口可能存在 data.data 与 data 两层包装，这里按客户端实现兜底。
        usage = data.get("data") if isinstance(data.get("data"), dict) else data
        total = self._number(usage.get("limitNum") if usage.get("limitNum") is not None else usage.get("limit_num"))
        used = self._number(usage.get("credit") if usage.get("credit") is not None else usage.get("used_num"))
        unlimited = usage.get("limitNum") == -1 or usage.get("limit_num") == -1
        if unlimited:
            total = -1.0
            left = -1.0
        else:
            left = max(0.0, total - used)
        return {
            "source": "enterprise_user_usage",
            "unlimited": unlimited,
            "creditsTotal": self._clean_number(total),
            "creditsLeft": self._clean_number(left),
            "creditsUsed": self._clean_number(0.0 if unlimited else used),
            "packages": [],
        }

    def _usage_request(self, row: Any, credential: dict[str, Any]) -> dict[str, Any]:
        account = credential["account"]
        enterprise_id = account.get("enterpriseId") or credential["auth"].get("enterpriseId")
        path = "/v2/billing/meter/get-enterprise-user-usage" if enterprise_id else "/billing/meter/get-user-resource-summary"
        status, payload = self._request_json(row["endpoint"], "POST", path, token=credential["auth"]["accessToken"], account=account, body={})
        if status in {401, 403}:
            raise PermissionError(f"登录态无效: HTTP {status}")
        data = payload.get("data")
        if status != 200 or payload.get("code") != 0 or not isinstance(data, dict):
            raise RuntimeError(f"查询真实余额失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
        usage = self._parse_enterprise_usage(data) if enterprise_id else self._parse_personal_usage(data)
        return usage

    @staticmethod
    def _merge_usage(checkin_status: dict[str, Any], usage: dict[str, Any]) -> dict[str, Any]:
        return {**checkin_status, "usage": usage, "credits_left": usage["creditsLeft"], "credits_total": usage["creditsTotal"]}

    def _status_request(self, row: Any, credential: dict[str, Any]) -> dict[str, Any]:
        account = credential["account"]
        status, payload = self._request_json(
            row["endpoint"],
            "POST",
            "/v2/billing/meter/checkin-activity-status",
            token=credential["auth"]["accessToken"],
            account=account,
            body={},
        )
        if status in {401, 403}:
            raise PermissionError(f"登录态无效: HTTP {status}")
        if status != 200 or payload.get("code") != 0:
            raise RuntimeError(f"查询签到状态失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
        return payload.get("data") or {}

    def _claim_request(self, row: Any, credential: dict[str, Any]) -> dict[str, Any]:
        account = credential["account"]
        status, payload = self._request_json(
            row["endpoint"],
            "POST",
            "/v2/billing/meter/daily-checkin",
            token=credential["auth"]["accessToken"],
            account=account,
            body={},
        )
        data = payload.get("data")
        if status == 200 and payload.get("code") == 0 and isinstance(data, dict):
            return data
        code = int(payload.get("code") or status or -1)
        message = str(payload.get("msg") or payload.get("message") or "签到失败")
        if code in {10001, 10002} or "已签到" in message:
            return {"code": code, "msg": message}
        raise RuntimeError(f"签到失败: HTTP {status} code={code} msg={message}")

    def _with_auth_retry(self, row: Any, method_name: str) -> dict[str, Any]:
        row, credential = self._ensure_fresh(row)
        method = getattr(self, method_name)
        try:
            return method(row, credential)
        except PermissionError:
            credential = self.refresh(row)
            return method(row, credential)

    def _fetch_status(self, row: Any, credential: dict[str, Any] | None = None) -> dict[str, Any]:
        if credential is None:
            row, credential = self._ensure_fresh(row)
        try:
            checkin_status = self._status_request(row, credential)
            usage = self._usage_request(row, credential)
        except PermissionError:
            credential = self.refresh(row)
            checkin_status = self._status_request(row, credential)
            usage = self._usage_request(row, credential)
        return self._merge_usage(checkin_status, usage)

    def status(self, row: Any) -> dict[str, Any]:
        result = self._fetch_status(row)
        self.store.update_status(int(row["id"]), result)
        return result

    def checkin(self, row: Any) -> dict[str, Any]:
        status = self._fetch_status(row)
        row = self.store.get_account(int(row["id"])) or row
        credential = json.loads(row["credential"])

        if not status.get("active"):
            result = {"action": "skip", "ok": True, "message": "签到活动未开启", "status": status}
        elif status.get("today_checked_in"):
            result = {"action": "already", "ok": True, "message": "今日已签到", "status": status}
        else:
            try:
                claim = self._claim_request(row, credential)
            except PermissionError:
                credential = self.refresh(row)
                claim = self._claim_request(row, credential)
            status_after = self._status_request(row, credential)
            usage_after = self._usage_request(row, credential)
            status_after = self._merge_usage(status_after, usage_after)
            result = {"action": "claim", "ok": True, "message": claim.get("msg") or "签到成功", "claim": claim, "status": status_after}

        self.store.update_status(int(row["id"]), result.get("status") or status)
        self.store.update_checkin(int(row["id"]), ok=result["ok"], message=result["message"])
        self.store.add_log(
            int(row["id"]), "workbuddy", action=result["action"], ok=result["ok"], message=result["message"], payload=result
        )
        return result

    @staticmethod
    def _display_name(row_or_account: Any) -> str:
        if isinstance(row_or_account, dict) and "account_json" not in row_or_account:
            return row_or_account.get("display_name") or row_or_account.get("external_id") or "未知账号"
        try:
            credential = json.loads(row_or_account["credential"])
            account = credential.get("account", {})
            return account.get("nickname") or account.get("displayName") or row_or_account["external_id"]
        except Exception:
            return "未知账号"

    def start_login(
        self,
        *,
        endpoint: str = DEFAULT_ENDPOINT,
        platform: str = "workbuddy",
        label: str = "",
        auto_browser: bool = True,
        timeout: float = 600.0,
    ) -> dict[str, Any]:
        status, payload = self._request_json(
            endpoint,
            "POST",
            f"{AUTH_PREFIX}/auth/state?platform={urllib.parse.quote(platform)}",
            body={},
        )
        data = payload.get("data")
        if status != 200 or payload.get("code") != 0 or not isinstance(data, dict) or not data.get("state") or not data.get("authUrl"):
            raise RuntimeError(f"申请登录 state 失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")

        login_id = str(uuid.uuid4())
        session = {
            "id": login_id,
            "provider": "workbuddy",
            "auth_url": data["authUrl"],
            "status": "waiting",
            "message": "等待浏览器授权",
            "account": None,
            "created_at": int(time.time()),
            "deadline": time.monotonic() + timeout,
            "state": data["state"],
            "endpoint": self._endpoint_origin(endpoint),
            "label": label,
        }
        with self._lock:
            self._login_sessions[login_id] = session
        if auto_browser:
            try:
                webbrowser.open(data["authUrl"])
            except Exception:
                pass
        threading.Thread(target=self._wait_login, args=(login_id,), daemon=True).start()
        return self.public_login(session)

    def public_login(self, session: dict[str, Any]) -> dict[str, Any]:
        return {key: value for key, value in session.items() if key not in {"deadline", "state", "endpoint"}}

    def login_status(self, login_id: str) -> dict[str, Any]:
        with self._lock:
            session = self._login_sessions.get(login_id)
            if not session:
                raise RuntimeError("登录会话不存在或已过期")
            return self.public_login(session)

    def _wait_login(self, login_id: str) -> None:
        with self._lock:
            session = self._login_sessions.get(login_id)
        if not session:
            return
        endpoint = session["endpoint"]
        state = session["state"]
        try:
            auth = None
            while time.monotonic() < session["deadline"]:
                time.sleep(self.poll_interval)
                status, payload = self._request_json(
                    endpoint, "GET", f"{AUTH_PREFIX}/auth/token?state={urllib.parse.quote(state)}"
                )
                data = payload.get("data")
                if isinstance(data, dict) and data.get("accessToken"):
                    auth = self._calculate_expiry(data)
                    break
                if int(payload.get("code") or 0) != PENDING_TOKEN_CODE:
                    raise RuntimeError(f"获取登录令牌失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
            if not auth:
                raise RuntimeError("等待登录超时")

            session["status"] = "exchanging"
            session["message"] = "正在获取账号信息"
            account_status, account_payload = (0, {})
            account_deadline = time.monotonic() + min(120, max(0, session["deadline"] - time.monotonic()))
            while time.monotonic() < account_deadline:
                account_status, account_payload = self._request_json(
                    endpoint,
                    "GET",
                    f"{AUTH_PREFIX}/login/account?state={urllib.parse.quote(state)}",
                    token=auth.get("accessToken"),
                    account={"domain": auth.get("domain")},
                )
                if int(account_payload.get("code") or 0) == PENDING_ACCOUNT_CODE:
                    time.sleep(self.poll_interval)
                    continue
                break
            account = account_payload.get("data")
            if account_status != 200 or account_payload.get("code") != 0 or not isinstance(account, dict):
                raise RuntimeError(f"获取账号失败: HTTP {account_status} code={account_payload.get('code')} msg={account_payload.get('msg')}")
            snapshot = self._fetch_snapshot(endpoint, auth)
            account = self._choose_account(account, snapshot)
            account_id = str(account.get("uid") or "")
            if not account_id:
                digest = hashlib.sha256(str(auth.get("accessToken", "")).encode()).hexdigest()[:16]
                account_id = f"token-{digest}"
            display_name = account.get("nickname") or account.get("displayName") or account_id
            credential = {"auth": auth, "account": account, "snapshot": snapshot}
            db_id = self.store.upsert_account(
                provider="workbuddy",
                external_id=account_id,
                display_name=display_name,
                endpoint=endpoint,
                credential=json.dumps(credential, ensure_ascii=False, sort_keys=True),
                label=session.get("label", ""),
            )
            self.store.add_log(db_id, "workbuddy", action="login", ok=True, message="登录成功", payload={"display_name": display_name})
            session.update({"status": "success", "message": "登录成功", "account": {"id": db_id, "name": display_name, "external_id": account_id}})
        except Exception as exc:
            session.update({"status": "failed", "message": str(exc)})
        finally:
            with self._lock:
                self._login_sessions[login_id] = session

    def import_legacy_sessions(self, legacy_db: str) -> list[int]:
        import sqlite3

        conn = sqlite3.connect(legacy_db)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT * FROM sessions").fetchall()
        imported: list[int] = []
        for row in rows:
            try:
                account = json.loads(row["account_json"] or "{}")
                auth = {
                    "accessToken": row["access_token"],
                    "refreshToken": row["refresh_token"],
                    "tokenType": row["token_type"],
                    "domain": row["domain"],
                    "expiresAt": row["expires_at"],
                    "refreshExpiresAt": row["refresh_expires_at"],
                }
                endpoint = DEFAULT_ENDPOINT
                snapshot = {}
                try:
                    snapshot = self._fetch_snapshot(endpoint, auth)
                except Exception:
                    snapshot = {}
                account = self._choose_account(account, snapshot, prefer_uid=row["account_id"])
                credential = {"auth": auth, "account": account, "snapshot": snapshot}
                imported.append(
                    self.store.upsert_account(
                        provider="workbuddy",
                        external_id=str(row["account_id"]),
                        display_name=account.get("nickname") or account.get("displayName") or str(row["account_id"]),
                        endpoint=endpoint,
                        credential=json.dumps(credential, ensure_ascii=False, sort_keys=True),
                        label=row["label"] or "",
                    )
                )
            except Exception:
                continue
        conn.close()
        return imported
