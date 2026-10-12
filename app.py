#!/usr/bin/env python3
"""WorkBuddy / Trae 统一签到管理后端。"""

from __future__ import annotations

import asyncio
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from account_store import AccountStore, DEFAULT_HUB_DB
from qoder_tool import QoderTool
from trae_tool import TraeTool
from trae_usage import fetch_usage as fetch_trae_usage
from workbuddy_tool import WorkBuddyTool
from workbuddy_usage import fetch_usage


DATABASE_PATH = os.environ.get("CHECKIN_HUB_DB", DEFAULT_HUB_DB)
store = AccountStore(DATABASE_PATH)
workbuddy = WorkBuddyTool(store)
trae = TraeTool(store)
qoder = QoderTool(store)
checkin_lock = asyncio.Lock()
status_lock = asyncio.Lock()


class WorkBuddyLoginRequest(BaseModel):
    label: str = ""
    endpoint: str = "https://www.workbuddy.cn"
    platform: str = "workbuddy"
    auto_browser: bool = False
    timeout: float = Field(default=600, ge=30, le=1800)


class TraeLoginRequest(BaseModel):
    label: str = ""
    auto_browser: bool = False
    timeout: float = Field(default=300, ge=30, le=1800)


class QoderLoginRequest(BaseModel):
    label: str = ""
    auto_browser: bool = False
    timeout: float = Field(default=300, ge=30, le=1800)


class ScheduleRequest(BaseModel):
    enabled: bool
    time: str = Field(pattern=r"^([01]\d|2[0-3]):([0-5]\d)$")


class WorkBuddyUsageRequest(BaseModel):
    start: str = Field(min_length=10, max_length=10)
    end: str = Field(min_length=10, max_length=10)
    cookie: str = Field(min_length=1, max_length=65536)
    user_agent: str = Field(min_length=1, max_length=512)


class TraeUsageRequest(BaseModel):
    start: str = Field(min_length=10, max_length=10)
    end: str = Field(min_length=10, max_length=10)
    account_id: int | None = Field(default=None, gt=0)


@asynccontextmanager
async def lifespan(_: FastAPI):
    await asyncio.to_thread(qoder.import_local_auth)
    task = asyncio.create_task(schedule_loop())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="WorkBuddy / Trae / Qoder 签到管理", version="1.1.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
async def index():
    return FileResponse("static/index.html")


@app.get("/api/health")
async def health():
    return {"ok": True, "time": int(time.time())}


@app.get("/api/accounts")
async def accounts():
    return {"accounts": store.list_accounts()}


@app.get("/api/logs")
async def logs(limit: int = 80):
    return {"logs": store.recent_logs(limit)}


@app.post("/api/workbuddy/usage")
async def workbuddy_usage(request: WorkBuddyUsageRequest):
    try:
        records = await asyncio.to_thread(
            fetch_usage,
            request.start,
            request.end,
            request.cookie,
            user_agent=request.user_agent,
        )
    except (RuntimeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"count": len(records), "records": records}


@app.post("/api/trae/usage")
async def trae_usage(request: TraeUsageRequest):
    try:
        return await asyncio.to_thread(
            fetch_trae_usage, store, trae, request.start, request.end, request.account_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


def get_row_or_404(account_id: int):
    row = store.get_account(account_id)
    if not row:
        raise HTTPException(status_code=404, detail="账号不存在")
    return row


@app.post("/api/accounts/{account_id}/enable")
async def enable_account(account_id: int, enabled: bool = True):
    get_row_or_404(account_id)
    if not store.set_enabled(account_id, enabled):
        raise HTTPException(status_code=404, detail="账号不存在")
    return {"ok": True, "enabled": enabled}


@app.post("/api/accounts/{account_id}/schedule")
async def set_account_schedule(account_id: int, request: ScheduleRequest):
    get_row_or_404(account_id)
    if not store.update_schedule(account_id, enabled=request.enabled, schedule_time=request.time):
        raise HTTPException(status_code=404, detail="账号不存在")
    return {"ok": True, "enabled": request.enabled, "time": request.time}


@app.delete("/api/accounts/{account_id}")
async def delete_account(account_id: int):
    get_row_or_404(account_id)
    store.delete_account(account_id)
    return {"ok": True}


@app.post("/api/accounts/{account_id}/status")
async def refresh_status(account_id: int):
    row = get_row_or_404(account_id)
    provider = row["provider"]
    try:
        if provider == "workbuddy":
            status = workbuddy.status(row)
        elif provider == "trae":
            status = trae.status(row)
        elif provider == "qoder":
            status = qoder.status(row)
        else:
            raise RuntimeError(f"不支持的 provider: {provider}")
        store.update_status(account_id, status)
        store.add_log(account_id, provider, action="status", ok=True, message="状态刷新成功", payload=status)
        return {"ok": True, "status": status}
    except Exception as exc:
        message = str(exc)
        store.add_log(account_id, provider, action="status", ok=False, message=message)
        store.update_checkin(account_id, ok=False, message=message)
        raise HTTPException(status_code=400, detail=message) from exc


@app.post("/api/status")
async def refresh_all_status():
    async with status_lock:
        results = []
        for row in store.list_account_rows():
            account_id = int(row["id"])
            provider = row["provider"]
            try:
                if provider == "workbuddy":
                    status = await asyncio.to_thread(workbuddy.status, row)
                elif provider == "trae":
                    status = await asyncio.to_thread(trae.status, row)
                elif provider == "qoder":
                    status = await asyncio.to_thread(qoder.status, row)
                else:
                    raise RuntimeError(f"不支持的 provider: {provider}")
                store.update_status(account_id, status)
                store.add_log(account_id, provider, action="status", ok=True, message="状态刷新成功", payload=status)
                results.append({"account_id": account_id, "provider": provider, "ok": True, "status": status})
            except Exception as exc:
                message = str(exc)
                store.add_log(account_id, provider, action="status", ok=False, message=message)
                results.append({"account_id": account_id, "provider": provider, "ok": False, "message": message})
        return {"results": results}


def run_single_checkin(row: Any) -> dict[str, Any]:
    account_id = int(row["id"])
    provider = row["provider"]
    try:
        if provider == "workbuddy":
            result = workbuddy.checkin(row)
        elif provider == "trae":
            result = trae.checkin(row)
        elif provider == "qoder":
            result = qoder.checkin(row)
        else:
            raise RuntimeError(f"不支持的 provider: {provider}")
        return {"account_id": account_id, "provider": provider, "display_name": row["display_name"], **result}
    except Exception as exc:
        message = str(exc)
        store.update_checkin(account_id, ok=False, message=message)
        store.add_log(account_id, provider, action="checkin", ok=False, message=message)
        return {"account_id": account_id, "provider": provider, "display_name": row["display_name"], "ok": False, "message": message}


@app.post("/api/accounts/{account_id}/checkin")
async def manual_checkin(account_id: int):
    row = get_row_or_404(account_id)
    async with checkin_lock:
        result = await asyncio.to_thread(run_single_checkin, row)
    return {"ok": bool(result.get("ok")), "result": result}


def run_batch_checkin():
    results = []
    for row in store.list_account_rows(enabled_only=True):
        results.append(run_single_checkin(row))
        time.sleep(0.4)
    return results


@app.post("/api/checkin")
async def batch_checkin():
    async with checkin_lock:
        results = await asyncio.to_thread(run_batch_checkin)
    return {"ok": all(item.get("ok") for item in results), "results": results}


@app.post("/api/login/workbuddy")
async def start_workbuddy_login(request: WorkBuddyLoginRequest):
    try:
        return await asyncio.to_thread(
            workbuddy.start_login,
            endpoint=request.endpoint,
            platform=request.platform,
            label=request.label,
            auto_browser=request.auto_browser,
            timeout=request.timeout,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/login/trae")
async def start_trae_login(request: TraeLoginRequest):
    try:
        return await asyncio.to_thread(
            trae.start_login,
            label=request.label,
            auto_browser=request.auto_browser,
            timeout=request.timeout,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.post("/api/login/qoder")
async def start_qoder_login(request: QoderLoginRequest):
    try:
        return await asyncio.to_thread(
            qoder.start_login,
            label=request.label,
            auto_browser=request.auto_browser,
            timeout=request.timeout,
        )
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/login/{provider}/{login_id}")
async def login_status(provider: Literal["workbuddy", "trae", "qoder"], login_id: str):
    try:
        if provider == "workbuddy":
            return await asyncio.to_thread(workbuddy.login_status, login_id)
        if provider == "trae":
            return await asyncio.to_thread(trae.login_status, login_id)
        return await asyncio.to_thread(qoder.login_status, login_id)
    except Exception as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


def parse_schedule_time(value: str) -> tuple[int, int]:
    hour, minute = value.split(":", 1)
    return int(hour), int(minute)


async def schedule_loop():
    while True:
        try:
            now = datetime.now()
            today = now.strftime("%Y-%m-%d")
            current_time = now.strftime("%H:%M")
            due_accounts = [
                row for row in store.list_account_rows(enabled_only=True)
                if row["schedule_enabled"]
                and row["schedule_last_date"] != today
                and str(row["schedule_time"] or "09:00") <= current_time
            ]
            for row in due_accounts:
                account_id = int(row["id"])
                schedule_time = str(row["schedule_time"] or "09:00")
                # 先标记当日运行，避免任务执行期间循环重复触发。
                store.mark_schedule_run(account_id, today)
                # 调度触发和实际签到结果分开记录，便于区分“未触发”与“触发后失败”。
                store.add_log(
                    account_id,
                    row["provider"],
                    action="schedule",
                    ok=True,
                    message=f"每日定时任务触发，计划时间 {schedule_time}",
                )
                async with checkin_lock:
                    await asyncio.to_thread(run_single_checkin, row)
        except Exception as exc:
            # 调度循环必须持续运行；单账号签到异常已由 run_single_checkin 记录，
            # 这里只保留服务端可见的框架级异常，避免整个调度器静默失效。
            print(f"[scheduler] 调度循环异常: {exc}", flush=True)
        await asyncio.sleep(10)
