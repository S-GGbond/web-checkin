# 签到中枢 · Flutter 跨端客户端

WorkBuddy / Trae / Qoder 多账号签到与额度查询的独立 Flutter 应用。界面与交互完全按 Flutter 重做，
不复用 Web 端的页面结构与样式；平台线协议与 Python 版 `web_checkin/` 保持一致，可读写同一份
`checkin-hub.sqlite3`。

## 支持的平台

Android、iOS、macOS、Windows、Linux（验证于 Linux desktop）。登录采用「系统浏览器打开授权页 +
本地回环回调」，因此没有 Web 端目标。

## 运行

```bash
flutter pub get
flutter run -d linux      # 或 -d windows / -d macos / 真机
```

构建：

```bash
flutter build linux --release
flutter build apk --release
```

### Linux 安装包（deb / rpm）

```bash
tools/package/package.sh          # deb + rpm，产物在 dist/
tools/package/package.sh deb      # 只要 deb（dpkg-deb，无需 root）
tools/package/package.sh rpm      # 只要 rpm（docker + rockylinux:9 跑 rpmbuild）
```

安装布局：bundle 放在 `/opt/checkin_hub/`（二进制必须与 `data/`、`lib/` 同级），
`/usr/bin/checkin_hub` 是指向它的软链接，另外装 `.desktop` 与 1024px 图标。
后台定时的 systemd unit 用 `Platform.resolvedExecutable` 取真实路径，因此软链接不影响定时任务。
rpm 由 rpmbuild 自动 strip 并生成 soname 依赖（xz payload，兼容 el8+）。

## 数据与目录

账号库默认位于应用支持目录下的 `checkin-hub.sqlite3`，表结构与 Python 版一致
（`accounts` / `checkin_logs` / `settings`）。可用环境变量覆盖：

| 变量 | 作用 |
|---|---|
| `WEB_CHECKIN_HOME` | 覆盖应用数据目录 |
| `CHECKIN_HUB_DB` | 直接指定账号库文件 |
| `TRAE_IDENTITY_PATH` | Trae 设备指纹文件路径 |
| `TRAE_DB_KEY` | Trae 会话库（SQLCipher）的 64 位十六进制密钥，跳过自动抓取 |

Trae 登录态以 AES-128-CBC + SHA-512 容器加密存放，与 Python 端可互相解密；
WorkBuddy 登录态按平台要求以 JSON 存放，请勿拷贝或提交该数据库。

「设置 → 数据与登录态」同时提供账号的导出与导入：

- **导出账号（JSON）**：把账号库里全部 WorkBuddy / Trae 账号（provider、账号 id、endpoint、登录态、
  定时与签到状态）写成 `~/checkin-accounts-<时间>.json`（权限 0600）。
- **导入账号（JSON）**：读同一个文件恢复账号；同 provider + 账号 id 视为同一账号、覆盖登录态，
  不会删除现有账号，导完提示新增 / 更新 / 跳过的数量。

文件里的登录态是明文，只适合自己备份或换机，不要上传或分享。

## 架构

```
lib/
├── main.dart          界面入口；检测到后台标记时切换到无界面签到并退出
└── src/
    ├── background_entry.dart  无界面执行：挑选到点账号、重试、落库
    ├── theme/       设计令牌与 Material 3 主题（深色优先的极光主题）
    ├── models/      Account / CheckinLog / LoginSession
    ├── data/        SQLite 账号库（sqflite + sqflite_common_ffi）
    ├── services/
    │   ├── checkin_runner.dart   签到执行内核（前台调度与后台进程共用）
    │   ├── sessions/             本地会话读取与跨账号复制；Trae 加解密与会话迁移（trae_chat_db / trae_db_key / trae_db_cipher / trae_migrator）
    │   ├── scheduler.dart        应用内兜底调度（OS 调度不可用时）
    │   ├── trae/                 PKCE + 加密容器 + RSA 设备信息
    │   ├── workbuddy/            state 轮询登录与签到
    │   ├── desktop/              写回桌面客户端登录态并重启客户端
    │   └── background/           systemd / launchd / schtasks / AlarmManager
    ├── state/       AppState：串联服务、账号库、系统调度与界面状态
    ├── widgets/     账号卡片、日志时间线、登录/定时对话框等
    └── screens/     概览 / 账号 / 用量 / 会话（仅桌面）/ 设置 / 全部动态 / 定时任务
```

## 每日定时（系统级后台调度）

定时不是应用内的计时器，而是**注册进操作系统的计划任务**，因此应用关闭后依然会执行。
桌面端由系统唤起「应用自身的可执行文件」：进程起来后不显示窗口，跑完签到写入账号库即退出。

| 平台 | 机制 | 补跑/延迟 |
|---|---|---|
| Linux | systemd 用户定时器（`~/.config/systemd/user/checkin-hub-<id>.{service,timer}`） | `Persistent=true`，开机/登录后补跑当天错过的任务 |
| macOS | launchd LaunchAgent（`~/Library/LaunchAgents/dev.checkinhub.checkin.<id>.plist`） | 需要用户已登录 |
| Windows | 任务计划程序（`schtasks`，任务名 `CheckinHub\account-<id>`） | 需要用户已登录；关机期间错过的不补跑 |
| Android | AlarmManager 精确闹钟（`setExactAndAllowWhileIdle`） | 准点，休眠中也会唤醒；重启后自动恢复 |
| iOS | 无系统级定时 | iOS 不允许可靠地按点后台唤醒；保持应用运行或每天打开一次即可补跑 |

在「设置 → 系统级后台定时」里可以看到当前机制、已注册的账号与可执行文件路径，也可以手动
「立即同步 / 从系统移除」。修改某个账号的定时时间、启用状态或删除账号时，会自动重新同步。

后台进程的触发方式（两者都支持）：

```bash
<app> --background-checkin --account 3        # 命令行参数
CHECKIN_HUB_BACKGROUND=3 CHECKIN_HUB_ACCOUNT=3 <app>   # 环境变量
```

重试策略：桌面端一次唤醒内最多尝试 3 次、间隔 5 分钟，耗尽后锁定当日避免反复唤醒；
Android 每次唤醒只尝试一次，失败后另排闹钟重试（最多 2 次），合计同样是 3 次。

> 桌面端的图形引擎需要可用的图形会话，因此定时任务实际在「用户已登录」时执行；
> 机器关机或未登录时，下一次登录后由 `Persistent`（Linux）/ 系统策略补跑。

### Android 权限

`android/app/src/main/AndroidManifest.xml` 中声明了：

| 权限 | 用途 |
|---|---|
| `INTERNET` | 调用 WorkBuddy / Trae 接口（Flutter 模板只在 debug 清单里加过，release 必须显式声明） |
| `ACCESS_NETWORK_STATE` | 判断网络可用性，离线时不发起注定失败的请求 |
| `SCHEDULE_EXACT_ALARM` | 精确定时。Android 14 起**默认拒绝**，需在系统设置里手动开启 |
| `WAKE_LOCK` | 休眠中唤醒设备执行签到 |
| `RECEIVE_BOOT_COMPLETED` | 重启后恢复已排的闹钟 |

同一文件里还声明了 `android_alarm_manager_plus` 需要的 `AlarmService` /
`AlarmBroadcastReceiver` / `RebootBroadcastReceiver`（插件自身不带清单项）。

**没有申请存储权限**：账号库、Trae 设备指纹、任务清单都写在应用私有目录
（`getApplicationSupportDirectory()`），Android 下即 `/data/data/<pkg>/files`，无需任何存储权限。
`MANAGE_EXTERNAL_STORAGE` 属于特殊权限、上架 Google Play 需要单独申请豁免，本项目用不到。

手机端不显示「会话」页（依赖桌面客户端本地数据），首页对应入口也一并隐藏。
账号导入 / 导出在手机端走系统文件选择器（Android SAF）：导出先写到临时目录，再由
`FilePicker.saveFile` 让你选保存位置；导入用 `FilePicker.pickFile` 选 `checkin-accounts-*.json`。
桌面端仍直接写到用户主目录并显示路径。

未授予精确闹钟权限时，代码会自动退化为非精确闹钟（仍能执行，只是可能被系统推迟），
并在「设置 → 系统级后台定时」里显示提示与「去开启精确闹钟」按钮；从系统设置返回后会自动重新同步。

## Qoder

- 登录：设备码 + PKCE，浏览器确认后轮询 `deviceToken/poll` 入库（不依赖本机客户端）
- 状态：`/sash/api/v2/me/usage`（套餐 + 加赠额度）+ `/api/v2/user/plan`
- 签到：领取 `CLAIM_BENEFIT` 类 campaign，`claim` 返回 `CLAIMED` 才算成功；`replayed` 记为重复领取
- 用量：优先走网页端逐笔明细（`qoder.cn/api/v1/me/usages/big_model_credits/histories`，
  含模型 / 会话 / 是否计费）；取不到时回落到客户端 `credits-heatmap` 的按日 Credits
- 网页登录态按账号绑定：客户端的「查看详情」只是在浏览器打开 `qoder.cn/account/usage`，
  网页会话是登录时由 `/users/sign-in` 在浏览器里建立的（客户端自带的 Cookie 库里没有它）。
  所以本应用在**账号登录成功后立刻**从浏览器抓一次 Cookie，用额度接口返回的 `user_id`
  核对归属后绑到该账号（`qoder_web_cookie_<id>`），之后查明细直接用绑定值，
  不需要浏览器一直保持登录；绑定失效（401）自动解绑并回落热力图
- 浏览器 Cookie 解析：Chrome / Chromium / Edge / Brave 全配置扫描（Gnome Keyring 口令 +
  AES-128-CBC 解 v10/v11），自带最小 D-Bus 客户端，不依赖 `secret-tool` 或 python-dbus；
  macOS 用 `security` 取口令；移动端与 Windows 只能在「设置 → Qoder 用量明细」手动贴 Cookie
- access_token 临期自动用 `refresh_token` 续期并回写（refresh_token 会轮换）
- 桌面端换号（Linux）：解密 / 加密 `auth.v1.dat`（Electron safeStorage，libsecret + AES-128-CBC），
  写入前自动备份，成功后重启 Qoder 客户端；macOS/Windows 暂不支持
- 换号前会先结束客户端：TERM 后轮询最多 6 秒（排除僵尸进程、按 /proc/<pid>/exe 精确匹配），
  仍不退出再 KILL；确认退出后才写盘，避免「报错说还在运行、其实已经关掉」
- 会话页：读桌面端 `main.sqlite` 的 chat_sessions / chat_session_messages，
  以及 CLI 的 `~/.qoder-cn/projects/*/*.jsonl`，按当前登录账号归属

## 进入界面时的刷新

- 账号状态刷新有 10 分钟节流（时间戳存在 settings 表），启动时直接用库里的值，
  不再每次进应用都先打一轮接口；「刷新状态」按钮与下拉刷新始终强制走网络
- 「用量」页缓存最近一次结果 5 分钟，重新进入先显示旧数据再后台更新，手动刷新强制重拉
- 「会话」页扫描结果缓存 2 分钟，迁移 / 打包等写操作后强制重扫
- 客户端探测（Qoder 的 python 解密、Trae / WorkBuddy 的安装目录搜索）放在后台并行执行，
  不挡首屏

## 外观与图标

- 设置 →「外观」可切换 **跟随系统 / 浅色 / 深色**，选择写在 settings 表里，重启后保留
- 浅色 / 深色共用同一套设计令牌（`AppPalette`），禁用态按钮、加载提示、导航未选中项
  都使用语义色而不是默认 38% 透明度，避免看不清
- 图标源文件 `assets/icon/app_icon.png`，导出到 Android（普通 + 自适应 + roundIcon）、
  iOS AppIcon、macOS（圆角带留白）、Windows `.ico`、Linux 窗口图标（bundle 的 `data/app_icon.png`）

## 用量

「用量」页把两套用量接口合在一起看：

- **WorkBuddy**：`POST /billing/meter/get-user-request-usage`（逐笔请求，含模型、积分、
  客户端 WorkBuddy/CLI、输入摘要），用账号库里保存的 accessToken 直接查，自动翻页
- **Trae**：`POST /trae/api/v1/pay/query_user_usage_group_by_session`（按会话聚合，
  `usage_type: [7]` 为积分口径；返回首条用户输入当会话标题、模型、积分与 token 数），
  用登录态里的 Cloud-IDE-JWT 调用，临期自动续期
- **Qoder**：`GET qoder.cn/api/v1/me/usages/big_model_credits/histories`（逐笔：模型、
  会话 ID、`Not Charged` 等计费类型、credits），Cookie 归属按额度接口返回的 `user_id`
  与账号匹配；没有浏览器登录态时回落到 `credits-heatmap` 的按日汇总

页面内容：总消耗 / 记录数 / 日均、每日消耗折线图（7/30/90 天）、平台占比条、
模型消耗 Top 5、按天分组的会话明细（标题、模型、客户端、积分、时间）。数据实时拉取，
单个账号失败只在页面底部提示，不影响其它账号。

## 客户端账号切换（仅桌面端）

托管账号的登录态可以直接写回本机 Trae CN / WorkBuddy 客户端，省掉重新扫码：

- **账号页每个平台分组里直接切换**：分组标题显示「客户端当前：xxx」，客户端当前登录的那张卡片
  带绿色边框；**点击同组的其他账号卡片**即切换并重启客户端。账号卡片「⋯ → 切换到客户端」
  是同一个动作的快捷入口
- 「设置 → 客户端探测」显示登录态路径、主程序与客户端当前账号，可手动重新探测
- **自动检测本地账号**：客户端当前登录的账号如果还不在账号库里，启动应用或点
  「重新探测」时会自动导入（Trae 读 `storage.json`，WorkBuddy 读 `workbuddy-desktop.info`
  并用客户端密钥解密令牌），不需要手动添加；客户端只保存「当前登录」的那一个账号，
  所以换号后重启应用即可再次自动收进来

- 平台：Windows / Linux / macOS。Android / iOS 无法控制桌面客户端，**入口整块隐藏**
- 流程固定为：完全退出客户端 → 备份登录态 → 原子写入 → 自动重启客户端（点击即执行，不再二次确认）
- Trae 写入 `storage.json` 的 `iCubeAuthInfo://icube.cloudide`（`tc` 容器，base64 后原样写回），
  并把目标 `userId` 补进 `iCubeAuthInfo://usertag`（缺这一项时客户端会当成未登录）
- WorkBuddy 重写 `workbuddy-desktop.info`，敏感字段用 `$wbEncrypted`（AES-256-GCM）重新加密；
  密钥由客户端自身的 `electron_browser_workbuddy_storage` 绑定在运行时提供
- 切换结果会记入 `checkin_logs`（`action = switch`）

同类能力也提供了命令行版本，便于在没有图形界面或客户端异常时排查：
`tools/desktop-auth/{trae,workbuddy}.mjs`，说明见 `tools/desktop-auth/README.md`。

## 会话（本地 AI 对话）

首页「最近动态 → 查看全部」进入「全部动态」页（全部执行记录），不再跳到会话页；
设置里的「定时任务 → 执行情况」按账号列出每日时间、下次触发、上次执行结果与最近 30 条记录。

「会话」页取代了原来的「动态」页，用来查看和搬运本机客户端里的 AI 对话（仅桌面端，手机端导航不显示）：

- 按账号列出本地会话（标题、所属项目、来源、消息数、最后更新时间），点开可阅读消息内容
- 支持按标题 / 项目 / 模型 / 会话 ID 搜索，并可按 WorkBuddy / Trae 过滤
- 数据来源与对应的原脚本一致：
  - **WorkBuddy 客户端**：`~/.workbuddy/workbuddy.db` 的 `sessions` 表（id / cwd / `user_id` /
    标题 / 状态 / 时间），正文在同目录 `projects/<项目>/<会话>.jsonl`。
    这是 WorkBuddy 自己的库，和下面两个 CodeBuddy 的产品不是一套东西
  - **CodeBuddy IDE**：`CodeBuddyExtension/Data/<uid>/CodeBuddyIDE/<uid>/history/<workspace>/<session>/`
    （`index.json` 是索引，`messages/*.json` 是正文；工作区名从 `Logs/CodeBuddyIDE` 反查；
    工作区目录名 = md5(工作区路径)，Windows / macOS 先转小写）
  - **CodeBuddy IDE 元数据**：`~/.config/CodeBuddy CN/codebuddy-sessions.vscdb` 的 `session:<id>`，
    补充标题、状态、cwd 与最近活动时间
  - **CodeBuddy CLI**：`~/.codebuddy/projects/<项目>/<会话>.jsonl`，标题取首条用户输入，
    正文按事件逐条解析
  - **Trae**：`User/globalStorage/state.vscdb` 与各工作区 `state.vscdb` 的会话键、
    `ModularData/ai-agent/snapshot/<id>`、`sandbox/<id>.json`，以及 `logs/**/renderer.log`
    里的 `session_updated` 事件（标题）
- 只显示**有实际内容**的会话：桌面端无消息且无标题的占位会话、0 字节的 CLI 会话会被过滤
- 每个分组分页展示（窄屏 6 条/页、宽屏 8 条/页），账号多时不会一次铺满页面；手机端标题与
  操作按钮改为上下排布，会话详情对话框自适应屏幕尺寸
- 勾选会话 →「迁移 N 条到账号…」→ 选择另一个账号，按来源分三种做法：
  - **WorkBuddy 客户端**：直接改 `workbuddy.db` 里 `sessions.user_id`，正文不动，原账号不再显示
    （可以一次迁移不同账号的会话）
  - **CodeBuddy IDE**：整目录复制到目标账号的数据目录，生成新的会话 id 并登记到目标的 `index.json`
    （原账号保留；一次只能来自同一个账号）
  - **CodeBuddy CLI**：解析 `~/.codebuddy/projects` 里的 `jsonl`，按 IDE 的 `index.json` +
    `messages/*.json` 结构写进目标账号，并落到「工作区路径 md5」对应的目录（Windows / macOS 先转小写）
  - IDE / CLI 两条路径都会补写 `codebuddy-sessions.vscdb` 的 `session:<新id>`（标题、cwd、
    `userId` = 目标账号），客户端按它归属账号
- **导出 / 导入**：勾选会话后右侧出现导出按钮
  - Trae → 导出 `trae-sessions-<时间>.db`（加密库裁剪出的明文包，跨机器用）
  - WorkBuddy / CodeBuddy IDE / CLI → 导出 `workbuddy-sessions-<时间>.json`
    （明文 JSON，含元数据与消息正文）；在另一台机器「导入迁移包」选这个文件，
    会写成 WorkBuddy 客户端的 `sessions` 行 + `projects/<项目>/<会话>.jsonl`，
    可选择沿用包里的账号或指定本机账号
- 迁移期间界面会弹出不可关闭的进度框；Trae 的解密/复制/重加密在后台 isolate 跑，
  不会把界面卡成「未响应」
- **客户端只显示「当前打开的工作区」的会话**：迁移后要重启 WorkBuddy 并打开对应项目文件夹，
  会话才会出现在列表里；不放回正确的工作区目录（例如随手生成一个随机 id）客户端永远看不到
- 迁移会复制 `history`、`file-tree`、`plan-task`，跳过 `check-point`（体积大且绑定本机 git 快照）；
  建议先退出 WorkBuddy 客户端再迁移，避免索引被运行中的客户端覆盖
- **Trae 正文**：正文在 SQLCipher v4 加密的 `ModularData/ai-agent/database.db` 里（页大小 4096、
  AES-256-CBC、每页 IV 在偏移 4016），应用按页解密出一份临时明文库再只读查询，全程不改动原库。
  密钥是 32 字节原始密钥，客户端运行时才存在内存里：优先用 `~/.trae-sessions-key.json` 缓存
  （与 `trae-checkin` 脚本共用），没有就扫运行中的 Trae 进程内存，再不行就拉起一个带独立
  `--user-data-dir` 的隔离实例抓一次并缓存；也可以用 `TRAE_DB_KEY` 手动指定。
  抓不到密钥或客户端未运行时，详情页回落到「最后一条回复」摘要，不影响列表。
- **Trae 会话归属**：以会话库的 `chat_session.project_id` → `project.user_id` 为准。
  状态库的 `draft:session` 键只覆盖最近打开过的少量会话、日志更稀疏，所以列表会先解密读取
  会话库索引（只取 id / 项目 / 账号 / 标题 / 条数 / 时间，不读正文），没有缓存密钥且客户端未运行时
  才退回状态库与日志；库里已删除的残留会话不再展示，不会再出现「未关联账号」
- **Trae 跨账号复制（同机换号）**：`chat_session` 表里没有账号列，归属记在
  `project.user_id` 上，所以复制时给目标账号建/复用同路径项目，再把选中的会话整条复制一份：
  1. 从选中会话出发，按 `session_id` / `message_id` / `turn_id` / `task_id` / `agent_run_id` 等
     关联列做闭包，收集整条会话图（消息、回合、任务、历史、服务端历史、快照 / staging /
     worktree、工件、待办）；
  2. 每行实体 id 换成新 id，`user_id` 换成目标账号，项目引用指向目标账号的项目行；
  3. `chat_session.context` / 快照 `state` 里内嵌的会话与项目 id 同步替换；
  4. 给副本补一条 `<目标账号>:draft:session:<新会话>:code`，客户端据此归属账号。
  **原账号的会话不变**，目标账号多出一份。复制前必须**完全退出 Trae**；写回前做完整性校验，
  原库自动备份成 `database.db.bak-<时间>`。账号级配置 / 缓存（`user_configuration`、
  `model_config_cache`、`agent`、`core_memory`）不复制
- **副本在 Trae 里看不到？** Trae 的会话列表只列「当前打开的工作区」里的会话（按
  `chat_session.project_id` 对应的工作区文件夹过滤）。副本挂在目标账号的同路径项目下，
  所以复制后要：重启 Trae → 切到目标账号 → 打开副本所属的项目文件夹；
  开着别的工作区时，其它项目的副本不会出现在列表里（数据已经在库里）

### Trae 会话跨机器迁移（桌面端）

和 WorkBuddy 一样在「会话」页勾选后迁移，只是目标换成了另一台机器（流程与 `db-migrate.mjs` 一致）：

1. **源机导出**：勾选要带走的 Trae 会话 →「导出 N 条迁移包」。应用解密本机库、只保留选中会话再收缩，
   生成 `trae-sessions-<时间>.db`。包内是**明文**正文，只用于传输，传完请删除。
2. **目标机导入**：把那台机器的 Trae 完全退出 →「导入迁移包」→ 填路径（可勾「只试算」）。
   应用解密目标库 → 按会话整体导入新会话（已存在的会话保留本机版本，重复导入不会重复写入）→ 完整性校验 →
   用目标机 key 重新加密（含逐页 HMAC）并自校验 → 备份原库后原子替换。

导入前会自动生成 `database.db.bak-<时间>`（同名 `-wal` / `-shm` 一并改名），任何一步失败都不会改动原库。
迁移包也可以是源机的加密 `database.db`，这时需要源机密钥（`node db-migrate.mjs key` 或 `TRAE_DB_KEY`）。
整库导出/导入需要几十秒。

## 测试

```bash
flutter analyze
flutter test

# 真实文件库测试
CHECKIN_HUB_DB=/tmp/checkin-test.sqlite3 flutter test

# 真实 systemd 集成验证（会写入 ~/.config/systemd/user，测试结束自动清理）
CHECKIN_VERIFY_SYSTEMD=1 WEB_CHECKIN_HOME=/tmp/bg-verify flutter test test/systemd_integration_test.dart
```

- `trae_crypto_test.dart`：加密容器与 Python 端双向互操作、PKCE、RSA SPKI/PEM 输出。
- `desktop_switch_test.dart`：WorkBuddy 信封与 Node 实现互通（AAD/keyId）、手机号掩码。
- `dashboard_widget_test.dart`：渲染真实概览页（宽/窄窗口、空态、页面切换），可捕获布局溢出。
- `session_service_test.dart`：桌面端目录与 vscdb 元数据合并、CLI jsonl 解析、Trae 状态库/快照/日志聚合、
  消息解码与跨账号复制。
- `sessions_widget_test.dart`：多来源分组、搜索过滤、窄屏布局与 Trae 预览展示。
- `background_entry_test.dart`：无界面执行的挑选/重试/锁定当日/退出码。
- `background_schedule_test.dart`：各平台生成的单元文件与命令、待执行账号筛选、任务清单。
- `systemd_integration_test.dart`：真实安装/查询/移除 systemd 用户定时器（需显式开启）。
- `scheduler_test.dart`：每日定时时间解析（含 Android 闹钟 id 与下一次触发时间）。
- `database_test.dart`：账号库与真实文件库行为。
