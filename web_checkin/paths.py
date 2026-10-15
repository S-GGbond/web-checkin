"""运行时路径解析：静态资源、用户数据目录、数据库与设备指纹默认位置。

安装为软件包后不能依赖当前工作目录，因此运行期需要写入的文件（账号库、
Trae 设备指纹等）统一放到用户数据目录下。为兼容从仓库目录直接运行的旧用法，
若数据目录里还没有对应文件、而当前目录存在同名旧文件，则继续复用旧文件。
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


PACKAGE_DIR = Path(__file__).resolve().parent
STATIC_DIR = PACKAGE_DIR / "static"


def user_data_dir() -> Path:
    """返回跨平台的应用数据目录（不创建目录）。

    - Windows: %LOCALAPPDATA%\\web-checkin
    - macOS:   ~/Library/Application Support/web-checkin
    - Linux:   $XDG_DATA_HOME/web-checkin 或 ~/.local/share/web-checkin

    可用 ``WEB_CHECKIN_HOME`` 覆盖。
    """
    override = os.environ.get("WEB_CHECKIN_HOME")
    if override:
        return Path(override).expanduser()
    if sys.platform == "win32":
        local_appdata = os.environ.get("LOCALAPPDATA")
        base = Path(local_appdata).expanduser() if local_appdata else Path.home() / "AppData" / "Local"
        return base / "web-checkin"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "web-checkin"
    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    base = Path(xdg_data_home).expanduser() if xdg_data_home else Path.home() / ".local" / "share"
    return base / "web-checkin"


def _legacy_cwd_file(name: str) -> Path | None:
    """旧版本把运行文件放在工作目录，迁移期优先复用，避免丢失已有数据。"""
    legacy = Path.cwd() / name
    return legacy if legacy.exists() else None


def data_file(name: str) -> Path:
    """返回用户数据目录下的文件路径，必要时回退到工作目录中的旧文件。"""
    target = user_data_dir() / name
    if not target.exists():
        legacy = _legacy_cwd_file(name)
        if legacy is not None:
            return legacy
    target.parent.mkdir(parents=True, exist_ok=True)
    return target


def default_db_path() -> Path:
    """统一账号数据库路径，可用 ``CHECKIN_HUB_DB`` 覆盖。"""
    override = os.environ.get("CHECKIN_HUB_DB")
    if override:
        return Path(override).expanduser()
    return data_file("checkin-hub.sqlite3")


def default_identity_path() -> Path:
    """Trae 设备指纹文件路径，可用 ``TRAE_IDENTITY_PATH`` 覆盖。"""
    override = os.environ.get("TRAE_IDENTITY_PATH")
    if override:
        return Path(override).expanduser()
    return data_file("trae-identity.json")
