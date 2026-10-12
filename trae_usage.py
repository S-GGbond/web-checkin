#!/usr/bin/env python3
"""Trae 积分用量查询，复用统一账号库和 TraeTool 认证能力。"""

from __future__ import annotations

import argparse
import json
import time
from datetime import date, datetime, time as day_time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from account_store import AccountStore, DEFAULT_HUB_DB
from trae_tool import TraeTool


SOURCE_LABEL = {0: "TRAE", 1: "Web/Lite", 2: "Web/Lite", 3: "Mobile"}
LOCAL_TZ = ZoneInfo("Asia/Shanghai")


def date_range_timestamps(start: str, end: str) -> tuple[int, int, list[str]]:
    try:
        start_day = date.fromisoformat(start)
        end_day = date.fromisoformat(end)
    except ValueError as exc:
        raise ValueError("日期格式必须为 YYYY-MM-DD") from exc
    if end_day < start_day:
        raise ValueError("结束日期不能早于开始日期")
    if (end_day - start_day).days > 90:
        raise ValueError("日期范围最多 91 天")
    start_dt = datetime.combine(start_day, day_time.min, LOCAL_TZ)
    end_dt = datetime.combine(end_day + timedelta(days=1), day_time.min, LOCAL_TZ)
    days = [(start_day + timedelta(days=index)).isoformat() for index in range((end_day - start_day).days + 1)]
    return int(start_dt.timestamp()), int(end_dt.timestamp()) - 1, days


def normalize_item(item: dict[str, Any]) -> dict[str, Any]:
    try:
        timestamp = int(float(item.get("usage_time") or 0))
    except (TypeError, ValueError):
        timestamp = 0
    try:
        credits = float(item.get("credits_float") or 0)
    except (TypeError, ValueError):
        credits = 0.0
    source = item.get("usage_source")
    extra = item.get("extra_info") if isinstance(item.get("extra_info"), dict) else {}
    return {
        "time": datetime.fromtimestamp(timestamp, LOCAL_TZ).strftime("%Y-%m-%d %H:%M:%S") if timestamp else "",
        "day": datetime.fromtimestamp(timestamp, LOCAL_TZ).date().isoformat() if timestamp else "",
        "sessionId": str(item.get("session_id") or ""),
        "record": str(item.get("user_input_preview") or ""),
        "model": str(item.get("model_name") or ""),
        "source": SOURCE_LABEL.get(source, f"source:{source}"),
        "plan": ",".join(str(value) for value in (item.get("product_type_list") or [])),
        "credits": credits,
        "amount": item.get("amount_float") or 0,
        "costMoney": item.get("cost_money_float") or 0,
        "tokens": {
            "input": extra.get("input_token", 0),
            "output": extra.get("output_token", 0),
            "cacheRead": extra.get("cache_read_token", 0),
            "cacheWrite": extra.get("cache_write_token", 0),
        },
    }


# 源脚本成功时的默认分页是 20；实测 100 会被支付网关拒绝为订单参数错误。
def query_account(trae: TraeTool, row: Any, start: str, end: str, page_size: int = 20) -> dict[str, Any]:
    start_time, end_time, days = date_range_timestamps(start, end)
    auth = trae._load_auth(row)
    items: list[dict[str, Any]] = []
    page_num = 1
    total = 0
    try:
        while True:
            status, payload = trae._post(
                row,
                auth,
                "/trae/api/v1/pay/query_user_usage_group_by_session",
                {
                    "start_time": start_time,
                    "end_time": end_time,
                    "page_size": page_size,
                    "page_num": page_num,
                    "usage_type": [7],
                },
                # usage.js 未传 ideVersionCode，源 lib.js 因此采用默认值。
                header_overrides={"x-ide-version-code": "20260401"},
            )
            if status != 200 or (payload.get("code") is not None and payload.get("code") != 0):
                message = payload.get("message") or payload.get("Message") or f"HTTP {status}"
                raise RuntimeError(f"查询用量失败: {message}")
            page_items = payload.get("user_usage_group_by_sessions") or []
            if not isinstance(page_items, list):
                raise RuntimeError("Trae 用量响应格式异常")
            try:
                total = int(payload.get("total") or 0)
            except (TypeError, ValueError):
                total = 0
            items.extend(normalize_item(item) for item in page_items if isinstance(item, dict))
            if not page_items or len(items) >= total or len(page_items) < page_size:
                break
            page_num += 1
            time.sleep(0.2)
    finally:
        trae._save_auth(row, auth)
    by_day = {day: {"credits": 0.0, "requests": 0} for day in days}
    by_model: dict[str, dict[str, float | int]] = {}
    for item in items:
        day = item["day"]
        if day in by_day:
            by_day[day]["credits"] += item["credits"]
            by_day[day]["requests"] += 1
        model = item["model"] or "未标记"
        summary = by_model.setdefault(model, {"credits": 0.0, "requests": 0})
        summary["credits"] += item["credits"]
        summary["requests"] += 1
    for value in by_day.values():
        value["credits"] = round(value["credits"], 4)
    model_summary = [
        {"model": model, **summary, "credits": round(float(summary["credits"]), 4)}
        for model, summary in sorted(by_model.items(), key=lambda entry: float(entry[1]["credits"]), reverse=True)
    ]
    return {
        "ok": True,
        "accountId": int(row["id"]),
        "externalId": str(row["external_id"]),
        "name": str(row["display_name"] or row["label"] or row["external_id"]),
        "total": total,
        "requestCount": len(items),
        "totalCredits": round(sum(item["credits"] for item in items), 4),
        "daily": [{"date": day, **value} for day, value in by_day.items()],
        "models": model_summary,
        "items": items,
    }


def fetch_usage(store: AccountStore, trae: TraeTool, start: str, end: str, account_id: int | None = None) -> dict[str, Any]:
    date_range_timestamps(start, end)
    rows = [row for row in store.list_account_rows() if row["provider"] == "trae" and (account_id is None or int(row["id"]) == account_id)]
    if account_id is not None and not rows:
        raise ValueError("Trae 账号不存在")
    results = []
    for row in rows:
        try:
            results.append(query_account(trae, row, start, end))
        except Exception as exc:
            results.append({
                "ok": False,
                "accountId": int(row["id"]),
                "externalId": str(row["external_id"]),
                "name": str(row["display_name"] or row["label"] or row["external_id"]),
                "message": str(exc),
            })
    return {
        "start": start,
        "end": end,
        "accounts": results,
        "totalCredits": round(sum(result.get("totalCredits", 0) for result in results if result.get("ok")), 4),
        "requestCount": sum(result.get("requestCount", 0) for result in results if result.get("ok")),
        "failedCount": sum(not result.get("ok") for result in results),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="查询 Trae 账号积分用量")
    parser.add_argument("--start", default=(date.today() - timedelta(days=6)).isoformat())
    parser.add_argument("--end", default=date.today().isoformat())
    parser.add_argument("--account", type=int)
    parser.add_argument("--db", default=DEFAULT_HUB_DB)
    args = parser.parse_args()
    store = AccountStore(args.db)
    try:
        print(json.dumps(fetch_usage(store, TraeTool(store), args.start, args.end, args.account), ensure_ascii=False, indent=2))
    finally:
        store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
