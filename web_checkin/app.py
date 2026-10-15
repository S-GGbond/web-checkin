#!/usr/bin/env python3
"""WorkBuddy / Trae 统一签到管理后端。"""

from __future__ import annotations

import asyncio
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from typing import Any, Literal

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.date import DateTrigger
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .account_store import AccountStore
from .paths import STATIC_DIR, default_db_path
from .qoder_tool import QoderTool
from .trae_tool import TraeTool
from .trae_usage import fetch_usage as fetch_trae_usage
from .workbuddy_tool import WorkBuddyTool
from .workbuddy_usage import fetch_usage


DATABASE_PATH = str(default_db_path())
store = AccountStore(DATABASE_PATH)
workbuddy = WorkBuddyTool(store)
trae = TraeTool(store)
qoder = QoderTool(store)
checkin_lock = asyncio.Lock()
status_lock = asyncio.Lock()

# 定时任务参数：按账号时间用 APScheduler 精确调度，失败后有限次重试，避免漏签整天。
DEFAULT_SCHEDULE_TIME = "09:00"
SCHEDULE_RETRY_DELAY_SECONDS = 300
SCHEDULE_MAX_ATTEMPTS = 3
scheduler = AsyncIOScheduler()
# 当日的重试状态：account_id -> (运行日期, 已尝试次数)，跨天自动失效。
_schedule_retry: dict[int, tuple[str, int]] = {}


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
    scheduler.start()
    sync_account_jobs()
    catchup_task = asyncio.create_task(catch_up_missed_runs())
    try:
        yield
    finally:
        catchup_task.cancel()
        try:
            await catchup_task
        except asyncio.CancelledError:
            pass
        scheduler.shutdown(wait=False)


app = FastAPI(title="WorkBuddy / Trae / Qoder 签到管理", version="1.1.0", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


@app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")


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
    row = store.get_account(account_id)
    if row:
        schedule_account_job(row)
    return {"ok": True, "enabled": enabled}


@app.post("/api/accounts/{account_id}/schedule")
async def set_account_schedule(account_id: int, request: ScheduleRequest):
    row = get_row_or_404(account_id)
    if not store.update_schedule(account_id, enabled=request.enabled, schedule_time=request.time):
        raise HTTPException(status_code=404, detail="账号不存在")
    if str(row["schedule_time"] or DEFAULT_SCHEDULE_TIME) != request.time:
        # 计划时间变化后重置当日重试计数，让新时间可以重新触发。
        _schedule_retry.pop(account_id, None)
    updated = store.get_account(account_id)
    if updated:
        schedule_account_job(updated)
    return {"ok": True, "enabled": request.enabled, "time": request.time}


@app.delete("/api/accounts/{account_id}")
async def delete_account(account_id: int):
    get_row_or_404(account_id)
    store.delete_account(account_id)
    remove_account_job(account_id)
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
            result = await asyncio.to_thread(workbuddy.login_status, login_id)
        elif provider == "trae":
            result = await asyncio.to_thread(trae.login_status, login_id)
        else:
            result = await asyncio.to_thread(qoder.login_status, login_id)
    except Exception as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    if isinstance(result, dict) and result.get("status") == "success":
        # 登录成功后账号可能新增或更新，立即把定时任务与账号库对齐。
        sync_account_jobs()
    return result


def parse_schedule_time(value: str) -> tuple[int, int]:
    """把 HH:MM 解析为 (hour, minute)，非法值回退到默认时间。"""
    try:
        hour_text, minute_text = str(value).split(":", 1)
        hour, minute = int(hour_text), int(minute_text)
    except (AttributeError, ValueError):
        return 9, 0
    if 0 <= hour <= 23 and 0 <= minute <= 59:
        return hour, minute
    return 9, 0


def schedule_job_id(account_id: int) -> str:
    return f"checkin:{account_id}"


def retry_job_id(account_id: int) -> str:
    return f"checkin-retry:{account_id}"


def remove_job_if_exists(job_id: str) -> None:
    if scheduler.get_job(job_id):
        scheduler.remove_job(job_id)


def remove_account_job(account_id: int) -> None:
    remove_job_if_exists(schedule_job_id(account_id))
    remove_job_if_exists(retry_job_id(account_id))
    _schedule_retry.pop(account_id, None)


def schedule_account_job(row: Any) -> None:
    """按账号配置注册/更新每日定时任务；账号未启用或关闭定时则移除。"""
    account_id = int(row["id"])
    if not row["enabled"] or not row["schedule_enabled"]:
        remove_account_job(account_id)
        return
    hour, minute = parse_schedule_time(row["schedule_time"] or DEFAULT_SCHEDULE_TIME)
    scheduler.add_job(
        run_scheduled_checkin,
        trigger=CronTrigger(hour=hour, minute=minute),
        args=[account_id],
        id=schedule_job_id(account_id),
        name=row["display_name"] or f"account-{account_id}",
        replace_existing=True,
        coalesce=True,
        misfire_grace_time=3600,
        max_instances=1,
    )


def sync_account_jobs() -> None:
    """把调度器任务与数据库账号对齐：新增/更新任务，清理已删除账号的任务。"""
    rows = {int(row["id"]): row for row in store.list_account_rows()}
    for row in rows.values():
        schedule_account_job(row)
    for job in scheduler.get_jobs():
        try:
            account_id = int(job.id.rsplit(":", 1)[1])
        except (IndexError, ValueError):
            continue
        if account_id not in rows:
            remove_account_job(account_id)


async def catch_up_missed_runs() -> None:
    """启动时补跑当天已过点但尚未完成的定时签到（服务停机期间错过的任务）。"""
    now = datetime.now()
    today = now.strftime("%Y-%m-%d")
    for row in store.list_account_rows(enabled_only=True):
        if not row["schedule_enabled"] or row["schedule_last_date"] == today:
            continue
        hour, minute = parse_schedule_time(row["schedule_time"] or DEFAULT_SCHEDULE_TIME)
        if (now.hour, now.minute) < (hour, minute):
            continue
        try:
            await run_scheduled_checkin(int(row["id"]))
        except Exception as exc:
            print(f"[scheduler] 补跑任务异常: {exc}", flush=True)


async def run_scheduled_checkin(account_id: int) -> None:
    """定时任务入口：执行签到，失败则按退避间隔安排重试，成功或重试耗尽后锁定当日。"""
    row = store.get_account(account_id)
    if not row or not row["enabled"] or not row["schedule_enabled"]:
        remove_account_job(account_id)
        return
    today = datetime.now().strftime("%Y-%m-%d")
    if row["schedule_last_date"] == today:
        return

    state = _schedule_retry.get(account_id)
    attempts = (state[1] if state and state[0] == today else 0) + 1
    schedule_time = str(row["schedule_time"] or DEFAULT_SCHEDULE_TIME)
    # 调度触发和实际签到结果分开记录，便于区分“未触发”与“触发后失败”。
    store.add_log(
        account_id,
        row["provider"],
        action="schedule",
        ok=True,
        message=f"每日定时任务触发（第 {attempts}/{SCHEDULE_MAX_ATTEMPTS} 次），计划时间 {schedule_time}",
    )

    async with checkin_lock:
        result = await asyncio.to_thread(run_single_checkin, row)

    if result.get("ok"):
        # 只有签到成功（或今日已签到）才标记当日完成。
        store.mark_schedule_run(account_id, today)
        _schedule_retry.pop(account_id, None)
        remove_job_if_exists(retry_job_id(account_id))
    elif attempts >= SCHEDULE_MAX_ATTEMPTS:
        # 连续失败达到上限后放弃当日重试，避免对失效登录态持续空转。
        store.mark_schedule_run(account_id, today)
        _schedule_retry.pop(account_id, None)
        remove_job_if_exists(retry_job_id(account_id))
        store.add_log(
            account_id,
            row["provider"],
            action="schedule",
            ok=False,
            message=f"定时签到连续 {attempts} 次失败，今日不再重试",
        )
    else:
        # 失败不锁定当日，改由一次性任务在退避间隔后重试。
        _schedule_retry[account_id] = (today, attempts)
        scheduler.add_job(
            run_scheduled_checkin,
            trigger=DateTrigger(run_date=datetime.now() + timedelta(seconds=SCHEDULE_RETRY_DELAY_SECONDS)),
            args=[account_id],
            id=retry_job_id(account_id),
            replace_existing=True,
            misfire_grace_time=3600,
            max_instances=1,
        )
