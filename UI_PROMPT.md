# “签到中枢”界面重生成提示词集

本文件用于把当前 Web 界面（`static/index.html` + `static/app.js` + `static/styles.css`）**重新生成**为一套新界面。
它包含：总纲提示词、分模块提示词、设计方向提示词、验收提示词，以及附录 A/B 的 API 与数据字典（提示词里引用的“附录 A/B”即本文件末尾）。

用法：先把 **P0 总纲** + **附录 A/B** 一起发给模型作为上下文，再按需追加 P1～P11 中的单个模块提示词逐块生成或迭代。

---

## P0 · 总纲（必发上下文）

> 你是一名资深前端工程师兼产品设计师。请为下面这个**本地运行的账号签到管理应用**重新实现整套界面。
>
> **产品定位**：一个只在本机运行（`127.0.0.1`）的个人工具，把多个 AI 平台账号（WorkBuddy、Trae、Qoder）的登录态、余额/签到状态、每日定时签到、积分用量明细和执行日志集中在一个页面里管理。
>
> **技术约束**：
> - 前端是**纯静态**页面，由 FastAPI 通过 `/static` 提供，**没有构建步骤、没有 npm 依赖、可完全离线运行**。除非我另外说明，请输出可直接放进 `static/` 的原生 `index.html` / `app.js` / `styles.css`（原生 JS + CSS，不用框架，不用 CDN）。
> - 图表请用**原生 Canvas 或纯 CSS**手绘（当前是手绘折线图），不要引入图表库。
> - 所有数据来自**附录 A** 的 REST 接口；字段定义见**附录 B**。不要臆造接口或字段。数量以接口返回为准。
> - 页面为**深色主题、中文界面**、桌面优先、在窄屏下退化可用。
>
> **必须覆盖的功能（概览）**：
> 1. 顶部栏：品牌、`刷新余额`（批量）、`全部签到`。
> 2. 统计卡片：账号总数、已启用、今日已签、已设定时。
> 3. 添加账号：WorkBuddy / Trae / Qoder 三个登录入口，各自打开授权流程。
> 4. 独立定时说明区。
> 5. 账号管理：按平台分组的账号卡片，含余额/活动状态、签到状态、最近签到、每日定时开关与时间、刷新/签到/启停/删除。
> 6. WorkBuddy 积分消耗明细：日期范围 + 临时 Cookie 查询、每日趋势折线图、请求明细分页表、导出 CSV。
> 7. Trae 积分用量：日期范围查询、汇总、每账号趋势图 + 模型消耗 + 明细分页。
> 8. 执行日志列表。
> 9. 登录授权弹窗 + Toast 提示。
>
> **输出要求**：给出完整的三个文件内容；组件化组织 JS；对加载态、空态、错误态、危险操作二次确认都有明确处理；关键交互必须有可访问性标注（`aria-*`、`label`、`role`）。

---

## P1 · 页面整体框架与信息架构

> 基于 P0 与附录 A/B，请先实现**页面骨架与信息架构**（不要求填满交互细节）：
>
> 页面自上而下固定顺序：
> 1. 顶部栏（品牌 + 批量操作）。
> 2. 统计卡片行（4 张）。
> 3. 两栏区块：左「添加账号」、右「独立定时说明」。
> 4. 账号管理区：按 `workbuddy → trae → qoder` 顺序分组，每组一个分组标题（图标 + 平台名 + 账号数），组内是账号卡片网格。
> 5. WorkBuddy 积分消耗明细区。
> 6. Trae 积分用量区。
> 7. 执行日志区。
>
> 要求：语义化标签（`header/section/article/main`）、`main` 限宽居中、区块之间有清晰层级与留白、每区有标题与副说明。给出布局用 CSS（可用 Grid）。无需联网字体。

---

## P2 · 顶部栏 + 统计卡片

> 实现顶部栏与统计卡片：
>
> **顶部栏**
> - 左侧：方形品牌标（文字「签」）+ 标题「签到中枢」+ 副标题「WorkBuddy / Trae / Qoder · 本地账号动态管理」。
> - 右侧：一个「本机授权账号」样式徽标（带小圆点），`刷新余额`（次要按钮）、`全部签到`（主按钮）。
> - `刷新余额` → `POST /api/status`，完成后用返回值里 `results[].ok === false` 的数量提示「刷新完成，N 个失败 / 全部状态已刷新」。
> - `全部签到` → `POST /api/checkin`，按 `results[].ok` 统计成功/失败并提示。
> - 两个按钮点击期间禁用（防重复提交）。
>
> **统计卡片**（数据来自 `GET /api/accounts`）
> - 账号总数：`accounts.length`，副标题「WorkBuddy + Trae + Qoder」。
> - 已启用：`accounts.filter(a => a.enabled).length`，副标题「参与定时任务」。
> - 今日已签：按附录 B 各平台“今日是否已签”的判定规则计数，副标题「平台实时签到状态」。
> - 已设定时：`accounts.filter(a => a.schedule_enabled).length`，副标题「账号独立每日执行」。
> - 首次加载时数字应能平滑更新，不要闪现 `NaN`/`undefined`。

---

## P3 · 添加账号 + 独立定时说明

> 实现「添加账号」面板：三张并排的平台登录按钮（WorkBuddy「浏览器 OAuth 授权」/ Trae「Web PKCE 授权」/ Qoder「设备码 PKCE 授权」）。
> - 点击分别调用 `POST /api/login/workbuddy`、`POST /api/login/trae`、`POST /api/login/qoder`。
> - 拿到 `{ id, auth_url, message, status }` 后：打开授权页（新标签），同时弹出登录弹窗（见 P8），并用 `id` 轮询 `GET /api/login/{provider}/{id}`。
> - 面板副标题：「登录后自动写入本地 SQLite」。
>
> 同时实现右侧「独立定时」说明面板：
> - 标题「独立定时」，副标题「每张账号卡片可设置自己的每日签到时间」。
> - 一条提示：「按本机时区执行；错过时间后当日补跑一次」。
> - 这是一个说明性卡片，不含输入控件。

---

## P4 · 账号卡片（核心模块）

> 实现账号卡片。**按平台分组展示**，组头为平台图标 + 平台名 + 「N 个账号」。
> 卡片数据来自 `GET /api/accounts`（字段见附录 B），状态语义必须严格按附录 B 的规则渲染。
>
> **卡片结构**（自上而下）：
> 1. 身份区：平台图标 + 账号名（`display_name || label || external_id`）+ 一行「平台名 · external_id」；右上角状态徽标：启用显示「运行中」，停用显示「已停用」。
> 2. 余额/活动区（标题随平台变化）：
>    - WorkBuddy / Trae：标题「当前可用余额」，主数值为剩余积分；`credits_left === -1` 显示「不限」；`credits_total === -1` 不显示总额，否则显示「剩余 / 总额 credits」。
>    - Qoder：标题「活动状态」，主数值「{claimableCount} 可领取」，附带「/ {campaignCount} 活动」。
>    - 底部小字：有 `last_status_at` 时显示「更新于 {时间}」；首次自动刷新进行中显示「正在获取平台实时额度…」；否则显示「点击刷新余额获取最新数据」。
> 3. 指标区（三列）：
>    - 「签到状态」：按附录 B 规则得到文案（今日已签到/今日未签到/暂无签到活动/无可领取活动），已签到时高亮。
>    - 「连续/奖励」：WorkBuddy 显示 `streak_days` + 「 天」；Trae 显示 `extra_credits`；Qoder 显示 `claimableCount`（标签「可领取」）。
>    - 「最近签到」：`last_checkin_at` 格式化，否则「暂无记录」。
> 4. 定时控件：「每日自动签到」标签 + 副标题（开启显示「每天 HH:MM 执行」，关闭显示「当前未启用」）+ 时间选择器（`<input type="time">`）+ 一个开关按钮（显示「定时开 / 定时关」）+ 一个「保存」按钮。
> 5. 操作行：`刷新余额`（Qoder 文案为「刷新状态」）、`立即签到`、`暂停账号/启用账号`、`移除`（危险色）。
>
> **交互**：
> - 保存时间 → `POST /api/accounts/{id}/schedule`，body `{ enabled: 当前 schedule_enabled, time: 输入值 }`；成功后按开启与否给不同提示。
> - 切换定时开关 → 同一接口，`enabled` 取反，`time` 取当前输入框值。
> - 刷新余额/状态 → `POST /api/accounts/{id}/status`。
> - 立即签到 → `POST /api/accounts/{id}/checkin`，用 `result.message` 提示，按 `ok` 决定成功/失败样式。
> - 暂停/启用 → `POST /api/accounts/{id}/enable?enabled=<取反>`。
> - 移除 → 先二次确认（如 `confirm`），再 `DELETE /api/accounts/{id}`。
> - 每个按钮操作期间禁用自身；操作完成后重新拉取账号列表与日志。
> - 停用账号的卡片整体降低不透明度并在视觉上区分。
> - 无账号时显示空态：「还没有授权账号 / 使用上方官方授权登录 WorkBuddy、Trae 或 Qoder」。
> - 所有来自后端/平台的文本都要做 HTML 转义后再插入 DOM（防止注入）。

---

## P5 · WorkBuddy 积分消耗明细

> 实现 WorkBuddy 用量区块。数据来自 `POST /api/workbuddy/usage`（body 见附录 A），记录字段见附录 B。
>
> **表单**：开始日期、结束日期（`<input type="date">`，默认最近 7 天：今天往前 6 天到今天就）、浏览器 Cookie（`textarea`，必填，`placeholder` 提示从开发者工具复制请求头）、`查询明细` 按钮。
> - **安全**：Cookie 只用于当次查询；提交后立即清空输入框且**不得持久化、不得回显、不得写日志**；UI 上要明确提示这一点。
> - 提交时按钮禁用并显示「查询中…」，重复提交要防止。
> - 后端约束：单次查询日期范围最多 31 天（超出会返回错误，需把错误信息提示给用户）。
>
> **结果区**（左右两块）：
> 1. 「每日积分趋势」：用 Canvas 手绘折线图，把记录按天聚合（`requestTime` 的日期部分）出每日积分合计；Y 轴 4 条参考线并显示数值，X 轴显示 `MM-DD`（点少时全显示，点多时只显示首尾）；右上角显示「N 天 · 合计 credits」。无数据时显示「暂无数据」。窗口尺寸变化时重绘。
> 2. 「请求明细」：表格列「请求时间 / 请求名 / 模型 / 客户端 / 积分」。带分页工具栏：每页条数（20/50/100，默认 20）、上一页、`第 X / Y 页`、下一页。空结果显示「该日期范围没有明细」。
>
> 右上角显示记录条数，并提供「导出 CSV」按钮（无数据时禁用）：导出当前查询的全部记录，UTF-8 带 BOM，文件名含日期范围。

---

## P6 · Trae 积分用量

> 实现 Trae 用量区块。数据来自 `POST /api/trae/usage`（body 见附录 A），返回结构见附录 B。
>
> **表单**：开始日期、结束日期（默认最近 7 天）、`查询用量` 按钮。查询中按钮禁用并显示「查询中…」。
> - 后端约束：日期范围最多 91 天；`page_size` 固定为 20（这是接口稳定值，不要改）。
>
> **汇总区**：查询后显示「区间积分消耗」大数值 + 「N 次请求」+ 「M 个账号成功」；若有失败账号，用警示色显示「K 个账号失败」。若无成功数据：有账号显示「所选日期范围内没有用量记录」，无账号显示「当前没有 Trae 授权账号」。区块右上角显示「成功数 / 总数 个账号 · N 次请求」。
>
> **每账号卡片**（按返回 `accounts[]` 逐个渲染）：
> - 失败账号：显示账号名、external_id 和错误信息（警示色），不显示图表。
> - 成功账号：
>   - 头部：账号名 + 「external_id · N 次请求」+ 右侧总积分。
>   - 每日趋势：Canvas 折线图（数据来自 `daily[]`）。
>   - 模型消耗：取 `models[]` 前 5 个列成列表（模型名 / 积分 / 次数）；无则「暂无模型明细」。
>   - 明细折叠区（`<details>`）：摘要「查看 N 条用量明细」，展开后是分页表，列「时间 / 模型 / 客户端 / 积分 / 使用记录」，每页 20 条，带上一页/下一页与页码。
> - 窗口尺寸变化时重绘所有 Trae 图表。

---

## P7 · 执行日志

> 实现执行日志区：`GET /api/logs?limit=80`，返回见附录 A/B。
> - 标题「执行日志」+ 右上角「刷新日志」按钮。
> - 每条日志一行：状态图标（成功 ✓ / 失败 ✕，区分颜色）、标题「{display_name || label || provider} · {action}」、消息文本、右侧格式化时间。
> - `message` 为空时显示「无详细信息」。
> - 空列表显示「暂无日志」。
> - `action` 常见值：`login`、`status`、`checkin`、`claim`、`already`、`skip`、`claimed`、`schedule`。若有未知 action 也要能正常展示（不要崩）。

---

## P8 · 登录弹窗 + Toast

> **登录弹窗**（模态）：
> - 标题按平台显示（WorkBuddy / Trae / Qoder 登录）。
> - 正文显示后端返回的 `message`（授权等待中/正在换取令牌/结果）。
> - 一个「授权链接」展示框（`code`）+ 三个操作：「打开授权页」（新标签打开 `auth_url`）、「复制链接」（复制到剪贴板并 Toast 反馈）、「关闭」。
> - 打开弹窗后开始轮询 `GET /api/login/{provider}/{id}`（约 1.2 秒一次），把最新 `message` 显示出来。
> - 当 `status` 变为 `success` 或 `failed` 时：停止轮询、显示对应 Toast、短暂延迟后关闭弹窗、重新加载账号与日志；`success` 时再触发一次「刷新余额」。
> - 关闭弹窗时要清除轮询定时器；轮询请求出错也要停止并提示。
> - 支持键盘 `Esc` 关闭、焦点管理、`role="dialog"` 与 `aria-modal="true"`。
>
> **Toast**：
> - 位于右下或右上固定容器，自动进入/退出动画，约 3.6 秒后自动消失。
> - 三种类型：成功（ok）、警示（warn）、错误（err），用颜色区分。
> - 不得使用 `alert`。

---

## P9 · 视觉与设计方向（可选，按需替换整段）

> 在满足 P0～P8 功能与信息架构的前提下，重新做一版视觉。要求：
> - **深色主题**，中文无衬线字体栈（`PingFang SC`/`Microsoft YaHei`/`Noto Sans SC`/`system-ui`）。
> - 用 CSS 变量集中管理色板与圆角、缓动，便于整体换肤。
> - 当前参考色板（可保留或重设，但请保持同类“深底 + 薄荷绿强调”气质）：
>   `--bg:#0a0e12`、`--surface:#11171c`、`--surface-raised:#151d23`、`--surface-soft:#192229`、`--line:rgba(211,225,225,.09)`、`--text:#edf3f1`、`--muted:#8c9b9c`、`--dim:#607071`、`--mint:#9be2c5`、`--mint-strong:#57c89c`、`--blue:#8bc6ee`、`--amber:#eac98a`、`--red:#ed9a97`、`--radius-lg:22px`、`--radius-md:15px`、`--ease:cubic-bezier(.2,0,0,1)`。
> - 背景使用极淡的径向渐变光晕，卡片用细描边 + 柔和阴影，避免过度装饰。
> - 平台可用各自识别色做轻量点缀（WorkBuddy/Trae/Qoder），但不要喧宾夺主。
> - 定义清晰的层级：`h1 22px / h2 16px / 正文 14px / 辅助 12px`，标题用负字距（如 `letter-spacing:-.03em`）。
> - 交互态：hover/active/focus-visible 都要有；`focus-visible` 用强调色描边且 `outline-offset` 明显。
> - 卡片网格在小屏折叠为单列；表格在窄屏可横向滚动。
> - 可加入尊重 `prefers-reduced-motion` 的动效降级。
>
> 请同时给出你选择这套视觉的理由（1～2 句）。

---

## P10 · 交互、状态与边界（务必逐条落地）

> 请逐条检查并实现：
> 1. **首次进入**：先并行加载账号与日志；若存在账号，自动触发一次 `POST /api/status`（刷新余额），期间卡片余额区显示加载态，完成后重新拉取账号与日志。
> 2. **加载态**：所有异步操作都要有可见的进行中反馈（按钮文案/禁用、骨架或占位文案）。
> 3. **空态**：无账号、无日志、无用量的空态文案要分别设计。
> 4. **错误态**：`api()` 统一处理——非 2xx 时优先取响应体 `detail` / `message`，否则回退 `HTTP {status}`；错误以 Toast 或区块内错误文案呈现，不能让界面卡死。
> 5. **危险操作**：删除账号必须二次确认；按钮在处理期间禁用。
> 6. **并发/防抖**：批量刷新、批量签到、查询、登录轮询等避免重复触发。
> 7. **数据健壮性**：任何字段缺失（`null`/`undefined`）都要有兜底显示（如「--」/「暂无记录」/「未标记」），不得抛出渲染异常。
> 8. **安全**：插入 DOM 的文本一律转义；Cookie 不落地、不回显、不进日志或 URL。
> 9. **可访问性**：图表 `canvas` 加 `role="img"` + `aria-label`；动态区域用 `aria-live`；纯图标按钮加 `aria-label`；时间/日期输入有关联 `label`。
> 10. **可维护性**：JS 组件化、把平台相关的状态判定与文案抽成函数；常量（默认日期范围、分页大小、轮询间隔、Toast 时长）集中定义。

---

## P11 · 自检 / 验收提示词（生成后回贴使用）

> 请对照以下清单审查你刚生成的界面，逐项给出「通过 / 不通过 + 原因 + 修复」：
> - [ ] 覆盖 P0 列出的全部 9 个功能区，且顺序与信息架构一致。
> - [ ] 三平台状态语义正确：WorkBuddy 用 `today_checked_in`；Trae 用 `checked_in`；Qoder 无“今日已签”字段，只有 `claimedCount > 0` 或“本地当天成功领取”才算已签，并区分「暂无签到活动」「无可领取活动」。
> - [ ] 余额中 `-1` 一律显示「不限」，`credits_total === -1` 不显示总额。
> - [ ] 所有接口路径/方法/请求体与附录 A 完全一致，无臆造接口。
> - [ ] 定时控件能同时反映与修改 `schedule_enabled` 与 `schedule_time`，且保存/切换都调用 `/schedule`。
> - [ ] WorkBuddy 用量 Cookie 查询后即清空、不外泄；导出 CSV 为 UTF-8 BOM。
> - [ ] 个图/表在窗口 resize 后正确重绘。
> - [ ] 加载/空/错误三态齐全；删除有二次确认；无 `alert`。
> - [ ] 无框架、无 CDN、无构建步骤，可直接放入 `static/` 运行。
> - [ ] 关键可访问性属性齐全。
>
> 最后额外给出一段「已知取舍与后续可改进点」。

---

## 附录 A · REST 接口契约

服务默认：`http://127.0.0.1:8320`，静态资源挂载在 `/static`。除 `GET /` 与静态资源外均为 JSON。

| 方法 | 路径 | 请求体 | 响应 | 说明 |
|---|---|---|---|---|
| GET | `/` | — | `index.html` | 首页 |
| GET | `/api/health` | — | `{ "ok": true, "time": <int> }` | 健康检查 |
| GET | `/api/accounts` | — | `{ "accounts": [Account] }` | 账号列表（不含凭据） |
| GET | `/api/logs?limit=80` | — | `{ "logs": [Log] }` | 执行日志，`limit` 范围 1–500 |
| POST | `/api/status` | — | `{ "results": [{ "account_id", "provider", "ok", "status"?, "message"? }] }` | 刷新全部账号状态/余额 |
| POST | `/api/accounts/{id}/status` | — | `{ "ok": true, "status": {...} }`；失败 `400 { "detail" }` | 刷新单账号状态 |
| POST | `/api/accounts/{id}/checkin` | — | `{ "ok": <bool>, "result": { "account_id", "provider", "display_name", "ok", "message", ... } }` | 单账号签到 |
| POST | `/api/checkin` | — | `{ "ok": <bool>, "results": [ <result> ] }` | 全部启用账号签到 |
| POST | `/api/accounts/{id}/schedule` | `{ "enabled": <bool>, "time": "HH:MM" }`（time 正则 `^([01]\d|2[0-3]):([0-5]\d)$`，违规 422） | `{ "ok": true, "enabled", "time" }` | 设置独立定时 |
| POST | `/api/accounts/{id}/enable?enabled=true\|false` | — | `{ "ok": true, "enabled": <bool> }` | 启用/停用 |
| DELETE | `/api/accounts/{id}` | — | `{ "ok": true }` | 删除账号 |
| POST | `/api/login/workbuddy` | `{ "label"?, "endpoint"?, "platform"?, "auto_browser"?, "timeout"? }` | `{ "id", "auth_url", "message", "status", ... }` | 启动 WorkBuddy 登录 |
| POST | `/api/login/trae` | `{ "label"?, "auto_browser"?, "timeout"? }` | 同上 | 启动 Trae 登录 |
| POST | `/api/login/qoder` | `{ "label"?, "auto_browser"?, "timeout"? }` | 同上 | 启动 Qoder 登录 |
| GET | `/api/login/{provider}/{login_id}` | — | `{ "status": "waiting"\|"exchanging"\|"success"\|"failed", "message", "account"?: { "id", "name", "external_id" } }` | 轮询登录状态 |
| POST | `/api/workbuddy/usage` | `{ "start", "end", "cookie", "user_agent" }`（日期 `YYYY-MM-DD`，范围 ≤31 天；`start/end` 长度必须 10） | `{ "count": <int>, "records": [UsageRecord] }`；失败 `400 { "detail" }` | WorkBuddy 用量（Cookie 临时） |
| POST | `/api/trae/usage` | `{ "start", "end", "account_id"? }`（范围 ≤91 天） | `{ "start", "end", "accounts": [TraeUsageAccount], "totalCredits", "requestCount", "failedCount" }`；失败 `400 { "detail" }` | Trae 用量 |

## 附录 B · 数据字典

### Account（`/api/accounts` 返回项）
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int | 主键 |
| `provider` | `"workbuddy"｜"trae"｜"qoder"` | 平台 |
| `external_id` | str | 平台侧账号 ID |
| `display_name` | str | 展示名（可能为空） |
| `label` | str | 备注名（可能为空） |
| `endpoint` | str | 平台接入点 |
| `enabled` | bool | 是否启用（停用则不参与定时） |
| `last_status` | object \| null | 最近一次平台状态，结构见下 |
| `last_status_at` | int(epoch 秒) \| null | 状态更新时间 |
| `last_checkin_at` | int(epoch 秒) \| null | 最近签到时间 |
| `last_checkin_ok` | bool \| null | 最近签到是否成功 |
| `last_checkin_message` | str \| null | 最近签到消息 |
| `schedule_time` | `"HH:MM"` | 每日签到时间（默认 `09:00`） |
| `schedule_enabled` | bool | 是否开启独立定时 |
| `schedule_last_date` | `"YYYY-MM-DD"` \| null | 当日任务完成日期（成功或重试耗尽后写入） |
| `created_at` / `updated_at` | int(epoch 秒) | 时间戳 |

> 注：`credential`（登录态）不会出现在接口响应中。所有时间戳均为**秒**级 epoch（前端需 ×1000 转毫秒；兼容毫秒值）。

### 各平台 `last_status` 结构与“今日已签”判定
- **workbuddy**：`{ active: bool, today_checked_in: bool, streak_days: int, credits_left: int, credits_total: int, usage: {...} }`
  - 今日已签 = `today_checked_in`；余额 `credits_left`/`credits_total`（`-1` 表示不限）。
- **trae**：`{ checked_in: bool, credits_left: int, credits_total: int, extra_credits: int }`
  - 今日已签 = `checked_in`；余额同上；「连续/奖励」位置显示 `extra_credits`。
- **qoder**：`{ campaignCount: int, claimableCount: int, claimedCount: int, checked: bool }`
  - **平台无明确“今日已签”字段**。判定：`claimedCount > 0`，或（`last_checkin_ok === true` 且 `last_checkin_at` 为本地今天）→ 「今日已签到」；否则「今日未签到」。
  - 特例文案：`campaignCount === 0` → 「暂无签到活动」；否则若 `claimableCount === 0` 且未签 → 「无可领取活动」。
  - 余额位改显示「活动状态」：`{claimableCount} 可领取 / {campaignCount} 活动`；「连续/奖励」位显示 `claimableCount`（标签「可领取」）。

### Log（`/api/logs` 返回项）
`{ id, account_id, display_name, label, provider, action, ok: bool, code: int|null, message: str, created_at: int(epoch 秒) }`
`action` ∈ `login`｜`status`｜`checkin`｜`claim`｜`already`｜`skip`｜`claimed`｜`schedule`。

### UsageRecord（WorkBuddy 用量，`records[]`）
`{ requestTime: str, requestName: str, model: str, client: str, credit: number }`
- `requestTime` 形如 `"YYYY-MM-DD HH:MM:SS"`；`model`/`client` 缺失时后端填「未标记」。

### TraeUsageAccount（Trae 用量，`accounts[]`）
- 成功：`{ ok: true, accountId: int, externalId: str, name: str, total: int, requestCount: int, totalCredits: number, daily: [{ date: "YYYY-MM-DD", credits: number, requests: int }], models: [{ model: str, credits: number, requests: int }], items: [TraeUsageItem] }`
- 失败：`{ ok: false, accountId, externalId, name, message: str }`
- `TraeUsageItem`：`{ time: "YYYY-MM-DD HH:MM:SS", day: "YYYY-MM-DD", sessionId, record, model, source, plan, credits: number, amount, costMoney, tokens: { input, output, cacheRead, cacheWrite } }`
- 外层汇总：`totalCredits`（成功账号合计）、`requestCount`（成功账号合计请求数）、`failedCount`。

### 业务规则（界面必须遵守）
1. 定时任务：账号 `enabled` 且 `schedule_enabled` 才生效；到 `schedule_time` 触发；失败会按固定间隔重试（默认 3 次、间隔 300 秒）；服务重启后当天已过点且未完成会补跑一次。界面只需正确展示与修改 `schedule_enabled`/`schedule_time`，不需要实现调度。
2. WorkBuddy 用量：日期范围 ≤ 31 天；Cookie 仅本次查询内存使用，**绝不持久化**。
3. Trae 用量：日期范围 ≤ 91 天；分页大小固定 20。
4. 服务仅监听本机，界面不得引导把手管理端暴露到公网。
