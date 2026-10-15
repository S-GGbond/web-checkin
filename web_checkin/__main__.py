"""支持 ``python -m web_checkin`` 启动服务。"""

from __future__ import annotations

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
