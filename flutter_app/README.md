# 签到中枢 · Flutter 跨端客户端

WorkBuddy / Trae 多账号签到与额度查询的独立 Flutter 应用。界面与交互完全按 Flutter 重做，
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

## 数据与目录

账号库默认位于应用支持目录下的 `checkin-hub.sqlite3`，表结构与 Python 版一致
（`accounts` / `checkin_logs` / `settings`）。可用环境变量覆盖：

| 变量 | 作用 |
|---|---|
| `WEB_CHECKIN_HOME` | 覆盖应用数据目录 |
| `CHECKIN_HUB_DB` | 直接指定账号库文件 |
| `TRAE_IDENTITY_PATH` | Trae 设备指纹文件路径 |

Trae 登录态以 AES-128-CBC + SHA-512 容器加密存放，与 Python 端可互相解密；
WorkBuddy 登录态按平台要求以 JSON 存放，请勿拷贝或提交该数据库。

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
    │   ├── scheduler.dart        应用内兜底调度（OS 调度不可用时）
    │   ├── trae/                 PKCE + 加密容器 + RSA 设备信息
    │   ├── workbuddy/            state 轮询登录与签到
    │   └── background/           systemd / launchd / schtasks / AlarmManager
    ├── state/       AppState：串联服务、账号库、系统调度与界面状态
    ├── widgets/     账号卡片、动态时间线、登录/定时对话框等
    └── screens/     概览 / 账号 / 动态 / 设置
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

未授予精确闹钟权限时，代码会自动退化为非精确闹钟（仍能执行，只是可能被系统推迟），
并在「设置 → 系统级后台定时」里显示提示与「去开启精确闹钟」按钮；从系统设置返回后会自动重新同步。

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
- `dashboard_widget_test.dart`：渲染真实概览页（宽/窄窗口、空态、动态筛选），可捕获布局溢出。
- `background_entry_test.dart`：无界面执行的挑选/重试/锁定当日/退出码。
- `background_schedule_test.dart`：各平台生成的单元文件与命令、待执行账号筛选、任务清单。
- `systemd_integration_test.dart`：真实安装/查询/移除 systemd 用户定时器（需显式开启）。
- `scheduler_test.dart`：每日定时时间解析（含 Android 闹钟 id 与下一次触发时间）。
- `database_test.dart`：账号库与真实文件库行为。
