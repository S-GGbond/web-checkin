# 签到中枢 · Check-in Hub

[![Release](https://img.shields.io/github/v/release/S-GGbond/checkin-hub?label=Release)](https://github.com/S-GGbond/checkin-hub/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/web-checkin.svg)](https://pypi.org/project/web-checkin/)

WorkBuddy / Trae / Qoder 多账号签到与用量查询中枢。

**主线是 Flutter 跨端客户端**（Windows / macOS / Linux 桌面版，Android / iOS 移动版），
仓库里同时保留早期的 Python + FastAPI Web 版（`web_checkin/` + `frontend/`）。
两条实现共用同一份 `checkin-hub.sqlite3` 账号库，协议与字段完全对齐，可互相迁移。

> 仅供个人管理自己拥有授权的账号。请不要用于批量注册、共享账号、绕过平台限制或任何违反平台服务条款的场景。

## 下载（v1.0.0 · Flutter 桌面版）

| 平台 | 安装包 | 安装方式 |
| --- | --- | --- |
| Debian / Ubuntu | [checkin-hub_1.0.0_amd64.deb](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_amd64.deb) | `sudo dpkg -i …` |
| RHEL / CentOS / Fedora | [checkin-hub_1.0.0_x86_64.rpm](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_x86_64.rpm) | `sudo rpm -ivh …` |
| Linux 通用 | [checkin-hub_1.0.0_linux_x64.tar.gz](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_linux_x64.tar.gz) | 解压即用 |
| Windows | [checkin-hub_1.0.0_windows_x64.zip](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_windows_x64.zip) | 解压运行 `checkin_hub.exe` |
| macOS (Apple Silicon) | [.zip](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_macos_arm64.zip) / [.dmg](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_macos_arm64.dmg) | 解压或双击安装 |
| iOS (iPhone, arm64) | [checkin-hub_1.0.0_ios_arm64.ipa](https://github.com/S-GGbond/checkin-hub/releases/download/v1.0.0/checkin-hub_1.0.0_ios_arm64.ipa) | **未签名**，需用 AltStore / Sideloadly 等工具侧载 |

Release 页面：<https://github.com/S-GGbond/checkin-hub/releases/tag/v1.0.0>

iOS 提供的是**未签名** IPA，只能侧载安装（自备开发者证书请用 Flutter 工具链自行构建）；
Android APK 请用 Flutter 工具链自行构建，见下面「从源码运行」。

## Flutter 客户端能做什么

- **账号与签到**：三平台官方授权登录，登录态存本地库（`0600`），每个账号独立签到时间，可单独启停
- **后台定时**：交给系统调度（systemd / launchd / 任务计划 / WorkManager），应用关闭后照常执行，失败自动重试
- **用量页**：总消耗、每日折线图、平台占比、模型 Top 5、按天分组的会话明细
  - WorkBuddy 逐笔请求用量（模型、积分、输入摘要）
  - Trae 按会话聚合（首条用户输入、模型、积分、token 数）
  - Qoder 走 qoder.cn 网页端逐笔明细（模型、会话、是否计费），登录时自动绑定网页登录态
- **会话管理**：扫描 Trae 会话库与 WorkBuddy CLI 会话，能把某个 Trae 会话**复制到另一个账号**
  （会话图闭包复制 + id 重映射 + 完整性校验 + 自动备份）
- **桌面客户端换号**：把账号库里的登录态写回本机 Trae / WorkBuddy / Qoder 客户端
  （写入前自动备份；Qoder 换号前会等客户端真正退出）
- **移动端适配**：Android 精确闹钟 + 开机自启，导入导出走系统文件选择器，桌面专属能力在手机端整块隐藏
- **外观**：浅色 / 深色双主题（可跟随系统），全平台应用图标

## 从源码运行（Flutter 客户端）

```bash
cd flutter_app
flutter pub get
flutter run -d linux        # 或 -d windows / -d macos / 真机

flutter build linux --release
flutter build apk --release
tools/package/package.sh    # 打 deb + rpm，产物在 flutter_app/dist/
```

架构、目录、协议细节、数据位置与测试方式见 **[flutter_app/README.md](flutter_app/README.md)**。

---

## Python Web 版（旧版，仍在仓库内）

下面保留原 `web-checkin`（FastAPI + React）的完整说明：安装、启动、环境变量、主要 API、
定时任务、数据库结构、安全约定与常见问题。

### 功能概览

#### 账号与状态

- WorkBuddy、Trae、Qoder 账号分别走平台官方授权流程。
- 登录态写入本地 SQLite 数据库，数据库默认 `0600` 权限。
- 支持账号启用 / 停用 / 删除。
- 页面打开后自动刷新所有账号的实时余额。
- WorkBuddy 使用平台返回的 `today_checked_in`，Trae 使用 `checked_in`；Qoder 没有明确“今日已签”字段，因此只有 `CLAIMED` 活动或当天本地成功领取记录才会显示“今日已签到”。
- 每个账号可配置独立的每日签到时间。
- 服务重启后，如果当天设定时间已过且尚未完成签到，会补跑一次。

#### 签到与日志

- 支持单账号签到、全部账号签到。
- 每个账号的定时触发会生成 `schedule` 日志。
- 实际签到结果会生成 `claim` / `already` 日志。
- 登录、状态刷新、签到失败信息都会记录在执行日志中。

#### WorkBuddy 用量

- 使用浏览器 Cookie 查询 WorkBuddy 积分消耗明细。
- 展示每日积分趋势、模型分布和分页请求明细。
- 支持导出 CSV。
- Cookie 只保存在当前查询请求内存中，不会写入账号库或日志。

#### Trae 用量

- 复用统一账号库中的 Trae 登录态查询积分明细。
- 展示总消耗、每日曲线、模型分布和请求明细。
- 临期登录态会自动续期并加密回写。
- 用量接口分页使用 `page_size=20`，该值是当前验证可用的稳定分页大小。

### 界面结构

页面自上而下分为：

1. 顶部栏（品牌、时钟、自动刷新、刷新余额、全部签到）。
2. 账号统计卡片区。
3. 添加账号（三平台官方授权登录）与独立定时说明。
4. 托管账号列表（按平台分组，卡片内含余额/活动状态、签到状态、每日定时、操作按钮）。
5. WorkBuddy 积分消耗明细。
6. Trae 积分用量。
7. 执行日志。

> 每日定时时间在「托管账号列表」中每张账号卡片的「定时」入口里单独设置。

### 环境要求

- Python 3.11 或更高版本。
- 现代浏览器。
- 各平台的官方授权页面可正常访问。
- 仅当需要修改界面时，才需要 Node.js 20+（构建前端）。

### 安装

推荐从 PyPI 安装为独立命令（pipx 会为它创建隔离环境）：

```bash
pipx install web-checkin
```

也可以直接用 pip：

```bash
pip install web-checkin
```

从源码安装：

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
# 或直接安装本仓库：pip install .
```

依赖包括 FastAPI、Uvicorn、cryptography 和 APScheduler。

前端已把构建产物提交到 `web_checkin/static/`，**无需 Node 即可直接运行**。只有在改动 `frontend/` 源码后才需要重新构建：

```bash
cd frontend
npm install
npm run build   # 产物输出到 ../web_checkin/static
```

### 启动

```bash
web-checkin
```

打开：

```text
http://127.0.0.1:8320
```

也可以直接从源码运行（开发时）：

```bash
python -m web_checkin
# 或：python -m uvicorn web_checkin.app:app --host 127.0.0.1 --port 8320
```

命令行参数：

| 参数 | 说明 | 默认值 |
|---|---|---|
| `--host` | 监听地址 | `127.0.0.1` |
| `--port` | 监听端口 | `8320` |
| `--db` | 账号数据库路径 | 用户数据目录下的 `checkin-hub.sqlite3` |
| `--no-browser` | 启动后不自动打开浏览器 | 关闭 |
| `--log-level` | uvicorn 日志级别 | `info` |

服务默认只监听本机地址。不要直接把无认证的管理端暴露到公网。如需局域网访问，请自行添加反向代理、访问控制和 HTTPS。

### 环境变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `WEB_CHECKIN_HOME` | 应用数据目录（数据库、设备指纹等） | 平台数据目录，见下 |
| `CHECKIN_HUB_DB` | 统一账号数据库路径 | `WEB_CHECKIN_HOME/checkin-hub.sqlite3` |
| `TRAE_IDENTITY_PATH` | Trae 设备指纹文件路径 | `WEB_CHECKIN_HOME/trae-identity.json` |
| `TRAE_LEGACY_DB` | 可选的旧 Trae 数据库路径 | `~/.trae-checkin/trae_checkin.db` |
| `QODER_DATA_DIR` | Qoder 登录态和机器 ID 目录 | `~/.qoder-checkin` |

应用数据目录按平台自动选择：

- Linux：`$XDG_DATA_HOME/web-checkin` 或 `~/.local/share/web-checkin`
- macOS：`~/Library/Application Support/web-checkin`
- Windows：`%LOCALAPPDATA%\web-checkin`

兼容旧用法：如果应用数据目录里还没有 `checkin-hub.sqlite3` / `trae-identity.json`，而当前工作目录存在同名旧文件，会一次性迁移到应用数据目录（旧文件保留作备份）。如果应用数据目录里的账号库是空的、而工作目录的旧库仍有数据，启动时会自动回迁，避免"数据丢了"的情况。

Qoder 登录脚本已内置在项目内。服务启动时会尝试从 `QODER_DATA_DIR/qoder_auth.json` 导入既有登录态；目录不存在或还没有登录态时，不影响 WorkBuddy / Trae 启动。

### 主要 API

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/health` | 健康检查 |
| `GET` | `/api/accounts` | 获取账号列表 |
| `GET` | `/api/logs` | 获取执行日志 |
| `POST` | `/api/status` | 刷新全部账号状态 |
| `POST` | `/api/accounts/{id}/status` | 刷新单个账号状态 |
| `POST` | `/api/accounts/{id}/checkin` | 手动签到单个账号 |
| `POST` | `/api/checkin` | 手动签到全部启用账号 |
| `POST` | `/api/accounts/{id}/schedule` | 设置独立定时任务 |
| `POST` | `/api/accounts/{id}/enable?enabled=true|false` | 启用或停用账号 |
| `DELETE` | `/api/accounts/{id}` | 删除账号 |
| `POST` | `/api/login/workbuddy` | 启动 WorkBuddy 登录 |
| `POST` | `/api/login/trae` | 启动 Trae 登录 |
| `POST` | `/api/login/qoder` | 启动 Qoder 登录 |
| `POST` | `/api/workbuddy/usage` | 查询 WorkBuddy 积分明细 |
| `POST` | `/api/trae/usage` | 查询 Trae 积分明细 |

### 定时任务

每个账号保存独立的：

- `schedule_enabled`
- `schedule_time`
- `schedule_last_date`

定时任务由 APScheduler 的 `AsyncIOScheduler` 驱动（非轮询）。服务启动时按账号注册每日 `CronTrigger`，到点直接触发，不再空转检查数据库：

- 账号启用且定时开启时，注册/更新一条每日定时任务；关闭账号或关闭定时即移除任务。
- 计划时间、启用状态变更，以及登录新增账号后，都会即时重排对应的定时任务。
- `schedule_last_date` 只在当日任务「完成」后写入。签到成功或平台返回「今日已签到」均视为完成。
- 签到失败会按固定间隔自动重试，默认最多 3 次、间隔 300 秒（用一次性任务重排）；重试次数用尽后放弃当日重试并记录失败日志。
- 服务重启后，如果当天设定时间已过且尚未完成，会由启动补跑任务补签一次。
- 每次调度触发都会生成 `schedule` 日志，并标注是第几次尝试。

日志顺序：

1. `schedule`：记录定时任务已触发（含第几次尝试）。
2. `claim` / `already`：记录实际签到结果。
3. 失败时记录错误信息；重试耗尽时额外记录一条失败 `schedule` 日志。

### 数据库

统一账号数据库默认为应用数据目录下的 `checkin-hub.sqlite3`（见「环境变量」），也可用 `--db` 或 `CHECKIN_HUB_DB` 指定。

核心表：

- `accounts`：账号、登录态、状态和定时配置。
- `checkin_logs`：登录、状态刷新、签到和调度日志。
- `settings`：运行级配置。

账号库会保存 access token、refresh token 或加密后的平台登录态。请确保：

- 不把数据库提交到 Git。
- 不把数据库复制到公共目录。
- 不把日志、数据库或 API 响应截图发给别人。
- 定期备份时也仅保存在受控设备中。

### 安全约定

- 服务只监听 `127.0.0.1`。
- `.gitignore` 已排除本地数据库、截图、浏览器调试数据和本机分析文档。
- WorkBuddy 用量 Cookie 只用于当次查询，前端提交后立即清空输入框。
- Trae 登录态使用加密容器保存，续期后自动回写。
- 请不要在 issue、日志、聊天或截图中粘贴 token、refresh token、Cookie 或完整账号数据库。

### 测试

```bash
python -m unittest -v test_qoder_status.py test_trae_usage.py test_workbuddy_usage.py test_trae_login_callback.py
python -m compileall -q web_checkin
cd frontend && npm run lint   # 前端类型检查
```

### 项目结构

```text
.
├── pyproject.toml                # 打包配置（命令入口：web-checkin）
├── web_checkin/                  # Python 包
│   ├── __init__.py
│   ├── __main__.py               # python -m web_checkin
│   ├── cli.py                    # 命令行入口，参数解析 + 启动 uvicorn
│   ├── paths.py                  # 静态资源 / 数据目录 / 数据库路径解析
│   ├── app.py                    # FastAPI 服务、路由、调度器
│   ├── account_store.py          # 统一账号和日志存储
│   ├── trae_tool.py              # Trae 登录、状态、签到
│   ├── trae_usage.py             # Trae 用量查询与聚合
│   ├── workbuddy_tool.py         # WorkBuddy 登录、状态、签到
│   ├── workbuddy_usage.py        # WorkBuddy 用量查询脚本
│   ├── workbuddy_common.py       # WorkBuddy 公共请求与存储
│   ├── workbuddy_login.py        # WorkBuddy 独立登录脚本
│   ├── workbuddy_checkin.py      # WorkBuddy 独立签到脚本
│   ├── qoder_tool.py             # Qoder Web Hub 接入
│   ├── qoder_login.py            # Qoder 设备码登录
│   ├── qoder_checkin.py          # Qoder 独立签到脚本
│   └── static/                   # 前端构建产物（由 npm run build 生成）
│       ├── index.html
│       └── assets/
├── frontend/                     # 界面源码（React + Vite + Tailwind）
│   ├── src/
│   │   ├── App.tsx               # 页面组装
│   │   ├── components/           # 顶部栏、统计、账号卡片、用量、日志、弹窗
│   │   ├── services/api.ts       # 对接 FastAPI 的数据访问层
│   │   └── types/index.ts        # 与后端对齐的类型定义
│   └── vite.config.ts            # 构建输出到 ../web_checkin/static
├── flutter_app/                   # Flutter 跨端客户端（主线）
│   ├── lib/src/services/       # 平台协议实现（workbuddy / trae / qoder）
│   ├── lib/src/screens/        # 界面（概览 / 账号 / 用量 / 会话 / 设置）
│   └── tools/package/          # deb / rpm 打包脚本
├── workbuddy-tools/              # 独立 Node.js 工具集
├── test_trae_usage.py            # Trae 用量测试
├── test_trae_login_callback.py   # Trae 登录本地回调回归测试
├── test_workbuddy_usage.py       # WorkBuddy 用量测试
└── test_qoder_status.py          # Qoder 状态解析测试
```

> `web_checkin/static/` 是前端构建产物，请勿手工编辑；修改界面请改 `frontend/src/` 后重新 `npm run build`。

包内的独立脚本（如 Qoder / WorkBuddy 登录、签到、用量）改用模块方式运行，例如：

```bash
python -m web_checkin.qoder_checkin --list
python -m web_checkin.trae_usage --start 2026-10-01 --end 2026-10-15
```

### WorkBuddy 独立工具

`workbuddy-tools/` 提供独立 Node.js 脚本，适合在没有启动 Web Hub 的场景使用。详细参数见：

```text
workbuddy-tools/README.md
```

这些工具也只应访问你自己授权的账号，并同样需要注意数据库和登录态安全。

### 常见问题

#### 页面打开后余额为空

可能是平台接口临时失败或登录态过期。点击账号卡片中的“刷新状态”，或先重新登录对应平台。

#### Trae 用量查询失败

确认账号仍能正常签到，并确认 Trae 登录态没有过期。当前接口分页必须使用 `page_size=20`；如果平台后续调整接口，需要重新核对请求结构。

#### WorkBuddy 用量查询失败

WorkBuddy 用量接口依赖浏览器 Cookie。Cookie 过期、账号会话失效、请求头不完整或站点前端变更都可能导致失败。请重新复制新的 Cookie，并不要把它提交到仓库。

#### Qoder 登录不可用

Qoder 登录脚本已随项目内置。若导入旧登录态失败，请确认 `QODER_DATA_DIR/qoder_auth.json` 存在且 refreshToken 未过期；也可以直接重新执行 Web 登录。

### 免责声明

本项目与 WorkBuddy、Trae、Qoder 官方没有隶属关系。接口和页面可能随平台更新变化。使用本项目时请遵守目标平台的服务条款和所在地区法律。
