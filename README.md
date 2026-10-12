# Web Check-in Hub

WorkBuddy / Trae / Qoder 多账号签到与用量查询中枢。项目提供一个 FastAPI 本地 Web 服务，把各平台的账号状态、余额、签到结果和用量明细放在同一个界面中管理。

> 仅供个人管理自己拥有授权的账号。请不要用于批量注册、共享账号、绕过平台限制或任何违反平台服务条款的场景。

## 功能概览

### 账号与状态

- WorkBuddy、Trae、Qoder 账号分别走平台官方授权流程。
- 登录态写入本地 SQLite 数据库，数据库默认 `0600` 权限。
- 支持账号启用 / 停用 / 删除。
- 页面打开后自动刷新所有账号的实时余额。
- WorkBuddy 使用平台返回的 `today_checked_in`，Trae 使用 `checked_in`；Qoder 没有明确“今日已签”字段，因此只有 `CLAIMED` 活动或当天本地成功领取记录才会显示“今日已签到”。
- 每个账号可配置独立的每日签到时间。
- 服务重启后，如果当天设定时间已过且尚未执行，会补跑一次签到。

### 签到与日志

- 支持单账号签到、全部账号签到。
- 每个账号的定时触发会生成 `schedule` 日志。
- 实际签到结果会生成 `claim` / `already` 日志。
- 登录、状态刷新、签到失败信息都会记录在执行日志中。

### WorkBuddy 用量

- 使用浏览器 Cookie 查询 WorkBuddy 积分消耗明细。
- 展示每日积分趋势、模型分布和分页请求明细。
- 支持导出 CSV。
- Cookie 只保存在当前查询请求内存中，不会写入账号库或日志。

### Trae 用量

- 复用统一账号库中的 Trae 登录态查询积分明细。
- 展示总消耗、每日曲线、模型分布和请求明细。
- 临期登录态会自动续期并加密回写。
- 用量接口分页使用 `page_size=20`，该值是当前验证可用的稳定分页大小。

## 界面结构

页面自上而下分为：

1. 账号统计卡片区。
2. 添加账号与独立定时说明。
3. 账号管理。
4. WorkBuddy 积分消耗明细。
5. Trae 积分用量。
6. 执行日志。

## 环境要求

- Python 3.11 或更高版本。
- 现代浏览器。
- 各平台的官方授权页面可正常访问。

## 安装

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

依赖包括 FastAPI、Uvicorn 和 cryptography。

## 启动

```bash
python -m uvicorn app:app --host 127.0.0.1 --port 8320
```

打开：

```text
http://127.0.0.1:8320
```

服务默认只监听本机地址。不要直接把无认证的管理端暴露到公网。如需局域网访问，请自行添加反向代理、访问控制和 HTTPS。

## 环境变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `CHECKIN_HUB_DB` | 统一账号数据库路径 | `checkin-hub.sqlite3` |
| `TRAE_IDENTITY_PATH` | Trae 设备指纹文件路径 | 项目目录下的 `trae-identity.json` |
| `TRAE_LEGACY_DB` | 可选的旧 Trae 数据库路径 | `~/.trae-checkin/trae_checkin.db` |
| `QODER_DATA_DIR` | Qoder 登录态和机器 ID 目录 | `~/.qoder-checkin` |

Qoder 登录脚本已内置在项目内。服务启动时会尝试从 `QODER_DATA_DIR/qoder_auth.json` 导入既有登录态；目录不存在或还没有登录态时，不影响 WorkBuddy / Trae 启动。

## 主要 API

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

## 定时任务

每个账号保存独立的：

- `schedule_enabled`
- `schedule_time`
- `schedule_last_date`

调度器每 10 秒检查一次。当账号启用、定时开启、当天未执行且当前时间已达到设定时间时，会触发一次签到。

日志顺序：

1. `schedule`：记录定时任务已触发。
2. `claim` / `already`：记录实际签到结果。
3. 失败时记录错误信息。

## 数据库

统一账号数据库默认为项目目录下的 `checkin-hub.sqlite3`。

核心表：

- `accounts`：账号、登录态、状态和定时配置。
- `checkin_logs`：登录、状态刷新、签到和调度日志。
- `settings`：运行级配置。

账号库会保存 access token、refresh token 或加密后的平台登录态。请确保：

- 不把数据库提交到 Git。
- 不把数据库复制到公共目录。
- 不把日志、数据库或 API 响应截图发给别人。
- 定期备份时也仅保存在受控设备中。

## 安全约定

- 服务只监听 `127.0.0.1`。
- `.gitignore` 已排除本地数据库、截图、浏览器调试数据和本机分析文档。
- WorkBuddy 用量 Cookie 只用于当次查询，前端提交后立即清空输入框。
- Trae 登录态使用加密容器保存，续期后自动回写。
- 请不要在 issue、日志、聊天或截图中粘贴 token、refresh token、Cookie 或完整账号数据库。

## 测试

```bash
python -m unittest -v test_qoder_status.py test_trae_usage.py test_workbuddy_usage.py
python -m py_compile account_store.py app.py qoder_login.py qoder_checkin.py qoder_tool.py trae_tool.py trae_usage.py workbuddy_tool.py workbuddy_usage.py
node --check static/app.js
```

## 项目结构

```text
.
├── app.py                        # FastAPI 服务、路由、调度器
├── account_store.py              # 统一账号和日志存储
├── static/
│   ├── index.html                # 页面结构
│   ├── app.js                    # 前端交互和图表
│   └── styles.css                # 界面样式
├── trae_tool.py                  # Trae 登录、状态、签到
├── trae_usage.py                 # Trae 用量查询与聚合
├── workbuddy_tool.py             # WorkBuddy 登录、状态、签到
├── workbuddy_usage.py            # WorkBuddy 用量查询脚本
├── workbuddy_common.py           # WorkBuddy 公共请求与存储
├── qoder_login.py                # Qoder 设备码登录（Python）
├── qoder_checkin.py              # Qoder 独立签到脚本（Python）
├── qoder_tool.py                 # Qoder Web Hub 接入
├── workbuddy-tools/              # 独立 Node.js 工具集
├── test_trae_usage.py            # Trae 用量测试
└── test_workbuddy_usage.py       # WorkBuddy 用量测试
```

## WorkBuddy 独立工具

`workbuddy-tools/` 提供独立 Node.js 脚本，适合在没有启动 Web Hub 的场景使用。详细参数见：

```text
workbuddy-tools/README.md
```

这些工具也只应访问你自己授权的账号，并同样需要注意数据库和登录态安全。

## 常见问题

### 页面打开后余额为空

可能是平台接口临时失败或登录态过期。点击账号卡片中的“刷新状态”，或先重新登录对应平台。

### Trae 用量查询失败

确认账号仍能正常签到，并确认 Trae 登录态没有过期。当前接口分页必须使用 `page_size=20`；如果平台后续调整接口，需要重新核对请求结构。

### WorkBuddy 用量查询失败

WorkBuddy 用量接口依赖浏览器 Cookie。Cookie 过期、账号会话失效、请求头不完整或站点前端变更都可能导致失败。请重新复制新的 Cookie，并不要把它提交到仓库。

### Qoder 登录不可用

Qoder 登录脚本已随项目内置。若导入旧登录态失败，请确认 `QODER_DATA_DIR/qoder_auth.json` 存在且 refreshToken 未过期；也可以直接重新执行 Web 登录。

## 免责声明

本项目与 WorkBuddy、Trae、Qoder 官方没有隶属关系。接口和页面可能随平台更新变化。使用本项目时请遵守目标平台的服务条款和所在地区法律。
