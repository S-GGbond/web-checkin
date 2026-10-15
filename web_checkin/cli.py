"""命令行入口：启动本地 Web 服务。"""

from __future__ import annotations

import argparse
import os
import threading
import webbrowser


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="web-checkin",
        description="启动 WorkBuddy / Trae / Qoder 多账号签到与用量查询服务",
    )
    parser.add_argument("--host", default="127.0.0.1", help="监听地址，默认 127.0.0.1")
    parser.add_argument("--port", type=int, default=8320, help="监听端口，默认 8320")
    parser.add_argument("--db", default=None, help="账号数据库路径，默认使用用户数据目录")
    parser.add_argument("--no-browser", action="store_true", help="启动后不自动打开浏览器")
    parser.add_argument("--log-level", default="info", help="uvicorn 日志级别，默认 info")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # app 模块在导入时就会解析数据库路径，因此必须在导入前写入环境变量。
    if args.db:
        os.environ["CHECKIN_HUB_DB"] = args.db

    import uvicorn

    from .app import DATABASE_PATH, app

    display_host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    url = f"http://{display_host}:{args.port}/"
    print(f"[web-checkin] 数据库: {DATABASE_PATH}")
    print(f"[web-checkin] 服务地址: {url}")
    if not args.no_browser:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()

    uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level)
    return 0
