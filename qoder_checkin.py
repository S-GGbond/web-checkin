#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Qoder 独立签到脚本。

用法：
  python3 qoder_checkin.py            # 拉取活动并领取可领取项
  python3 qoder_checkin.py --list     # 只查看活动状态，不执行领取

登录态读取 `QODER_DATA_DIR/qoder_auth.json`，该文件由 `qoder_login.py` 生成。
"""

import argparse
import sys

import qoder_login

OPENAPI_BASE = qoder_login.OPENAPI_BASE
build_headers = qoder_login.build_headers
http = qoder_login.http
pick_expiry = qoder_login.pick_expiry
save_auth = qoder_login.save_auth
load_auth = qoder_login.load_auth
EXPIRY_MARGIN = 60  # access token 到期前 60 秒视为需要续期


def refresh(auth: dict) -> dict:
    """刷新 access token，并把轮换后的 refreshToken 回写到本地数据文件。"""
    url = f"{OPENAPI_BASE}/api/v1/deviceToken/refresh"
    headers = {"Accept": "application/json", "User-Agent": "Qoder"}
    status, text = http(
        "POST", url, headers, body={"refresh_token": auth["refreshToken"]}
    )
    if status != 200:
        raise RuntimeError(f"续期失败 HTTP {status}: {text[:300]}")

    import json

    payload = json.loads(text)
    auth["token"] = payload.get("device_token") or payload.get("token") or auth["token"]
    auth["refreshToken"] = payload.get("refresh_token") or auth["refreshToken"]
    auth["expiresAt"] = pick_expiry(payload, "expires_at", "expires_in")
    auth["refreshTokenExpiresAt"] = pick_expiry(
        payload, "refresh_token_expires_at", "refresh_token_expires_in"
    )
    auth["savedAt"] = __import__("time").time()
    save_auth(auth)
    return auth


def ensure_token(auth: dict) -> dict:
    """确保 access token 可用；refresh token 过期则要求重新登录。"""
    import time

    now = time.time()
    if now >= auth.get("refreshTokenExpiresAt", 0):
        print("refresh_token 已过期，请重新登录：python3 qoder_login.py", file=sys.stderr)
        raise SystemExit(1)
    if now >= auth.get("expiresAt", 0) - EXPIRY_MARGIN:
        print("[1/3] access_token 已过期，正在续期...")
        auth = refresh(auth)
        print("  续期成功，新 token 已回写")
    else:
        print("[1/3] token 有效，无需续期")
    return auth


def list_campaigns(auth: dict) -> tuple[dict, dict]:
    """拉取当前账号的签到活动列表；遇到 401 会先续期再重试。"""
    import json

    url = f"{OPENAPI_BASE}/sash/api/v1/me/campaigns"
    status, text = http("GET", url, build_headers(auth["token"]))
    if status == 401:
        print("  campaigns 返回 401，先续期后重试...")
        auth = refresh(auth)
        status, text = http("GET", url, build_headers(auth["token"]))
    if status != 200:
        raise RuntimeError(f"拉取活动失败 HTTP {status}: {text[:300]}")
    return json.loads(text), auth


def claim(auth: dict, campaign_id: str) -> tuple[int, str]:
    """领取指定活动，返回 HTTP 状态码和响应文本。"""
    url = f"{OPENAPI_BASE}/sash/api/v1/me/campaigns/{campaign_id}/claim"
    return http("POST", url, build_headers(auth["token"]))


def main() -> int:
    parser = argparse.ArgumentParser(description="Qoder 独立签到脚本")
    parser.add_argument("--list", action="store_true", help="只列出活动状态，不领取")
    args = parser.parse_args()

    print("=== Qoder 签到 ===")
    auth = ensure_token(load_auth())

    print("[2/3] 拉取活动列表 GET /sash/api/v1/me/campaigns ...")
    payload, auth = list_campaigns(auth)
    campaigns = payload.get("campaigns") or []
    user = auth.get("user") or {}
    name = user.get("name") or user.get("username") or ""
    print(f"  uid={payload.get('uid', '')} 账号={name or '(未知)'} 活动数={len(campaigns)}")

    claimable = []
    for item in campaigns:
        benefit = item.get("benefit") or {}
        print(
            f"  - {item.get('campaignKey', '')} [{item.get('actionType', '')}] "
            f"{item.get('claimStatus', '')} "
            f"({benefit.get('kind', '')} x{benefit.get('amount', '')})"
        )
        if item.get("claimStatus") == "CLAIMABLE":
            claimable.append(item)

    if args.list:
        print("[3/3] --list 模式，不执行领取")
        return 0

    if not claimable:
        print("[3/3] 当前没有可领取活动")
        return 0

    print(f"[3/3] 可领取活动 {len(claimable)} 个，开始领取...")
    succeeded = 0
    for item in claimable:
        campaign_id = item["campaignId"]
        status, text = claim(auth, campaign_id)
        benefit = item.get("benefit") or {}
        tag = f"{benefit.get('kind', '')} x{benefit.get('amount', '')}"
        if status == 200:
            succeeded += 1
            print(f"  领取成功 {item.get('campaignKey', campaign_id)} ({tag})")
        else:
            print(
                f"  领取失败 {item.get('campaignKey', campaign_id)} HTTP {status}: {text[:200]}",
                file=sys.stderr,
            )

    print(f"运行结果：成功 {succeeded}/{len(claimable)}")
    return 0 if succeeded == len(claimable) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        raise SystemExit(1)
