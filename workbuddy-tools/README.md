# WorkBuddy 签到工具

这套脚本只保存你本人授权导出的会话，并在 Windows 本机调用打包自带的官方 `turing_sdk.node` / `TuringShieldSDK.dll` 生成当前 `X-Device-Token`。脚本不会离线伪造、重放或绕过设备风控 token。

另有 `wbipc-checkin.mjs`：单文件、零第三方依赖、纯 Node 标准库，跨 Windows/macOS/Linux。它通过 WorkBuddy 官方 WBIPC 宿主通道请求接口，认证头由客户端注入，不读取、不解密、不落盘登录 token。

## 跨端 WBIPC 方案

前提：WorkBuddy 已启动并登录。

```bash
node workbuddy-tools/wbipc-checkin.mjs --diagnose
node workbuddy-tools/wbipc-checkin.mjs --check-only
node workbuddy-tools/wbipc-checkin.mjs
```

脚本读取：

```text
Linux/macOS: {WORKBUDDY_CONFIG_DIR|~/.workbuddy}/wbipc/endpoint.json
Windows:     {WORKBUDDY_CONFIG_DIR|%USERPROFILE%\.workbuddy}\wbipc\endpoint.json
```

也可临时指定：

```bash
WBIPC_ENDPOINT="unix:/path/to/wbipc.sock" WBIPC_TICKET="..." node workbuddy-tools/wbipc-checkin.mjs --check-only
```

`WBIPC_ENDPOINT` 支持 `unix:`、Windows named pipe 和 `tcp://host:port`。协议使用 HMAC-SHA256 双向握手，业务请求走 `wb.request/http.fetch`。

## 数据库

默认数据库是当前目录下的 `workbuddy-checkin.sqlite`，可用 `--db` 或 `WORKBUDDY_CHECKIN_DB` 覆盖。数据库权限会尝试设置为 `0600`，但仍应放在受保护目录中。

## 1. 导入登录态

官方登录态文件使用 Electron credential protection 加密，脚本不直接解密它。请先从官方程序导出或通过你自己授权的诊断流程得到如下明文 JSON：

```json
{
  "auth": {
    "accessToken": "..."
  },
  "account": {
    "uid": "..."
  }
}
```

导入：

```powershell
node workbuddy-tools/login.mjs import-session --db workbuddy-checkin.sqlite --auth-json workbuddy-session.json
```

验证：

```powershell
node workbuddy-tools/login.mjs verify --db workbuddy-checkin.sqlite
```

也可以使用官方外部链接登录流程自动创建并轮询 state：

```powershell
node workbuddy-tools/login.mjs browser-login `
  --db workbuddy-checkin.sqlite `
  --sdk "C:\Users\<you>\AppData\Local\Programs\WorkBuddy\resources\app.asar.unpacked\native\turing-sdk"
```

脚本会调用官方 SDK 获取当前设备 token，请求：

1. `POST /v2/plugin/auth/state?platform=workbuddy`
2. 打开返回的 `authUrl`
3. `GET /v2/plugin/auth/token?state=...`
4. `GET /v2/plugin/login/account?state=...`

登录成功后把 accessToken/refreshToken/account 写入 SQLite。若以后需要刷新登录态：

```powershell
node workbuddy-tools/login.mjs refresh --db workbuddy-checkin.sqlite
```

## 2. 签到

把 `--sdk` 指向官方安装目录中的：

```text
resources\app.asar.unpacked\native\turing-sdk
```

示例：

```powershell
node workbuddy-tools/checkin.mjs `
  --db workbuddy-checkin.sqlite `
  --sdk "C:\Users\<you>\AppData\Local\Programs\WorkBuddy\resources\app.asar.unpacked\native\turing-sdk"
```

脚本会调用官方 SDK 取当前 token，先请求 `POST /v2/billing/meter/checkin-activity-status`；如果当天未签且活动开启，再请求 `POST /v2/billing/meter/daily-checkin`。每次请求和结果都会写入 SQLite 日志。
