# 桌面端账号切换工具（Windows / Linux / macOS）

把 [签到中枢](../../README.md) 账号库里保存的登录态，直接写回 **Trae CN / WorkBuddy 桌面客户端**，
再自动重启客户端，从而免去重新扫码登录。Flutter 客户端里的「切换到客户端」按钮内置了同一套逻辑；
本目录下的 Node 脚本用于在没有客户端界面时手动排查、批处理或核对数据。

```text
tools/desktop-auth/
├── trae.mjs                # Trae CN 换号 / 还原 / 查看
├── workbuddy.mjs           # WorkBuddy 换号 / 还原 / 查看
├── scan-asar.mjs           # app.asar 只读探针（逆向辅助）
├── lib/
│   ├── accounts.mjs        # 读取 checkin-hub.sqlite3、参数解析
│   ├── clients.mjs         # 跨平台路径探测、进程退出 / 重启、原子写入
│   ├── crypto-trae.mjs     # Trae tc 容器 加解密
│   └── crypto-wb.mjs       # WorkBuddy $wbEncrypted 信封 + 本机密钥探针
└── reference/              # 最初的逆向脚本与换号原型（保留对照）
```

脚本要求 Node.js 22.5+（用到 `node:sqlite`）。

## 一、登录态位置（按平台）

| 客户端 | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Trae CN | `%APPDATA%\Trae CN\User\globalStorage\storage.json` | `~/.config/Trae CN/User/globalStorage/storage.json` | `~/Library/Application Support/Trae CN/User/globalStorage/storage.json` |
| WorkBuddy | `%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info` | `~/.local/share/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` | `~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info` |

同一客户端的多个变体（`Trae`、`TRAE SOLO CN` 等）会一并探测；探测顺序写在 `lib/clients.mjs`。
主程序路径同样按平台候选列表探测，Linux 上还支持在 `/var/lib/apm`、`/opt`、`/usr/lib` 等目录有限深度搜索。

## 二、加密格式

### Trae：`tc` 容器

逆向自 `resources/app/out/main.js`（`out-build/vs/base/common/byteCrypto.js`）。

```text
base64( 74 69 05 10 00 00 | RANDOM(32) | AES-128-CBC( SHA512(payload)(64) ‖ payload ) )
```

- 密钥：`SHA512( SHA512(RANDOM) ‖ XOR掩码(64B) )`，前 16B 为 key、后 16B 为 IV
- 掩码硬编码在 bundle 中，**与机器码无关**，因此可以跨机迁移
- 完整性：明文前置 `SHA512(明文)`，解密后逐字节比对
- 客户端写入的 `iCubeAuthInfo://icube.cloudide` 就是这个 base64 字符串
- 换号时还必须把目标 `userId` 补进 `iCubeAuthInfo://usertag`（`userId → 地区` 映射）：
  客户端按这张表判断登录态属于哪个区，缺失时即使 token 有效也会被当成未登录——
  这正是「切到某个账号失败、切回原来的账号又正常」的典型原因
- `account.scope` 不能为空：客户端 `UserInfoManager` 的第一道判断就是
  `if (!userInfo.account.scope) return`，为空直接按未登录处理。应用侧登录走
  `GetUserInfo`，部分账号不返回 `Scope` / `LoginScope` / `StoreRegion` / `UserTag`，
  写回前会按客户端自身写入的默认值补齐（`marscode` / `trae` / 地区 / `cn`）

### WorkBuddy：`$wbEncrypted` 信封

逆向自 `app.asar!/main/app-lifetime-job.js`（`AtRestCrypto`）。

```text
{ "$wbEncrypted": 1, "envelope": base64(JSON{ suite:1, keyId, nonce(12B), authTag(16B), ciphertext }) }
key   = SHA-256(atRestSecretKey)        // AES-256-GCM
keyId = hex(SHA-256(key))[0:16]
AAD   = "WB-AAD\0" ‖ 0x01 ‖ len("WBEV1") ‖ len("sym-v1") ‖ uint32(1) ‖ len(keyId) ‖ 0x02 ‖ 0x00 ‖ 0x00
```

只有 `account.nickname` / `account.phoneNumber` / `auth.accessToken` / `auth.refreshToken`
是信封值，其余字段明文。密钥不落盘，只能让客户端自己吐出来：

```bash
ELECTRON_RUN_AS_NODE=1 WorkBuddy.exe -e '<probe>'
# probe: process._linkedBinding("electron_browser_workbuddy_storage").loggerGet()
```

`lib/crypto-wb.mjs` 的 `readProtectorKey()` 已封装该探针（无窗口、不联网、不改状态）。

> Windows CMD 下不要用 `ELECTRON_RUN_AS_NODE=1 xxx` 语法，脚本内部通过 `env` 注入，直接跑 `node workbuddy.mjs list` 即可。

## 三、用法

```bash
# 查看客户端当前账号 + 账号库候选（只读）
node trae.mjs list
node workbuddy.mjs list

# 切换（写入前会先完全退出客户端，完成后自动重启）
node trae.mjs switch --to 2
node workbuddy.mjs switch --to f9d35b32

# 只写登录态，手动重启
node trae.mjs switch --to 2 --no-restart

# 还原最近一次备份
node trae.mjs restore
node workbuddy.mjs restore

# 打印当前登录态（令牌打码）
node trae.mjs dump
node workbuddy.mjs dump
```

公共参数：`--hub <checkin-hub.sqlite3>`、`--file <登录态文件>`、`--bin <客户端主程序>`、`--no-restart`。

写入流程固定为 **退出客户端 → 备份 → 原子写入 → 重启**：客户端运行时会回写登录态，
不先退出的话改动会被覆盖。每次写入前的备份名为 `<文件名>.bak-<UTC 时间戳>`。

## 四、与 Flutter 客户端的关系

客户端内的「切换到客户端」复用同一套规则，实现在 `lib/src/services/desktop/`：

- 只在 **Windows / Linux / macOS** 显示入口；Android / iOS 上完全不出现相关按钮
- 支持平台：`Trae`、`WorkBuddy`
- 点击后自动完成「退出 → 写入 → 重启」，并记录一条 `switch` 操作日志

## 五、已知限制

1. WorkBuddy 的 AAD 字节序来自原始换号脚本，未在 bundle 中逐字节复核；若客户端升级后拒绝接受登录态，
   优先怀疑此处。
2. 切换只改登录态文件，不改客户端缓存的余额 / 会话数据，客户端启动后会自动拉取。
3. 账号库里的 Trae 登录态是 `tc` 密文，WorkBuddy 是明文 JSON（含令牌），
   `checkin-hub.sqlite3` 请按敏感文件保管。
4. 本项目与 WorkBuddy、Trae 官方没有隶属关系，请仅切换你本人拥有授权的账号。
