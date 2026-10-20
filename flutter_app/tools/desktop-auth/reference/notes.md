# 逆向笔记（原始记录）

> 路径相关的多端适配已整理到 [`../README.md`](../README.md)；本文保留最初的客户端逆向细节，
> 其中的 Windows 绝对路径仅代表记录时的环境，脚本已改为按平台自动探测。

---


对本机已安装的两个客户端做反编译得到的结果汇总。凡在真实数据上跑通的部分，均已在此标注。

---

## 一、Trae CN（已完成实测验证）

### 1. 登录态位置

```
%APPDATA%\Trae CN\User\globalStorage\storage.json
```

| 键 | 含义 |
| --- | --- |
| `iCubeAuthInfo://icube.cloudide` | **主登录态**：token / refreshToken / userId / account / host |
| `iCubeAuthInfo://usertag` | `userId -> 地区` 映射 |
| `iCubeAuthInfo://icube-dc:<id>` | 设备 RSA 密钥对（privateKeyPEM / publicKeyPEM，用于请求签名） |

键名前缀来自 `out-build/vs/base/common/iCube/userInfo.js`（`L5="iCubeAuthInfo"`）；
写入方是 `out-build/vs/platform/iCubeAuth/electron-main/components/userStorage.js`，
通过 `stateService.setItem(持久化键, base64密文)` 落盘。客户端退出时会回写该文件。

### 2. 加密实现

模块 `out-build/vs/base/common/byteCrypto.js`（打包在 `out/main.js` 内）。顶层 API：

- `R1(plaintext) -> base64`　加密
- `u2(base64) -> plaintext`　解密

密文结构：

```
[6B 魔数 74 69 05 10 00 00] [32B 伪装密钥] [AES-128-CBC(64B SHA-512 校验 ‖ 明文)]
   "t" "c"  v5  tag16  ver0  pad0
```

- **KDF**：`SHA-512( SHA-512(salt) ‖ XOR掩码(64B) )`，前 16B = AES key，后 16B = IV
- **掩码**：两组 64 字节常量（`AES` 用 `Sle^ble`，`AES_PRIVATE` 用 `_le^yle`），硬编码在 bundle 里
- **密钥自包含**：第 6~38 字节就是真实密钥，**不绑定机器码 / 硬件指纹**
- **完整性**：明文前置 64 字节 `SHA-512(明文)`，解密后逐字节比对
- **版本判定**：`t[0]=116,t[1]=99` 即 `"tc"`；`t[2]=5,t[3]=16` 为 AES
- `crypto.subtle`（WebCrypto）实现，非 node:crypto

### 3. 登录态 API（逆向自 `out/main.js`）

**续期** `POST {host}/trae/api/v3/oauth/ExchangeToken`

```js
body = {
  ClientID, ClientSecret: "",
  RefreshToken,
  DeviceInfo,      // { DeviceID, MachineID, PlatformCode:"IDE_PC", DeviceType:"PC",
                   //   DeviceName, DevicePublicKey(RSA公钥PEM), ClientVersion, ... }
  DeviceProof,     // { Signature, Timestamp, Nonce }  ← 用 icube-dc 私钥 PEM 签名
  IDEVersion,
}
```

**校验** `POST {host}/cloudide/api/v3/trae/CheckLogin`，body `{ IDEVersion, ReqSource:"IDE", GetAIPayHost:true }`，读 `Result.IsLogin`。

**用户信息** `POST {host}/cloudide/api/v3/trae/GetUserInfo`。

**统一请求头**（拦截器注入）：`Authorization: Cloud-IDE-JWT <token>`、`X-User-Region: <region>`。

脚本见 `trae-tc.js`。

---

## 二、WorkBuddy（格式已逆向；解密未在本机实测）

### 1. 登录态位置

```
%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\workbuddy-desktop.info
```

明文 JSON，**仅敏感字段**被 `$wbEncrypted` 信封包裹。顶层键：`auth` / `account` / `accounts` / `allAccounts`

- `account`：`uid`、`uin`、`type`、`lastLogin` 等为明文；`nickname`、`phoneNumber` 为信封
- `auth`：`accessToken`、`refreshToken` 为信封；`tokenType/scope/domain/expiresAt/lastRefreshTime/refreshExpiresAt` 为明文
- `accounts` / `allAccounts`：账号列表（slim）

### 2. 加密实现

模块 `app.asar!/main/app-lifetime-job.js`（`AtRestCrypto` / `AtRestCryptoError` / `KeyMismatchError` 等类）。

客户端常量（已与 bundle 逐项比对一致）：

| 项 | 值 |
| --- | --- |
| AAD 域 | `"WB-AAD\0"` |
| 包装域 | `"WB-WRAP\0"` |
| framing 码 | `{file:1, field:2, record:3, stream:4}` |
| 格式 ID | `{file:"WBEF1", field:"WBEV1", record:"WBER1", stream:"WBES1"}` |
| 整文件帧 | `{WBEF1, WBEA1}` |
| suite 集合 | `{1}` |
| scheme | `"sym-v1"` |
| nonce | `randomBytes(12)` |
| 信封键集合 | `authTag, ciphertext, keyId, nonce, suite`（解析时按键名排序严格校验） |

- 算法 **AES-256-GCM**，12B nonce，16B tag
- `key = SHA-256(atRestSecretKey)`
- `keyId = SHA-256(key)` 的 hex 前 16 位
- AAD 序列化（**取自 switch.mjs，未在 bundle 中逐字节复核**）：

```
WB-AAD\0 ‖ 0x01 ‖ len("WBEV1") ‖ len("sym-v1") ‖ uint32(1) ‖ len(keyId) ‖ 0x02 ‖ 0x00 ‖ 0x00
```

### 3. 密钥来源

客户端内部绑定 `electron_browser_workbuddy_storage` 的 `loggerGet()` 返回 JSON，含 `version` 与 `atRestSecretKey`。
取回方式：以 `ELECTRON_RUN_AS_NODE=1` 启动 `WorkBuddy.exe` 执行 `-e` 探针脚本（无窗口、不改动客户端状态）。

脚本见 `workbuddy-envelope.js`。

---

## 三、原始脚本

`originals/` 保留了最初提供的两个换号脚本：

- `originals/switch.mjs`　WorkBuddy 换号（自包含，已实现上面的信封逻辑）
- `originals/trae-switch.js`　Trae 换号（依赖 `auth.js` / `db.js` / `lib.js`，这些文件未提供）

---

## 待验证事项

1. WorkBuddy 信封的**实际解密**未在本机跑过（未执行客户端探针取 `atRestSecretKey`）。
2. WorkBuddy AAD 的**字节序**仅来自 `switch.mjs`，需在 bundle 里确认。
3. Trae 侧 `trae-switch.js` 依赖的 `auth.js`（`AUTH_KEY` / `encrypt` / `decrypt` / `scan`）未提供，
   其 `scan()` 是否覆盖 Windows 路径未知。
