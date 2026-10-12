#!/usr/bin/env python3
"""Qoder 账号接入：使用项目内置 Python 脚本完成登录、状态和签到。"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.request
import uuid
import webbrowser
from typing import Any

import qoder_login
from account_store import AccountStore


OPENAPI_BASE = "https://openapi.qoder.com.cn"
EXPIRY_MARGIN = 60


class QoderTool:
    def __init__(self, store: AccountStore, data_dir: str | None = None):
        self.store = store
        # 允许测试传入隔离目录；生产环境由 QODER_DATA_DIR 控制。
        if data_dir:
            qoder_login.set_data_dir(data_dir)
        self._login = qoder_login
        self._login_sessions: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _display_name(user: dict[str, Any], fallback: str = "") -> str:
        return str(user.get("name") or user.get("username") or user.get("user_name") or fallback)

    @staticmethod
    def _external_id(user: dict[str, Any]) -> str:
        return str(user.get("id") or user.get("user_id") or user.get("uid") or "")

    def import_local_auth(self) -> dict[str, Any]:
        auth_path = qoder_login.AUTH_FILE
        if not auth_path.exists():
            return {"ok": False, "message": "未找到 Qoder 登录态文件"}
        try:
            auth = json.loads(auth_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            return {"ok": False, "message": f"Qoder 登录态文件无效: {exc}"}
        if not auth.get("refreshToken"):
            return {"ok": False, "message": "参考登录态缺少 refreshToken"}
        user = auth.get("user") if isinstance(auth.get("user"), dict) else {}
        external_id = self._external_id(user)
        if not external_id:
            return {"ok": False, "message": "参考登录态缺少用户 ID"}
        existing = next((row for row in self.store.list_account_rows() if row["provider"] == "qoder" and str(row["external_id"]) == external_id), None)
        reference_saved_at = float(auth.get("savedAt") or 0)
        if existing:
            try:
                existing_saved_at = float(json.loads(existing["credential"]).get("savedAt") or 0)
            except (json.JSONDecodeError, TypeError, ValueError):
                existing_saved_at = 0
            if reference_saved_at <= existing_saved_at:
                self.store.set_setting("qoder_local_auth_saved_at", str(max(existing_saved_at, reference_saved_at)))
                return {"ok": True, "message": "Qoder 登录态已是最新", "account_id": int(existing["id"])}
        elif reference_saved_at <= float(self.store.get_setting("qoder_local_auth_saved_at", "0") or 0):
            return {"ok": True, "message": "Qoder 参考登录态已导入过", "account_id": None}
        db_id = self.store.upsert_account(
            provider="qoder",
            external_id=external_id,
            display_name=self._display_name(user),
            endpoint=OPENAPI_BASE,
            credential=json.dumps(auth, ensure_ascii=False, sort_keys=True),
        )
        self.store.set_setting("qoder_local_auth_saved_at", str(reference_saved_at))
        return {"ok": True, "message": "Qoder 参考登录态已导入", "account_id": db_id}

    def start_login(self, *, label: str = "", auto_browser: bool = False, timeout: float = 300) -> dict[str, Any]:
        verifier = self._login.gen_verifier(64)
        challenge = self._login.b64url(hashlib.sha256(verifier.encode("ascii")).digest())
        nonce = str(uuid.uuid4())
        machine_id = self._login.load_machine_id()
        login_id = str(uuid.uuid4())
        session: dict[str, Any] = {
            "id": login_id,
            "status": "pending",
            "message": "等待网页授权",
            "auth_url": self._login.build_login_url(challenge, nonce, machine_id, False),
            "verifier": verifier,
            "nonce": nonce,
            "label": label,
            "deadline": time.monotonic() + timeout,
        }
        with self._lock:
            self._login_sessions[login_id] = session
        if auto_browser:
            try:
                webbrowser.open(session["auth_url"])
            except Exception:
                pass
        threading.Thread(target=self._wait_login, args=(login_id, timeout), daemon=True).start()
        return self.public_login(session)

    def public_login(self, session: dict[str, Any]) -> dict[str, Any]:
        return {key: value for key, value in session.items() if key not in {"verifier", "nonce"}}

    def login_status(self, login_id: str) -> dict[str, Any]:
        with self._lock:
            session = self._login_sessions.get(login_id)
        if not session:
            raise RuntimeError("登录会话不存在或已过期")
        return self.public_login(session)

    def _wait_login(self, login_id: str, timeout: float) -> None:
        with self._lock:
            session = self._login_sessions.get(login_id)
        if not session:
            return
        try:
            token_payload = self._login.wait_for_token(session["nonce"], session["verifier"], 1.0, timeout)
            session["message"] = "正在获取用户信息"
            token = token_payload["token"]
            user = self._login.fetch_userinfo(token)
            if not isinstance(user, dict) or not user:
                raise RuntimeError("获取用户信息失败")
            auth = {
                "schemaVersion": 1,
                "token": token,
                "refreshToken": token_payload["refresh_token"],
                "expiresAt": self._login.pick_expiry(token_payload, "expires_at", "expires_in"),
                "refreshTokenExpiresAt": self._login.pick_expiry(token_payload, "refresh_token_expires_at", "refresh_token_expires_in"),
                "machineId": self._login.load_machine_id(),
                "user": user,
                "savedAt": time.time(),
            }
            external_id = self._external_id(user)
            if not external_id:
                raise RuntimeError("用户信息缺少 ID")
            db_id = self.store.upsert_account(
                provider="qoder",
                external_id=external_id,
                display_name=self._display_name(user),
                endpoint=OPENAPI_BASE,
                credential=json.dumps(auth, ensure_ascii=False, sort_keys=True),
                label=session.get("label", ""),
            )
            self.store.add_log(db_id, "qoder", action="login", ok=True, message="Web 登录成功")
            session.update({
                "status": "success",
                "message": "登录成功",
                "account": {"id": db_id, "name": self._display_name(user), "external_id": external_id},
            })
        except Exception as exc:
            session.update({"status": "failed", "message": str(exc)})
        finally:
            with self._lock:
                self._login_sessions[login_id] = session

    def _http(self, method: str, url: str, *, token: str | None = None, body: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
        headers = self._login.build_headers(token)
        raw_body = None
        if method.upper() == "POST":
            headers["Content-Type"] = "application/json"
            raw_body = json.dumps(body or {}, separators=(",", ":")).encode("utf-8")
        request = urllib.request.Request(url, data=raw_body, headers=headers, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode("utf-8", "replace") or "{}")
                return response.status, payload
        except urllib.error.HTTPError as exc:
            try:
                payload = json.loads(exc.read().decode("utf-8", "replace") or "{}")
            except Exception:
                payload = {"message": str(exc.reason)}
            return exc.code, payload
        except Exception as exc:
            raise RuntimeError(f"Qoder 请求失败: {url}: {exc}") from exc

    def _refresh(self, auth: dict[str, Any]) -> dict[str, Any]:
        status, payload = self._http(
            "POST",
            f"{OPENAPI_BASE}/api/v1/deviceToken/refresh",
            body={"refresh_token": auth["refreshToken"]},
        )
        token = payload.get("device_token") or payload.get("token")
        if status != 200 or not token:
            message = payload.get("message") or payload.get("msg") or f"HTTP {status}"
            raise RuntimeError(f"Qoder token 续期失败: {message}")
        auth["token"] = token
        auth["refreshToken"] = payload.get("refresh_token") or auth["refreshToken"]
        auth["expiresAt"] = self._login.pick_expiry(payload, "expires_at", "expires_in")
        auth["refreshTokenExpiresAt"] = self._login.pick_expiry(payload, "refresh_token_expires_at", "refresh_token_expires_in")
        auth["savedAt"] = time.time()
        return auth

    def _load_auth(self, row: Any) -> dict[str, Any]:
        auth = json.loads(row["credential"])
        now = time.time()
        if now >= auth.get("refreshTokenExpiresAt", 0):
            raise RuntimeError("Qoder refreshToken 已过期，请重新登录")
        if now >= auth.get("expiresAt", 0) - EXPIRY_MARGIN:
            auth = self._refresh(auth)
            self.store.update_account(int(row["id"]), credential=json.dumps(auth, ensure_ascii=False, sort_keys=True))
        return auth

    def _campaigns(self, row: Any, auth: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        headers = self._login.build_headers(auth["token"])
        status, text = self._login.http("GET", f"{OPENAPI_BASE}/sash/api/v1/me/campaigns", headers)
        if status == 401:
            auth = self._refresh(auth)
            self.store.update_account(int(row["id"]), credential=json.dumps(auth, ensure_ascii=False, sort_keys=True))
            headers = self._login.build_headers(auth["token"])
            status, text = self._login.http("GET", f"{OPENAPI_BASE}/sash/api/v1/me/campaigns", headers)
        if status != 200:
            raise RuntimeError(f"拉取 Qoder 活动失败: HTTP {status}")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Qoder 活动响应不是有效 JSON") from exc
        campaigns = payload.get("campaigns") or []
        if not isinstance(campaigns, list):
            raise RuntimeError("Qoder 活动响应格式异常")
        return [item for item in campaigns if isinstance(item, dict)], auth

    @staticmethod
    def _activity_status(campaigns: list[dict[str, Any]]) -> dict[str, Any]:
        # Qoder 没有 WorkBuddy / Trae 那种明确的“今日已签”字段。
        # 缺少 CLAIMABLE 只能说明当前不可领取，不能倒推出“今日已签到”。
        claimable = [item for item in campaigns if item.get("claimStatus") == "CLAIMABLE"]
        claimed = [item for item in campaigns if item.get("claimStatus") == "CLAIMED"]
        return {
            "campaignCount": len(campaigns),
            "claimableCount": len(claimable),
            "claimedCount": len(claimed),
            "checked": bool(claimed),
        }

    def status(self, row: Any) -> dict[str, Any]:
        auth = self._load_auth(row)
        campaigns, auth = self._campaigns(row, auth)
        self.store.update_account(int(row["id"]), credential=json.dumps(auth, ensure_ascii=False, sort_keys=True))
        return self._activity_status(campaigns)

    def checkin(self, row: Any) -> dict[str, Any]:
        auth = self._load_auth(row)
        campaigns, auth = self._campaigns(row, auth)
        claimable = [item for item in campaigns if item.get("claimStatus") == "CLAIMABLE"]
        if not claimable:
            self.store.update_account(int(row["id"]), credential=json.dumps(auth, ensure_ascii=False, sort_keys=True))
            return {
                "action": "skip",
                "ok": True,
                "message": "没有可领取活动（可能未开始或已结束）",
                "status": self._activity_status(campaigns),
            }
        succeeded = 0
        for campaign in claimable:
            campaign_id = campaign.get("campaignId")
            headers = self._login.build_headers(auth["token"])
            status, text = self._login.http("POST", f"{OPENAPI_BASE}/sash/api/v1/me/campaigns/{campaign_id}/claim", headers)
            if status == 200:
                succeeded += 1
            else:
                message = text[:180]
                raise RuntimeError(f"领取 {campaign.get('campaignKey', campaign_id)} 失败: HTTP {status}: {message}")
        campaigns, auth = self._campaigns(row, auth)
        self.store.update_account(int(row["id"]), credential=json.dumps(auth, ensure_ascii=False, sort_keys=True))
        return {
            "action": "claimed",
            "ok": succeeded == len(claimable),
            "message": f"成功领取 {succeeded}/{len(claimable)} 个活动",
            "status": self._activity_status(campaigns),
        }
