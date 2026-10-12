import { createRequire } from "node:module";
import path from "node:path";

export const DEFAULT_CHANNEL_ID = 109144;
export const DEFAULT_PRODUCT_NAME = "WorkBuddy";
export const DEFAULT_PRODUCT_VERSION = "5.7.7";

export function resolveSdkDir(cliValue) {
  const value = cliValue
    || process.env.WORKBUDDY_TURING_SDK_DIR
    || path.join(process.env.LOCALAPPDATA || "", "Programs", "WorkBuddy", "resources", "app.asar.unpacked", "native", "turing-sdk");
  if (!value || !value.trim()) {
    throw new Error("未找到官方 turing-sdk 目录，请用 --sdk 或 WORKBUDDY_TURING_SDK_DIR 指定");
  }
  return path.resolve(value.trim());
}

export async function fetchDeviceTokenWithOfficialSdk(sdkDir, { timeoutMs = 15000 } = {}) {
  const require = createRequire(import.meta.url);
  const binding = require(sdkDir);
  if (!binding?.isSupported?.()) {
    throw new Error(binding?.getLoadError?.() || "官方 Turing SDK binding 不可用");
  }
  binding.configure(DEFAULT_CHANNEL_ID, DEFAULT_PRODUCT_NAME, DEFAULT_PRODUCT_VERSION);
  return await binding.fetchDeviceToken({
    usingCachedMessage: true,
    includesOutdatedMessage: false,
    includesDeviceInfo: true,
    timeoutMs,
  });
}
