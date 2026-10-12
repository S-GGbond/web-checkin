#!/usr/bin/env python3
"""WorkBuddy 签到脚本：只做批量状态查询和每日签到，不发起登录。"""

from __future__ import annotations

import argparse
import json
import os
import sys

from workbuddy_common import (
    DEFAULT_DB,
    DEFAULT_ENDPOINT,
    DEFAULT_HTTP_TIMEOUT,
    WorkBuddyError,
    add_log,
    call_with_auth_retry,
    claim_daily_checkin,
    display_name,
    ensure_session,
    get_checkin_status,
    get_real_balance,
    init_db,
    list_sessions,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="WorkBuddy 批量签到；登录态必须已由 workbuddy_login.py 保存")
    parser.add_argument("--db", default=DEFAULT_DB, help=f"SQLite 数据库路径，默认 {DEFAULT_DB}")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help=f"API endpoint，默认 {DEFAULT_ENDPOINT}")
    parser.add_argument("--http-timeout", type=float, default=DEFAULT_HTTP_TIMEOUT, help="单次 HTTP 超时秒数")
    parser.add_argument(
        "--device-token",
        default=os.environ.get("WORKBUDDY_DEVICE_TOKEN"),
        help="可选风控设备令牌；默认读取环境变量 WORKBUDDY_DEVICE_TOKEN",
    )
    parser.add_argument("--dry-run", action="store_true", help="只查询状态，不执行领取")
    parser.add_argument("account_ids", nargs="*", help="只签到指定 uid；缺省为全部启用账号")
    return parser


def run_checkin(args: argparse.Namespace) -> int:
    conn = init_db(args.db)
    failed = False
    try:
        rows = list_sessions(conn, args.account_ids)
        if not rows:
            print("没有可用账号；请先运行 workbuddy_login.py")
            return 1

        for row in rows:
            try:
                row = ensure_session(conn, row, args.endpoint)
                row, status = call_with_auth_retry(
                    conn,
                    row,
                    args.endpoint,
                    lambda current_row: get_checkin_status(args.endpoint, current_row, args.device_token, args.http_timeout),
                    args.device_token,
                    args.http_timeout,
                )
                row, balance = call_with_auth_retry(
                    conn,
                    row,
                    args.endpoint,
                    lambda current_row: get_real_balance(args.endpoint, current_row, args.http_timeout),
                    args.device_token,
                    args.http_timeout,
                )
            except Exception as exc:
                failed = True
                print(f"[FAIL] {display_name(row)} {exc}")
                add_log(conn, row["id"], "checkin", False, message=str(exc))
                continue

            if not status.get("active"):
                print(f"[SKIP] {display_name(row)} 签到活动未开启")
                print(f"       真实余额={balance['creditsLeft']}/{balance['creditsTotal']}")
                add_log(conn, row["id"], "checkin", True, 0, "activity_inactive", {**status, "balance": balance})
                continue
            if status.get("today_checked_in"):
                print(f"[SKIP] {display_name(row)} 今日已签到")
                print(f"       真实余额={balance['creditsLeft']}/{balance['creditsTotal']}")
                add_log(conn, row["id"], "checkin", True, 0, "already_signed", {**status, "balance": balance})
                continue
            if args.dry_run:
                print(f"[DRY] {display_name(row)} 未签到，未执行领取")
                print(f"      真实余额={balance['creditsLeft']}/{balance['creditsTotal']}")
                add_log(conn, row["id"], "checkin", True, 0, "dry_run", {**status, "balance": balance})
                continue

            try:
                _, claimed = call_with_auth_retry(
                    conn,
                    row,
                    args.endpoint,
                    lambda current_row: claim_daily_checkin(args.endpoint, current_row, args.device_token, args.http_timeout),
                    args.device_token,
                    args.http_timeout,
                )
                row, status_after = call_with_auth_retry(
                    conn,
                    row,
                    args.endpoint,
                    lambda current_row: get_checkin_status(args.endpoint, current_row, args.device_token, args.http_timeout),
                    args.device_token,
                    args.http_timeout,
                )
                _, balance_after = call_with_auth_retry(
                    conn,
                    row,
                    args.endpoint,
                    lambda current_row: get_real_balance(args.endpoint, current_row, args.http_timeout),
                    args.device_token,
                    args.http_timeout,
                )
                message = str(claimed.get("msg") or "领取成功")
                print(
                    f"[OK] {display_name(row)} {message} "
                    f"streak={status_after.get('streak_days')} "
                    f"balance={balance_after['creditsLeft']}/{balance_after['creditsTotal']}"
                )
                add_log(
                    conn,
                    row["id"],
                    "checkin",
                    True,
                    int(claimed.get("code") or 0),
                    message,
                    {"claim": claimed, "status": status_after, "balance": balance_after},
                )
            except Exception as exc:
                failed = True
                print(f"[FAIL] {display_name(row)} {exc}")
                add_log(conn, row["id"], "checkin", False, message=str(exc))
    finally:
        conn.close()
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run_checkin(args)
    except KeyboardInterrupt:
        print("已取消", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
