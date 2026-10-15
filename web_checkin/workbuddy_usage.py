#!/usr/bin/env python3
"""查询 WorkBuddy 网页端积分消耗明细。"""

from __future__ import annotations

import argparse
import csv
import getpass
import json
import sys
import urllib.error
import urllib.request
from datetime import date, datetime
from typing import Any, TextIO


API_URL = "https://www.workbuddy.cn/billing/meter/get-user-request-usage"
REFERER = "https://www.workbuddy.cn/profile/plans-usage"
PAGE_SIZE = 1000
MAX_PAGES = 100
MAX_RANGE_DAYS = 31
FIELDS = ("requestTime", "requestName", "model", "client", "credit")


def validate_range(start: str, end: str) -> tuple[date, date]:
    try:
        start_date = date.fromisoformat(start)
        end_date = date.fromisoformat(end)
    except ValueError as exc:
        raise ValueError("日期格式须为 YYYY-MM-DD") from exc
    if start_date.isoformat() != start or end_date.isoformat() != end:
        raise ValueError("日期格式须为 YYYY-MM-DD")
    if start_date > end_date:
        raise ValueError("开始日期不能晚于结束日期")
    if (end_date - start_date).days >= MAX_RANGE_DAYS:
        raise ValueError(f"单次查询最多 {MAX_RANGE_DAYS} 天")
    return start_date, end_date


def _default_user_agent() -> str:
    return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36"


def _unwrap(payload: Any) -> tuple[list[dict[str, Any]], int | None]:
    root = payload.get("data", payload) if isinstance(payload, dict) else {}
    if isinstance(root, list):
        records = root
        total = None
    elif isinstance(root, dict):
        raw_records = next(
            (root.get(key) for key in ("data", "list", "records", "rows", "items") if isinstance(root.get(key), list)),
            None,
        )
        records = raw_records if isinstance(raw_records, list) else []
        raw_total = root.get("total", root.get("totalCount", root.get("count")))
        try:
            total = int(raw_total) if raw_total is not None else None
        except (TypeError, ValueError):
            total = None
    else:
        records, total = [], None
    return [item for item in records if isinstance(item, dict)], total


def _normalize(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "requestTime": record.get("requestTime") or record.get("request_time") or record.get("time") or record.get("createdAt") or "",
        "requestName": record.get("requestName") or record.get("request_name") or record.get("name") or record.get("title") or "",
        "model": record.get("model") or record.get("modelName") or "未标记",
        "client": record.get("client") or record.get("clientName") or "未标记",
        "credit": record.get("credit", record.get("credits", record.get("usage", 0))),
    }


def fetch_usage(
    start: str,
    end: str,
    cookie: str,
    *,
    user_agent: str | None = None,
    page_size: int = PAGE_SIZE,
    opener: Any = urllib.request.urlopen,
) -> list[dict[str, Any]]:
    validate_range(start, end)
    cookie = cookie.strip()
    if not cookie or "\r" in cookie or "\n" in cookie:
        raise ValueError("Cookie 不能为空，且不能包含换行")
    if not 1 <= page_size <= PAGE_SIZE:
        raise ValueError(f"page_size 须在 1 到 {PAGE_SIZE} 之间")

    agent = user_agent or _default_user_agent()
    records: list[dict[str, Any]] = []
    for page in range(1, MAX_PAGES + 1):
        body = {
            "startTime": f"{start} 00:00:00",
            "endTime": f"{end} 23:59:59",
            "pageNum": page,
            "pageSize": page_size,
        }
        request = urllib.request.Request(
            API_URL,
            data=json.dumps(body, separators=(",", ":")).encode("utf-8"),
            headers={
                "Accept": "application/json, text/plain, */*",
                "Content-Type": "application/json",
                "Cookie": cookie,
                "Origin": "https://www.workbuddy.cn",
                "Referer": REFERER,
                "User-Agent": agent,
                "X-Client-Platform": "web",
            },
            method="POST",
        )
        try:
            with opener(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8", "replace") or "{}")
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"用量接口请求失败：HTTP {exc.code}，请检查 Cookie 是否有效及浏览器版本是否匹配") from None
        except (OSError, TimeoutError):
            raise RuntimeError("用量接口网络请求失败，请检查网络后重试") from None
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("用量接口返回内容不是有效 JSON，登录态可能已失效") from exc

        if not isinstance(payload, dict):
            raise RuntimeError("用量接口返回格式异常")
        code = payload.get("code")
        if code is not None and str(code) not in {"0", "200"}:
            message = payload.get("message") or payload.get("msg") or f"错误码 {code}"
            raise RuntimeError(f"用量接口返回错误：{message}")
        page_records, total = _unwrap(payload)
        records.extend(_normalize(item) for item in page_records)
        if len(page_records) < page_size or (total is not None and len(records) >= total):
            return records
    raise RuntimeError(f"超过 {MAX_PAGES} 页，为避免过量请求已停止；请缩短日期范围")


def write_csv(records: list[dict[str, Any]], output: TextIO) -> None:
    writer = csv.DictWriter(output, fieldnames=FIELDS, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(records)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="查询 WorkBuddy 积分消耗明细")
    parser.add_argument("--start", required=True, help="开始日期 YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="结束日期 YYYY-MM-DD")
    parser.add_argument("--page-size", type=int, default=PAGE_SIZE, help=f"每页条数，最大 {PAGE_SIZE}")
    parser.add_argument("--format", choices=("csv", "json"), default="csv", help="输出格式，默认 CSV")
    parser.add_argument("--output", default="-", help="输出文件，默认写入标准输出")
    parser.add_argument("--user-agent", help="覆盖自动识别的 Chrome User-Agent")
    args = parser.parse_args(argv)
    try:
        cookie = getpass.getpass("WorkBuddy Cookie（不会回显）: ")
        records = fetch_usage(args.start, args.end, cookie, user_agent=args.user_agent, page_size=args.page_size)
        if args.output == "-":
            output = sys.stdout
            close_output = False
        else:
            output = open(args.output, "w", encoding="utf-8-sig", newline="")
            close_output = True
        try:
            if args.format == "json":
                json.dump({"count": len(records), "records": records}, output, ensure_ascii=False, indent=2)
                output.write("\n")
            else:
                write_csv(records, output)
        finally:
            if close_output:
                output.close()
        return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
