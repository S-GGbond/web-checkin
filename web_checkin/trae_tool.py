#!/usr/bin/env python3
"""Trae 签到工具类：Python 版登录态加解密、刷新、状态查询和签到。"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import platform
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

from .account_store import AccountStore
from .paths import default_identity_path
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.algorithms import AES
from cryptography.hazmat.primitives.ciphers.modes import CBC


CLIENT_ID = "ono9krqynydwx5"
API_HOST = "https://api.trae.cn"
LOGIN_HOST = "https://www.trae.cn"
AUTH_KEY = "iCubeAuthInfo://icube.cloudide"
HEADER = bytes([0x74, 0x63, 0x05, 0x10, 0x00, 0x00])
RB_LEN = 32
HMAC_LEN = 64
SALT_A = bytes([
    82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,
    155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,
    238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,
    139,209,37,
])
SALT_B = bytes([
    31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,
    181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,
    200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,
    85,33,12,125,
])
SALT = bytes(a ^ b for a, b in zip(SALT_A, SALT_B))


def _make_callback_handler(session: dict[str, Any]) -> type[BaseHTTPRequestHandler]:
    """为单个登录会话构造回调处理器，把本次回调结果写入对应会话。

    必须按会话绑定（而不是用类属性），否则并发登录时回调会串到别的会话。
    """

    class _CallbackHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/authorize":
                self.send_response(404)
                self.end_headers()
                return
            session["search"] = parsed.query
            session["event"].set()
            body = "<!doctype html><meta charset='utf-8'><title>Trae 登录成功</title><body style='font-family:system-ui;text-align:center;padding:60px'><h2>登录成功</h2><p>可以关闭本页面。</p></body>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))

        def log_message(self, format: str, *args: Any) -> None:
            return

    return _CallbackHandler


class TraeTool:
    def __init__(self, store: AccountStore, identity_path: str | Path | None = None):
        self.store = store
        self.identity_path = Path(identity_path) if identity_path else default_identity_path()
        self._login_sessions: dict[str, dict[str, Any]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _now_iso() -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    @staticmethod
    def _pick(data: dict[str, Any], *keys: str) -> Any:
        for key in keys:
            if data.get(key) is not None:
                return data[key]
        return None

    def _identity(self) -> dict[str, Any]:
        env_identity = os.environ.get("TRAE_IDENTITY_PATH")
        candidates = [self.identity_path]
        if env_identity:
            candidates.append(Path(env_identity))
        candidates.append(Path.home() / ".trae-checkin" / "identity.json")
        for path in candidates:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if data.get("machineId") and data.get("deviceId"):
                    return data
            except Exception:
                continue
        identity = {
            "machineId": secrets.token_hex(32),
            "deviceId": secrets.token_hex(16),
            "deviceName": "Linux-PC",
        }
        self.identity_path.parent.mkdir(parents=True, exist_ok=True)
        self.identity_path.write_text(json.dumps(identity, ensure_ascii=False, indent=2), encoding="utf-8")
        try:
            os.chmod(self.identity_path, 0o600)
        except OSError:
            pass
        return identity

    @staticmethod
    def _client_version() -> str:
        candidates = [
            Path("/usr/share/trae-cn/resources/app/package.json"),
            Path("/usr/share/trae/resources/app/package.json"),
        ]
        for path in candidates:
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
                if data.get("version"):
                    return str(data["version"])
            except Exception:
                continue
        return "3.3.99"

    @staticmethod
    def _pkcs7_pad(data: bytes) -> bytes:
        size = 16
        amount = size - (len(data) % size)
        return data + bytes([amount] * amount)

    @staticmethod
    def _pkcs7_unpad(data: bytes) -> bytes:
        if not data or len(data) % 16:
            raise ValueError("AES 明文长度异常")
        amount = data[-1]
        if amount < 1 or amount > 16 or data[-amount:] != bytes([amount] * amount):
            raise ValueError("AES padding 校验失败")
        return data[:-amount]

    def _derive_key(self, random_block: bytes) -> tuple[bytes, bytes]:
        if len(random_block) != RB_LEN:
            raise ValueError("随机块长度必须为 32")
        inner = hashlib.sha512(random_block).digest()
        final_hash = hashlib.sha512(inner + SALT).digest()
        return final_hash[:16], final_hash[16:32]

    def decrypt(self, encoded: str) -> dict[str, Any]:
        data = base64.b64decode(encoded)
        if data[:6] != HEADER:
            raise ValueError("未知的 Trae 登录态加密格式")
        random_block = data[6:38]
        encrypted = data[38:]
        key, iv = self._derive_key(random_block)
        decryptor = Cipher(AES(key), CBC(iv)).decryptor()
        plain = self._pkcs7_unpad(decryptor.update(encrypted) + decryptor.finalize())
        if len(plain) <= HMAC_LEN:
            raise ValueError("明文过短")
        stored_mac, payload = plain[:HMAC_LEN], plain[HMAC_LEN:]
        if hashlib.sha512(payload).digest() != stored_mac:
            raise ValueError("Trae 登录态完整性校验失败")
        return json.loads(payload.decode("utf-8"))

    def encrypt(self, auth: dict[str, Any]) -> str:
        payload = json.dumps(auth, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        mac = hashlib.sha512(payload).digest()
        plain = mac + payload
        random_block = secrets.token_bytes(RB_LEN)
        key, iv = self._derive_key(random_block)
        encryptor = Cipher(AES(key), CBC(iv)).encryptor()
        encrypted = encryptor.update(self._pkcs7_pad(plain)) + encryptor.finalize()
        return base64.b64encode(HEADER + random_block + encrypted).decode("ascii")

    def _request_json(
        self,
        url: str,
        *,
        method: str = "POST",
        headers: dict[str, str] | None = None,
        body: dict[str, Any] | None = None,
        timeout: float = 20.0,
    ) -> tuple[int, dict[str, Any]]:
        raw_body = json.dumps(body or {}, separators=(",", ":")).encode("utf-8") if method.upper() == "POST" else None
        request = urllib.request.Request(url, data=raw_body, headers=headers or {}, method=method.upper())
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.status
                payload = json.loads(response.read().decode("utf-8", "replace") or "{}")
        except urllib.error.HTTPError as exc:
            status = exc.code
            try:
                payload = json.loads(exc.read().decode("utf-8", "replace") or "{}")
            except Exception:
                payload = {"message": str(exc.reason)}
        except Exception as exc:
            raise RuntimeError(f"请求失败: {url}: {exc}") from exc
        if not isinstance(payload, dict):
            payload = {"message": "响应不是 JSON 对象", "data": payload}
        return status, payload

    def _device_info(self) -> dict[str, Any]:
        identity = self._identity()
        version = self._client_version()
        private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        public_key = private_key.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        ).decode("ascii")
        return {
            "DeviceID": identity["deviceId"],
            "MachineID": identity["machineId"],
            "PlatformCode": "IDE_PC",
            "DeviceType": "PC",
            "DeviceName": identity.get("deviceName", "Linux-PC"),
            "DeviceModel": "Linux",
            "ClientVersion": version,
            "DevicePublicKey": public_key,
            "DeviceBrand": "Generic",
            "DeviceCPU": platform.machine(),
            "OSInfo": platform.system(),
            "OSVersion": f"{platform.system()} {platform.release()}",
        }

    def _exchange_auth_code(self, auth_code: str, code_verifier: str) -> dict[str, Any]:
        status, payload = self._request_json(
            f"{API_HOST}/trae/api/v3/oauth/ExchangeToken",
            body={
                "ClientID": CLIENT_ID,
                "AuthCode": auth_code,
                "CodeVerifier": code_verifier,
                "DeviceInfo": self._device_info(),
                "IDEVersion": self._client_version(),
            },
        )
        result = payload.get("Result") or payload.get("result") or {}
        if status < 200 or status >= 300 or not isinstance(result, dict) or not (result.get("Token") or result.get("token")):
            message = payload.get("message") or payload.get("Message") or f"HTTP {status}"
            raise RuntimeError(f"ExchangeToken 失败: {message}")
        return result

    def _get_user_info(self, token: str) -> dict[str, Any]:
        version = self._client_version()
        status, payload = self._request_json(
            f"{API_HOST}/cloudide/api/v3/trae/GetUserInfo",
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "Authorization": f"Cloud-IDE-JWT {token}",
                "X-Cloudide-Token": token,
            },
            body={"ReqSource": "IDE", "IDEVersion": version},
        )
        if status < 200 or status >= 300:
            raise RuntimeError(f"GetUserInfo 失败: HTTP {status}")
        return payload.get("Result") or payload.get("Data") or payload

    @staticmethod
    def _normalize_expire(raw: Any, duration: Any) -> str:
        try:
            number = float(raw)
            if number > time.time() * 1000:
                return datetime.fromtimestamp(number / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
            if number > 1e12:
                return datetime.fromtimestamp(number / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
        except (TypeError, ValueError):
            pass
        if duration:
            try:
                return datetime.fromtimestamp(time.time() + float(duration), timezone.utc).isoformat().replace("+00:00", "Z")
            except (TypeError, ValueError):
                pass
        if raw:
            try:
                return datetime.fromisoformat(str(raw).replace("Z", "+00:00")).astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
            except Exception:
                pass
        return datetime.fromtimestamp(time.time() + 7200, timezone.utc).isoformat().replace("+00:00", "Z")

    def _build_auth_payload(self, result: dict[str, Any], info: dict[str, Any]) -> dict[str, Any]:
        token = self._pick(result, "Token", "token")
        refresh_token = self._pick(result, "RefreshToken", "refreshToken")
        if not token:
            raise RuntimeError("ExchangeToken 未返回 Token")
        expired_at = self._normalize_expire(self._pick(result, "TokenExpireAt", "tokenExpireAt"), self._pick(result, "TokenExpireDuration", "tokenExpireDuration"))
        refresh_expired_raw = self._pick(result, "RefreshExpireAt", "refreshExpireAt")
        refresh_expired = self._normalize_expire(refresh_expired_raw, None) if refresh_expired_raw else self._normalize_expire(time.time() * 1000 + 365 * 86400000, None)
        user_info = info.get("UserInfo") or info
        user_id = str(self._pick(user_info, "UserID", "userId", "user_id") or self._pick(info, "UserID") or "")
        if not user_id:
            raise RuntimeError("GetUserInfo 未返回 UserID")
        ai_region = self._pick(user_info, "AIRegion", "aiRegion") or self._pick(info, "AIRegion") or "CN"
        return {
            "token": token,
            "refreshToken": refresh_token,
            "expiredAt": expired_at,
            "refreshExpiredAt": refresh_expired,
            "tokenReleaseAt": self._now_iso(),
            "userId": user_id,
            "host": API_HOST,
            "userRegion": {"region": ai_region, "_aiRegion": ai_region},
            "account": {
                "username": self._pick(user_info, "ScreenName", "username") or "",
                "iss": "",
                "iat": 0,
                "organization": self._pick(user_info, "Organization", "organization") or "",
                "work_country": self._pick(user_info, "WorkCountry", "work_country") or "",
                "email": self._pick(user_info, "NonPlainTextEmail", "email") or "",
                "avatar_url": self._pick(user_info, "AvatarUrl", "avatar_url") or "",
                "description": self._pick(user_info, "Description", "description") or "",
                "scope": self._pick(user_info, "Scope", "scope") or "",
                "loginScope": self._pick(user_info, "LoginScope", "loginScope") or "",
                "nonPlainTextMobile": self._pick(user_info, "NonPlainTextMobile") or "",
                "storeCountryCode": self._pick(user_info, "StoreCountryCode") or "",
                "storeCountrySrc": self._pick(user_info, "StoreCountrySrc") or "",
                "storeRegion": self._pick(info, "StoreRegion", "storeRegion") or "",
                "userTag": self._pick(info, "UserTag", "userTag") or "",
                "migrateToSG": bool(self._pick(user_info, "MigrateToSG")),
            },
        }

    def start_login(self, *, label: str = "", timeout: float = 300.0, auto_browser: bool = False) -> dict[str, Any]:
        verifier = secrets.token_urlsafe(48)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode("ascii")
        identity = self._identity()
        version = self._client_version()
        event = threading.Event()
        session: dict[str, Any] = {
            "id": str(uuid.uuid4()),
            "provider": "trae",
            "status": "waiting",
            "message": "等待浏览器授权",
            "account": None,
            "event": event,
            "search": None,
            "server": None,
            "deadline": time.monotonic() + timeout,
            "verifier": verifier,
            "label": label,
        }
        # 回调服务器按会话创建并立即开始监听，确保浏览器回跳时能收到授权码。
        server = HTTPServer(("127.0.0.1", 0), _make_callback_handler(session))
        session["server"] = server
        port = server.server_address[1]
        query = urllib.parse.urlencode(
            {
                "login_version": "1",
                "auth_from": "trae",
                "login_channel": "native_ide",
                "plugin_version": version,
                "auth_type": "local",
                "client_id": CLIENT_ID,
                "redirect": "0",
                "login_trace_id": str(uuid.uuid4()),
                "auth_callback_url": f"http://127.0.0.1:{port}/authorize",
                "machine_id": identity["machineId"],
                "device_id": identity["deviceId"],
                "x_device_id": identity["deviceId"],
                "x_machine_id": identity["machineId"],
                "x_device_brand": "Generic",
                "x_device_type": "linux",
                "x_os_version": f"Linux {platform.release()}",
                "x_env": "",
                "x_app_version": version,
                "x_app_type": "stable",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
            }
        )
        session["auth_url"] = f"{LOGIN_HOST}/authorization?{query}"
        with self._lock:
            self._login_sessions[session["id"]] = session
        if auto_browser:
            import webbrowser
            try:
                webbrowser.open(session["auth_url"])
            except Exception:
                pass
        threading.Thread(target=server.serve_forever, daemon=True).start()
        threading.Thread(target=self._wait_login, args=(session["id"],), daemon=True).start()
        return self.public_login(session)

    def public_login(self, session: dict[str, Any]) -> dict[str, Any]:
        return {key: value for key, value in session.items() if key not in {"event", "search", "server", "deadline", "verifier"}}

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
        try:
            if not session["event"].wait(max(0, session["deadline"] - time.monotonic())):
                raise RuntimeError("等待登录超时")
            session["server"].shutdown()
            session["server"].server_close()
            session["status"] = "exchanging"
            session["message"] = "正在换取登录令牌"
            params = urllib.parse.parse_qs(session["search"] or "")
            error = params.get("error_code") or params.get("error")
            if error:
                raise RuntimeError(f"授权被拒绝: {error[0]} {params.get('error_msg', [''])[0]}")
            auth_code = None
            for key in ["authCodeInfo", "code", "authCode", "AuthCode"]:
                value = params.get(key, [None])[0]
                if not value:
                    continue
                try:
                    parsed = json.loads(value)
                    auth_code = parsed.get("AuthCode") or parsed.get("code")
                except Exception:
                    auth_code = value
                if auth_code:
                    break
            if not auth_code:
                raise RuntimeError("回跳未携带授权码")
            result = self._exchange_auth_code(auth_code, session["verifier"])
            info = self._get_user_info(self._pick(result, "Token", "token"))
            auth = self._build_auth_payload(result, info)
            display_name = auth.get("account", {}).get("username") or auth["userId"]
            credential = self.encrypt(auth)
            db_id = self.store.upsert_account(
                provider="trae",
                external_id=auth["userId"],
                display_name=display_name,
                endpoint=auth["host"],
                credential=credential,
                label=session.get("label", ""),
            )
            self.store.add_log(db_id, "trae", action="login", ok=True, message="Web 登录成功", payload={"display_name": display_name})
            session.update({"status": "success", "message": "登录成功", "account": {"id": db_id, "name": display_name, "external_id": auth["userId"]}})
        except Exception as exc:
            try:
                session["server"].shutdown()
                session["server"].server_close()
            except Exception:
                pass
            session.update({"status": "failed", "message": str(exc)})
        finally:
            with self._lock:
                self._login_sessions[login_id] = session

    def _save_auth(self, row: Any, auth: dict[str, Any]) -> None:
        self.store.update_account(
            int(row["id"]),
            credential=self.encrypt(auth),
            display_name=auth.get("account", {}).get("username") or None,
        )

    def _refresh(self, auth: dict[str, Any]) -> bool:
        if not auth.get("refreshToken"):
            return False
        status, payload = self._request_json(
            f"{auth.get('host') or API_HOST}/cloudide/api/v3/trae/oauth/ExchangeToken",
            body={
                "ClientID": CLIENT_ID,
                "RefreshToken": auth["refreshToken"],
                "ClientSecret": "-",
                "UserID": str(auth.get("userId") or ""),
            },
        )
        result = payload.get("Result") or payload.get("result") or {}
        token = self._pick(result, "Token", "token")
        if status < 200 or status >= 300 or not token:
            return False
        auth["token"] = token
        new_refresh_token = self._pick(result, "RefreshToken", "refreshToken")
        if new_refresh_token:
            auth["refreshToken"] = new_refresh_token
        if self._pick(result, "TokenExpireAt", "tokenExpireAt") or self._pick(result, "TokenExpireDuration", "tokenExpireDuration"):
            auth["expiredAt"] = self._normalize_expire(
                self._pick(result, "TokenExpireAt", "tokenExpireAt"),
                self._pick(result, "TokenExpireDuration", "tokenExpireDuration"),
            )
        return True

    def _ensure_fresh(self, auth: dict[str, Any]) -> dict[str, Any]:
        expired_at = 0
        if auth.get("expiredAt"):
            try:
                expired_at = datetime.fromisoformat(str(auth["expiredAt"]).replace("Z", "+00:00")).timestamp() * 1000
            except Exception:
                expired_at = 0
        if not expired_at or expired_at - time.time() * 1000 < 30 * 60 * 1000:
            self._refresh(auth)
        return auth

    def _load_auth(self, row: Any) -> dict[str, Any]:
        auth = self.decrypt(row["credential"])
        auth["host"] = auth.get("host") or row["endpoint"] or API_HOST
        return self._ensure_fresh(auth)

    @staticmethod
    def _device_id() -> str:
        return str(int(time.time() * 1000)) + str(secrets.randbelow(90) + 10)

    def _headers(self, auth: dict[str, Any]) -> dict[str, str]:
        identity = self._identity()
        version = self._client_version()
        system = platform.system().lower()
        device_type = {"linux": "linux", "darwin": "mac", "windows": "windows"}.get(system, "unknown")
        return {
            "Authorization": f"Cloud-IDE-JWT {auth['token']}",
            "X-Cloudide-Token": auth["token"],
            "x-uid": str(auth.get("userId") or ""),
            "x-app-id": "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8",
            "x-device-id": self._device_id(),
            "x-machine-id": identity["machineId"],
            "x-request-id": str(uuid.uuid4()),
            "x-ide-version": version,
            "x-ide-version-code": version.replace(".", "") or version,
            "x-device-type": device_type,
            "x-os-version": f"{platform.system()} {platform.release()}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _post(
        self,
        row: Any,
        auth: dict[str, Any],
        path: str,
        body: dict[str, Any] | None = None,
        *,
        header_overrides: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, Any]]:
        url = f"{auth['host']}{path}"
        headers = {**self._headers(auth), **(header_overrides or {})}
        status, payload = self._request_json(url, headers=headers, body=body or {})
        if status == 401:
            if self._refresh(auth):
                headers = {**self._headers(auth), **(header_overrides or {})}
                status, payload = self._request_json(url, headers=headers, body=body or {})
        return status, payload

    def _usage_request(self, auth: dict[str, Any]) -> dict[str, Any]:
        status, payload = self._post(
            None,
            auth,
            "/trae/api/v2/pay/ide_user_ent_usage",
            {"require_usage": True, "req_source": 1},
        )
        if status != 200 or (payload.get("code") is not None and payload.get("code") != 0):
            message = payload.get("message") or payload.get("Message") or f"HTTP {status}"
            raise RuntimeError(f"查询真实余额失败: {message}")

        packs = payload.get("user_entitlement_pack_list") or []
        total = 0.0
        used = 0.0
        unlimited = False
        packages: list[dict[str, Any]] = []
        for raw in packs:
            if not isinstance(raw, dict):
                continue
            quota = ((raw.get("entitlement_base_info") or {}).get("quota") or {})
            usage = raw.get("usage") or {}
            limit = quota.get("credits_limit")
            amount = usage.get("credits_amount") or 0
            try:
                amount = max(0.0, float(amount))
            except (TypeError, ValueError):
                amount = 0.0
            if limit == -1:
                unlimited = True
            elif isinstance(limit, (int, float)) and limit > 0:
                limit = float(limit)
                total += limit
            if limit != 0:
                used += amount
            packages.append({"limit": limit, "used": amount})

        if unlimited:
            credits_total = -1
            credits_left = -1
        else:
            credits_total = int(total) if total.is_integer() else round(total, 6)
            credits_left = int(max(0.0, total - used)) if (total - used).is_integer() else round(max(0.0, total - used), 6)
        credits_used = int(used) if used.is_integer() else round(used, 6)
        return {
            "source": "ide_user_ent_usage",
            "isCreditsBilling": payload.get("is_credits_billing") is True,
            "creditsTotal": credits_total,
            "creditsLeft": credits_left,
            "creditsUsed": credits_used,
            "unlimited": unlimited,
            "packCount": len(packages),
            "packages": packages,
        }

    @staticmethod
    def _merge_usage(checkin_status: dict[str, Any], usage: dict[str, Any]) -> dict[str, Any]:
        return {
            **checkin_status,
            "usage": usage,
            "credits_left": usage["creditsLeft"],
            "credits_total": usage["creditsTotal"],
        }

    def _fetch_status(self, row: Any) -> tuple[dict[str, Any], dict[str, Any]]:
        auth = self._load_auth(row)
        status, payload = self._post(row, auth, "/trae/api/v2/ug/checkin_credits/status")
        if status != 200 or payload.get("code") != 0:
            message = payload.get("message") or f"HTTP {status}"
            raise RuntimeError(f"查询签到状态失败: {message}")
        usage = self._usage_request(auth)
        return self._merge_usage(payload, usage), auth

    def status(self, row: Any) -> dict[str, Any]:
        result, auth = self._fetch_status(row)
        self._save_auth(row, auth)
        self.store.update_status(int(row["id"]), result)
        return result

    def checkin(self, row: Any) -> dict[str, Any]:
        status_payload, auth = self._fetch_status(row)
        if status_payload.get("checked_in"):
            result = {"action": "already", "ok": True, "message": "今日已签到", "status": status_payload}
        else:
            status, claim_payload = self._post(row, auth, "/trae/api/v2/ug/checkin_credits/claim")
            if status != 200 or claim_payload.get("code") != 0:
                message = claim_payload.get("message") or f"HTTP {status}"
                result = {"action": "claim", "ok": False, "message": f"签到失败: {message}", "claim": claim_payload, "status": status_payload}
            else:
                gained = self._pick(claim_payload, "gained_credits", "credits_gained", "reward", "credits")
                result = {"action": "claim", "ok": True, "message": "签到成功", "credits": gained, "claim": claim_payload, "status": status_payload}
            _, status_after = self._fetch_status(row)
            status_payload = status_after
            result["status"] = status_payload
        self._save_auth(row, auth)
        self.store.update_status(int(row["id"]), status_payload)
        self.store.update_checkin(int(row["id"]), ok=result["ok"], message=result["message"])
        self.store.add_log(
            int(row["id"]), "trae", action=result["action"], ok=result["ok"], message=result["message"], payload=result
        )
        return result

    def import_from_desktop(self) -> list[int]:
        home = Path.home()
        roots = [home / ".config", home / "Library" / "Application Support"]
        names = ["Trae CN", "TRAE SOLO CN", "Trae", "TRAE SOLO"]
        imported: list[int] = []
        for root in roots:
            for name in names:
                path = root / name / "User" / "globalStorage" / "storage.json"
                try:
                    storage = json.loads(path.read_text(encoding="utf-8"))
                    raw = storage.get(AUTH_KEY)
                    if not raw:
                        continue
                    auth = json.loads(raw) if str(raw).strip().startswith("{") else self.decrypt(raw)
                    display_name = auth.get("account", {}).get("username") or auth.get("userId")
                    imported.append(
                        self.store.upsert_account(
                            provider="trae",
                            external_id=str(auth["userId"]),
                            display_name=str(display_name),
                            endpoint=auth.get("host") or API_HOST,
                    credential=self.encrypt(auth),
                        )
                    )
                except Exception:
                    continue
        return imported

    def import_from_legacy(self, legacy_db: str | Path | None = None) -> list[int]:
        import sqlite3

        raw_legacy_db = legacy_db or os.environ.get("TRAE_LEGACY_DB") or Path.home() / ".trae-checkin" / "trae_checkin.db"
        conn = sqlite3.connect(raw_legacy_db)
        conn.row_factory = sqlite3.Row
        imported: list[int] = []
        for row in conn.execute("SELECT id,user_id,username,host,auth_enc,enabled FROM accounts").fetchall():
            try:
                auth = self.decrypt(row["auth_enc"])
                imported.append(
                    self.store.upsert_account(
                        provider="trae",
                        external_id=str(auth.get("userId") or row["user_id"]),
                        display_name=auth.get("account", {}).get("username") or row["username"] or str(auth.get("userId")),
                        endpoint=auth.get("host") or row["host"] or API_HOST,
                        credential=self.encrypt(auth),
                    )
                )
            except Exception:
                continue
        conn.close()
        return imported
