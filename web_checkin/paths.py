"""运行时路径解析：静态资源、用户数据目录、数据库与设备指纹默认位置。

安装为软件包后不能依赖当前工作目录，因此运行期需要写入的文件（账号库、
Trae 设备指纹等）统一放到用户数据目录下。为兼容从仓库目录直接运行的旧用法，
若数据目录里还没有对应文件、而当前目录存在同名旧文件，则一次性迁移过去。
"""

from __future__ import annotations

import os
import shutil
import sqlite3
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


def _migrate_legacy_file(name: str, target: Path) -> None:
    """把工作目录里的旧文件一次性复制到用户数据目录（保留旧文件作为备份）。"""
    legacy = _legacy_cwd_file(name)
    if legacy is None:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(legacy, target)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass


def data_file(name: str) -> Path:
    """返回用户数据目录下的文件路径；首次运行时从工作目录的旧文件迁移。"""
    target = user_data_dir() / name
    if not target.exists():
        _migrate_legacy_file(name, target)
    target.parent.mkdir(parents=True, exist_ok=True)
    return target


def _db_has_accounts(path: Path) -> bool:
    """判断账号库是否已有数据，用于识别"新空库遮蔽旧数据"的情况。"""
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            row = con.execute("SELECT COUNT(*) FROM accounts").fetchone()
            return bool(row and row[0])
        finally:
            con.close()
    except Exception:
        return False


def default_db_path() -> Path:
    """统一账号数据库路径，可用 ``CHECKIN_HUB_DB`` 覆盖。"""
    override = os.environ.get("CHECKIN_HUB_DB")
    if override:
        return Path(override).expanduser()
    target = data_file("checkin-hub.sqlite3")
    # 防御：新位置曾被初始化成空库、而工作目录里仍有旧数据时，自动回迁，
    # 避免"看起来数据丢了"的情况。
    legacy = _legacy_cwd_file("checkin-hub.sqlite3")
    if (
        legacy is not None
        and target.exists()
        and legacy.resolve() != target.resolve()
        and not _db_has_accounts(target)
        and _db_has_accounts(legacy)
    ):
        backup = target.with_name(target.name + ".empty-backup")
        shutil.copy2(target, backup)
        shutil.copy2(legacy, target)
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass
    return target


def default_identity_path() -> Path:
    """Trae 设备指纹文件路径，可用 ``TRAE_IDENTITY_PATH`` 覆盖。"""
    override = os.environ.get("TRAE_IDENTITY_PATH")
    if override:
        return Path(override).expanduser()
    return data_file("trae-identity.json")
