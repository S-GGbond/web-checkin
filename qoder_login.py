#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Qoder 登录执行脚本（设备码 + PKCE S256）

流程：
  1. 本地生成 verifier / challenge / nonce
  2. 拼 qoder.cn/users/sign-in 登录 URL，浏览器完成网页登录
  3. 轮询 openapi /api/v1/deviceToken/poll 换取 token
  4. GET /api/v1/userinfo 取用户信息
  5. 落盘 qoder_auth.json（供签到执行脚本使用）

用法：
  python3 login.py                 # 打开浏览器并轮询
  python3 login.py --no-open       # 只打印登录 URL
  python3 login.py --direct        # 跳过 /users/sign-in 直达设备码页
"""

import argparse
import base64
import hashlib
import json
import os
import platform
import secrets
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from pathlib import Path

AUTH_BASE = "https://qoder.cn"
OPENAPI_BASE = "https://openapi.qoder.com.cn"
CLIENT_ID = "732aef47-9cf2-46a2-95fe-4cebb5d0d1fa"
BIZ_VARIANT = "qoder"

CLIENT_TYPE = "10"        # 客户端常量 clientType:10
CLIENT_VERSION = "0.3.4"  # 客户端版本

# 登录态保存在用户数据目录，避免凭据被误放进 Git 工作区。
DATA_DIR = Path(os.environ.get("QODER_DATA_DIR", str(Path.home() / ".qoder-checkin"))).expanduser()
AUTH_FILE = DATA_DIR / "qoder_auth.json"
MACHINE_ID_FILE = DATA_DIR / "machine_id.txt"


def set_data_dir(path: str | Path) -> None:
    """设置登录态目录；供 Web Hub 或测试显式隔离数据。"""
    global DATA_DIR, AUTH_FILE, MACHINE_ID_FILE
    DATA_DIR = Path(path).expanduser()
    AUTH_FILE = DATA_DIR / "qoder_auth.json"
    MACHINE_ID_FILE = DATA_DIR / "machine_id.txt"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def machine_os() -> str:
    """复刻客户端 eXe(): `<arch>_<platform>`，x64->x86_64 / arm64->aarch64"""
    arch = platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(arch, arch)
    return f"{arch}_{platform.system().lower()}"


def load_machine_id() -> str:
    """复刻 auth.machine-id：文件存在则用，否则随机 UUID 落盘"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if MACHINE_ID_FILE.exists():
        mid = MACHINE_ID_FILE.read_text().strip()
        if mid:
            return mid
    mid = str(uuid.uuid4())
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    MACHINE_ID_FILE.write_text(mid + "\n")
    try:
        MACHINE_ID_FILE.chmod(0o600)
    except OSError:
        pass
    return mid


def build_headers(token: str | None = None) -> dict:
    """请求头契约：Authorization + Cosy-* + User-Agent: Qoder

    Cosy-MachineToken / MachineCode / MachineType 由阿里 UMID 风控子进程
    （resources/umid/runtime-info）生成，服务端为可选项，这里不带。
    """
    h = {
        "Accept": "application/json",
        "User-Agent": "Qoder",
        "Cosy-ClientType": CLIENT_TYPE,
        "Cosy-Version": CLIENT_VERSION,
        "Cosy-MachineOS": machine_os(),
        "Cosy-MachineId": load_machine_id(),
    }
    host = socket.gethostname()
    if host.isascii() and host.isprintable() and len(host) <= 96:
        h["Cosy-MachineHostname"] = host
    if token:
        h["Authorization"] = f"Bearer {token}"
    return h


def http(method: str, url: str, hdr: dict, body=None, timeout: float = 20):
    """返回 (status, text)，HTTP 错误也走返回值而不是异常"""
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        hdr = {**hdr, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def gen_verifier(n: int = 64) -> str:
    """客户端 $je(): 从 A-Za-z0-9-._~ 取 n 个字符"""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    rnd = secrets.token_bytes(n)
    return "".join(alphabet[b % len(alphabet)] for b in rnd)


def build_login_url(challenge: str, nonce: str, machine_id: str, direct: bool) -> str:
    inner_qs = urllib.parse.urlencode({
        "challenge": challenge,
        "challenge_method": "S256",
        "nonce": nonce,
        "machine_id": machine_id,
        "client_id": CLIENT_ID,
    })
    select_url = f"{AUTH_BASE}/device/selectAccounts?{inner_qs}"
    if direct:
        return select_url
    outer_qs = urllib.parse.urlencode({
        "biz_variant": BIZ_VARIANT,
        "oauth_callback": select_url,
    })
    return f"{AUTH_BASE}/users/sign-in?{outer_qs}"


def wait_for_token(nonce: str, verifier: str, interval: float, timeout: float) -> dict:
    """GET /api/v1/deviceToken/poll：404=未完成继续，成功返回 token+refresh_token"""
    qs = urllib.parse.urlencode({
        "nonce": nonce,
        "verifier": verifier,
        "challenge_method": "S256",
    })
    url = f"{OPENAPI_BASE}/api/v1/deviceToken/poll?{qs}"
    hdr = {"Accept": "application/json", "User-Agent": "Qoder"}
    deadline = time.time() + timeout
    fails = 0
    while time.time() < deadline:
        try:
            status, text = http("GET", url, hdr, timeout=10)
            fails = 0
            if status == 200:
                d = json.loads(text)
                if isinstance(d.get("token"), str) and isinstance(d.get("refresh_token"), str):
                    return d
            # 404 / 其它：网页登录尚未完成，继续轮询
        except Exception as e:  # 网络层错误才到这里
            fails += 1
            print(f"  轮询网络异常({fails}/5): {e}", file=sys.stderr)
            if fails >= 5:
                raise RuntimeError("网络连续失败 5 次，终止轮询")
        time.sleep(interval)
    raise TimeoutError("轮询超时：网页登录未在时限内完成")


def load_auth() -> dict:
    """读取登录态；文件不存在时抛出可读错误。"""
    if not AUTH_FILE.exists():
        raise RuntimeError(f"未找到 Qoder 登录态文件: {AUTH_FILE}，请先执行 python3 qoder_login.py")
    return json.loads(AUTH_FILE.read_text(encoding="utf-8"))


def save_auth(data: dict) -> None:
    """保存登录态，目录和文件权限都限制在本机用户。"""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    AUTH_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    try:
        AUTH_FILE.chmod(0o600)
    except OSError:
        pass


def pick_expiry(d: dict, at_key: str, in_key: str) -> float:
    """兼容 expires_at（ISO 字符串 / 秒 / 毫秒）与 expires_in（相对秒）多种返回"""
    from datetime import datetime
    v = d.get(at_key)
    if v is not None:
        if isinstance(v, str):
            # 形如 2026-11-09T08:06:06Z
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        v = float(v)
        if v > 1e12:  # 毫秒
            v /= 1000.0
        return v
    v = d.get(in_key)
    if v is not None:
        return time.time() + float(v)
    return time.time() + 7200  # 客户端未给过期时间时的兜底


def fetch_userinfo(token: str) -> dict:
    status, text = http("GET", f"{OPENAPI_BASE}/api/v1/userinfo", build_headers(token))
    if status != 200:
        print(f"  userinfo 返回 {status}: {text[:200]}", file=sys.stderr)
        return {}
    return json.loads(text)


def main() -> int:
    ap = argparse.ArgumentParser(description="Qoder 登录执行脚本")
    ap.add_argument("--no-open", action="store_true", help="只打印登录 URL，不自动打开浏览器")
    ap.add_argument("--direct", action="store_true", help="跳过 /users/sign-in 包装直达设备码页")
    ap.add_argument("--timeout", type=int, default=300, help="轮询总超时秒数（默认 300，与客户端一致）")
    ap.add_argument("--interval", type=float, default=1.0, help="轮询间隔秒数（默认 1）")
    args = ap.parse_args()

    verifier = gen_verifier(64)
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    nonce = str(uuid.uuid4())
    machine_id = load_machine_id()

    login_url = build_login_url(challenge, nonce, machine_id, args.direct)

    print("=== Qoder 登录 ===")
    print(f"[1/4] 已生成 PKCE 参数（machine_id={machine_id}）")
    print("[2/4] 请在浏览器完成登录：")
    print(login_url)
    if not args.no_open:
        webbrowser.open(login_url)

    print(f"[3/4] 开始轮询 deviceToken/poll（{args.interval}s 间隔，{args.timeout}s 超时）...")
    try:
        tok = wait_for_token(nonce, verifier, args.interval, args.timeout)
    except (TimeoutError, RuntimeError) as e:
        print(f"登录失败：{e}", file=sys.stderr)
        return 1

    token = tok["token"]
    refresh_token = tok["refresh_token"]
    user = fetch_userinfo(token)

    data = {
        "schemaVersion": 1,
        "token": token,
        "refreshToken": refresh_token,
        "expiresAt": pick_expiry(tok, "expires_at", "expires_in"),
        "refreshTokenExpiresAt": pick_expiry(tok, "refresh_token_expires_at", "refresh_token_expires_in"),
        "machineId": machine_id,
        "user": user,
        "savedAt": time.time(),
    }
    save_auth(data)

    name = user.get("name") or user.get("username") or user.get("user_name") or ""
    uid = user.get("id") or user.get("user_id") or user.get("uid") or ""
    print("[4/4] 登录成功，凭据已保存")
    print(f"  账号: {name or '(未返回)'}  uid: {uid or '(未返回)'}")
    print(f"  token 有效期至: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(data['expiresAt']))}")
    print(f"  已写入: {AUTH_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
