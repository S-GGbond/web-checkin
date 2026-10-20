/**
 * 桌面客户端定位与进程管理（Windows / Linux / macOS）
 *
 * 只做三件事：
 *   1. 找到客户端主程序与登录态文件；
 *   2. 判断客户端是否在运行、安全退出；
 *   3. 重新拉起客户端。
 *
 * 所有路径都按平台候选列表逐个探测，任何一项缺失都返回 null，
 * 由调用方给出可操作的提示，而不是写死某个用户的目录。
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawn, spawnSync } from "node:child_process";

export const isWin = process.platform === "win32";
export const isMac = process.platform === "darwin";
export const isLinux = process.platform === "linux";

const HOME = os.homedir();
const env = (key) => {
  const value = process.env[key];
  return value && value.trim() ? value.trim() : "";
};

/** 候选列表中第一个存在的文件（跳过空值）。 */
export function firstFile(candidates) {
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // 不存在或无权访问，继续下一个
    }
  }
  return null;
}

/** 候选列表中第一个存在的目录。 */
export function firstDir(candidates) {
  for (const candidate of candidates) {
    if (!candidate) continue;
    try {
      if (fs.statSync(candidate).isDirectory()) return candidate;
    } catch {
      // 同上
    }
  }
  return null;
}

function which(names) {
  for (const name of names) {
    const result = spawnSync(isWin ? "where" : "which", [name], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const hit = String(result.stdout || "").split(/\r?\n/).map((s) => s.trim()).find(Boolean);
    if (hit) return hit;
  }
  return null;
}

/** 在有限深度内按文件名搜索（Linux 上 apm/deb 安装层级较深时兜底）。 */
function findInRoots(roots, fileName, maxDepth = 10) {
  for (const root of roots) {
    if (!root || !fs.existsSync(root)) continue;
    const result = spawnSync(
      "find",
      [root, "-maxdepth", String(maxDepth), "-type", "f", "-name", fileName, "-perm", "-u+x"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 20000, maxBuffer: 4 * 1024 * 1024 },
    );
    const hit = String(result.stdout || "").split("\n").map((s) => s.trim()).find(Boolean);
    if (hit) return hit;
  }
  return null;
}

/* ------------------------------------------------------------------ *
 * Trae CN
 * ------------------------------------------------------------------ */

export const TRAE_AUTH_KEY = "iCubeAuthInfo://icube.cloudide";
const TRAE_STATES = ["Trae CN", "TRAE SOLO CN", "Trae", "TRAE SOLO"];

export function traeStorageFiles() {
  const files = [];
  for (const name of TRAE_STATES) {
    if (isWin) {
      files.push(path.join(env("APPDATA"), name, "User", "globalStorage", "storage.json"));
      files.push(path.join(env("LOCALAPPDATA"), name, "User", "globalStorage", "storage.json"));
    } else if (isMac) {
      files.push(path.join(HOME, "Library", "Application Support", name, "User", "globalStorage", "storage.json"));
    } else {
      files.push(path.join(HOME, ".config", name, "User", "globalStorage", "storage.json"));
    }
  }
  return files.filter((file) => fs.existsSync(file));
}

export function findTraeExe() {
  const candidates = [];
  if (isWin) {
    for (const name of ["Trae CN", "Trae"]) {
      candidates.push(path.join(env("LOCALAPPDATA"), "Programs", name, `${name}.exe`));
      candidates.push(path.join(env("PROGRAMFILES"), name, `${name}.exe`));
      candidates.push(path.join(env("PROGRAMFILES(X86)"), name, `${name}.exe`));
    }
  } else if (isMac) {
    candidates.push("/Applications/Trae CN.app/Contents/MacOS/Electron");
    candidates.push(path.join(HOME, "Applications", "Trae CN.app", "Contents", "MacOS", "Electron"));
  } else {
    candidates.push(
      "/usr/share/trae-cn/trae-cn",
      "/usr/share/trae/trae",
      "/opt/trae-cn/trae-cn",
      "/opt/trae/trae",
      "/usr/lib/trae-cn/trae-cn",
      path.join(HOME, ".local/share/trae-cn/trae-cn"),
    );
  }
  return firstFile(candidates) || which(isWin ? ["Trae CN.exe", "Trae.exe"] : ["trae-cn", "trae"]);
}

export function traeProcessMatchers() {
  if (isWin) return ["Trae CN.exe", "Trae.exe"];
  if (isMac) return ["Trae CN.app/Contents/MacOS", "Trae.app/Contents/MacOS"];
  return ["/trae-cn", "/trae ", "trae-cn/trae-cn", "/opt/trae/trae"];
}

/* ------------------------------------------------------------------ *
 * WorkBuddy
 * ------------------------------------------------------------------ */

export function workbuddyAuthFiles() {
  const rel = path.join("CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info");
  const files = [];
  if (isWin) {
    files.push(path.join(env("LOCALAPPDATA"), rel));
    files.push(path.join(env("APPDATA"), rel));
  } else if (isMac) {
    files.push(path.join(HOME, "Library", "Application Support", rel));
  } else {
    files.push(path.join(HOME, ".local", "share", rel));
    files.push(path.join(HOME, ".config", rel));
  }
  return files.filter((file) => fs.existsSync(file));
}

export function findWorkbuddyExe() {
  const candidates = [];
  if (isWin) {
    candidates.push(path.join(env("LOCALAPPDATA"), "Programs", "WorkBuddy", "WorkBuddy.exe"));
    candidates.push(path.join(env("PROGRAMFILES"), "WorkBuddy", "WorkBuddy.exe"));
    candidates.push(path.join(env("PROGRAMFILES(X86)"), "WorkBuddy", "WorkBuddy.exe"));
  } else if (isMac) {
    candidates.push("/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy");
    candidates.push("/Applications/WorkBuddy.app/Contents/MacOS/Electron");
    candidates.push(path.join(HOME, "Applications", "WorkBuddy.app", "Contents", "MacOS", "WorkBuddy"));
  } else {
    candidates.push(
      "/opt/workbuddy/workbuddy",
      "/opt/WorkBuddy/workbuddy",
      "/usr/lib/workbuddy/workbuddy",
      "/usr/share/workbuddy/workbuddy",
      "/usr/local/workbuddy/workbuddy",
      path.join(HOME, ".local", "opt", "workbuddy", "workbuddy"),
    );
  }
  const hit = firstFile(candidates) || which(["workbuddy"]);
  if (hit) return hit;
  if (isLinux) {
    return findInRoots(
      ["/var/lib/apm", "/opt", "/usr/lib", "/usr/share", path.join(HOME, ".local")],
      "workbuddy",
      12,
    );
  }
  return null;
}

export function workbuddyProcessMatchers() {
  if (isWin) return ["WorkBuddy.exe"];
  if (isMac) return ["WorkBuddy.app/Contents/MacOS"];
  return ["/workbuddy", "workbuddy/workbuddy"];
}

/* ------------------------------------------------------------------ *
 * 进程
 * ------------------------------------------------------------------ */

/** 返回匹配到的进程 PID 列表（排除当前脚本自身）。 */
export function runningPids(matchers) {
  const pids = new Set();
  if (isWin) {
    for (const image of matchers) {
      try {
        const out = execFileSync("tasklist", ["/FI", `IMAGENAME eq ${image}`, "/NH"], {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        });
        for (const line of out.split(/\r?\n/)) {
          const match = new RegExp(`^${image.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s+(\\d+)`, "i").exec(
            line.trim(),
          );
          if (match) pids.add(Number(match[1]));
        }
      } catch {
        // 进程不存在时 tasklist 退出码非 0
      }
    }
    return [...pids];
  }
  for (const pattern of matchers) {
    try {
      const out = execFileSync("pgrep", ["-f", pattern], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      });
      for (const line of out.split(/\r?\n/)) {
        const pid = Number(line.trim());
        if (pid) pids.add(pid);
      }
    } catch {
      // pgrep 无匹配时退出码 1
    }
  }
  pids.delete(process.pid);
  return [...pids];
}

/** 完全退出客户端；返回仍在运行的 PID（空数组表示已退出）。 */
export async function stopClient(matchers, { timeoutMs = 15000 } = {}) {
  const initial = runningPids(matchers);
  if (!initial.length) return [];

  if (isWin) {
    for (const image of matchers) {
      try {
        execFileSync("taskkill", ["/IM", image, "/T", "/F"], { stdio: "ignore" });
      } catch {
        // 已退出
      }
    }
  } else {
    for (const pid of initial) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        // 已退出
      }
    }
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline && runningPids(matchers).length) {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    for (const pid of runningPids(matchers)) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // 已退出
      }
    }
  }

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const left = runningPids(matchers);
    if (!left.length) return [];
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  return runningPids(matchers);
}

/** 以脱离方式启动客户端，不继承本进程的输出与生命周期。 */
export function launchClient(exe, args = []) {
  if (isMac) {
    const appMatch = /^(.*\.app)\/Contents\/MacOS\//.exec(exe);
    if (appMatch) {
      const child = spawn("open", ["-a", appMatch[1]], { detached: true, stdio: "ignore" });
      child.unref();
      return;
    }
  }
  const child = spawn(exe, args, { detached: true, stdio: "ignore", cwd: path.dirname(exe) });
  child.unref();
}

/* ------------------------------------------------------------------ *
 * 文件写入
 * ------------------------------------------------------------------ */

/** 原子写入：同目录临时文件 + rename，保留原文件权限位。 */
export function writeFileAtomic(target, text) {
  let mode = 0o600;
  try {
    mode = fs.statSync(target).mode & 0o777;
  } catch {
    // 文件尚不存在
  }
  const tmp = `${target}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text, { mode });
  try {
    fs.chmodSync(tmp, mode);
  } catch {
    // Windows 上 chmod 无实际意义
  }
  fs.renameSync(tmp, target);
}

export function backupFile(target) {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "Z").replace("T", "-");
  const backup = `${target}.bak-${stamp}`;
  fs.copyFileSync(target, backup);
  return backup;
}

export function listBackups(target) {
  const dir = path.dirname(target);
  const prefix = `${path.basename(target)}.bak-`;
  return fs
    .readdirSync(dir)
    .filter((name) => name.startsWith(prefix))
    .sort()
    .reverse()
    .map((name) => path.join(dir, name));
}
