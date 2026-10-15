#!/usr/bin/env python3
"""WorkBuddy 登录脚本：只做浏览器授权、获取令牌并写入 SQLite。"""

from __future__ import annotations

import argparse
import sys
import time
import urllib.parse
import webbrowser

from .workbuddy_common import (
    DEFAULT_DB,
    DEFAULT_ENDPOINT,
    DEFAULT_HTTP_TIMEOUT,
    PENDING_ACCOUNT_CODE,
    PENDING_TOKEN_CODE,
    WorkBuddyError,
    calculate_expiry,
    choose_account,
    endpoint_origin,
    fetch_account_snapshot,
    init_db,
    request_json,
    save_session,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WorkBuddy 登录并保存 SQLite 登录态")
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite 数据库路径，默认 {DEFAULT_DB}")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help=f"API endpoint，默认 {DEFAULT_ENDPOINT}")
    parser.add_argument("--platform", default="workbuddy", help="登录平台参数，默认 workbuddy")
    parser.add_argument("--label", default="", help="账号备注")
    parser.add_argument("--login-timeout", type=float, default=600, help="等待登录完成秒数")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="轮询间隔秒数")
    parser.add_argument("--http-timeout", type=float, default=DEFAULT_HTTP_TIMEOUT, help="单次 HTTP 超时秒数")
    parser.add_argument("--no-browser", action="store_true", help="不自动打开浏览器，只打印链接")
    return parser


def run_login(args: argparse.Namespace) -> int:
    endpoint = args.endpoint
    status, payload = request_json(
        endpoint,
        "POST",
        f"/v2/plugin/auth/state?platform={urllib.parse.quote(args.platform)}",
        body={},
        timeout=args.http_timeout,
    )
    auth_state = payload.get("data") if isinstance(payload.get("data"), dict) else None
    if status != 200 or payload.get("code") != 0 or not auth_state:
        raise WorkBuddyError(f"申请登录 state 失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
    if not auth_state.get("state") or not auth_state.get("authUrl"):
        raise WorkBuddyError("登录 state 响应缺少 state/authUrl")

    print("请在浏览器中完成登录：")
    print(auth_state["authUrl"])
    if not args.no_browser:
        try:
            webbrowser.open(auth_state["authUrl"])
        except Exception:
            print("自动打开浏览器失败，请手动复制上方链接。")

    deadline = time.monotonic() + args.login_timeout
    auth = None
    while time.monotonic() < deadline:
        time.sleep(args.poll_interval)
        status, payload = request_json(
            endpoint,
            "GET",
            f"/v2/plugin/auth/token?state={urllib.parse.quote(str(auth_state['state']))}",
            timeout=args.http_timeout,
        )
        if isinstance(payload.get("data"), dict) and payload["data"].get("accessToken"):
            auth = calculate_expiry(payload["data"])
            break
        if int(payload.get("code") or 0) == PENDING_TOKEN_CODE:
            print("等待登录授权...")
            continue
        raise WorkBuddyError(f"获取登录令牌失败: HTTP {status} code={payload.get('code')} msg={payload.get('msg')}")
    if not auth:
        raise WorkBuddyError("等待登录超时")

    account_path = f"/v2/plugin/login/account?state={urllib.parse.quote(str(auth_state['state']))}"
    account_payload = {}
    account_status = 0
    auth_retries = 0
    deadline = time.monotonic() + min(args.login_timeout, 120)
    while time.monotonic() < deadline:
        time.sleep(args.poll_interval)
        account_status, account_payload = request_json(
            endpoint,
            "GET",
            account_path,
            token=auth.get("accessToken"),
            account={"domain": auth.get("domain")},
            timeout=args.http_timeout,
        )
        code = int(account_payload.get("code") or 0)
        if code == PENDING_ACCOUNT_CODE:
            print("等待账号信息...")
            continue
        if account_status in {401, 403} and auth_retries < 3:
            auth_retries += 1
            continue
        break
    account = account_payload.get("data") if isinstance(account_payload, dict) else None
    if account_status != 200 or account_payload.get("code") != 0 or not isinstance(account, dict):
        raise WorkBuddyError(
            f"获取账号失败: HTTP {account_status} code={account_payload.get('code')} msg={account_payload.get('msg')}"
        )

    snapshot = fetch_account_snapshot(endpoint, auth, args.http_timeout)
    account = choose_account(account, snapshot)
    conn = init_db(args.db)
    try:
        session_id = save_session(conn, endpoint, auth, account, snapshot, args.label)
    finally:
        conn.close()
    print(f"登录成功：{account.get('nickname') or account.get('displayName') or account.get('uid')} -> session_id={session_id}")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_login(args)
    except KeyboardInterrupt:
        print("已取消", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
