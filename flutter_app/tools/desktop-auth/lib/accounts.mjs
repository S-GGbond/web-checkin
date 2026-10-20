/**
 * 候选账号来源：checkin-hub.sqlite3 的 accounts 表（与 Flutter / Python 端共用）。
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

/** tools/desktop-auth */
const TOOL_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** 依次尝试：显式参数 → 环境变量 → 仓库各处常见位置。 */
export function resolveHubDb(explicit) {
  const candidates = [
    explicit,
    process.env.CHECKIN_HUB_DB,
    path.join(process.cwd(), "checkin-hub.sqlite3"),
    path.resolve(TOOL_DIR, "..", "..", "checkin-hub.sqlite3"),
    path.resolve(TOOL_DIR, "..", "..", "..", "checkin-hub.sqlite3"),
  ].filter(Boolean);
  for (const candidate of candidates) {
    try {
      if (fs.statSync(candidate).isFile()) return candidate;
    } catch {
      // 继续下一个
    }
  }
  return null;
}

export async function loadAccounts(dbPath, provider) {
  if (!dbPath) throw new Error("未找到 checkin-hub.sqlite3，请用 --hub <路径> 指定");
  let DatabaseSync;
  try {
    ({ DatabaseSync } = await import("node:sqlite"));
  } catch {
    throw new Error(`当前 Node ${process.version} 缺少 node:sqlite，请升级到 Node 22.5+ 或改用客户端内置的切换功能`);
  }
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    const rows = db
      .prepare(
        "SELECT id, provider, external_id, display_name, credential, enabled FROM accounts WHERE provider = ? ORDER BY id",
      )
      .all(provider);
    return rows.map((row) => {
      let parsed = null;
      try {
        parsed = JSON.parse(row.credential);
      } catch {
        // Trae 的 credential 是加密容器，不是 JSON
      }
      return {
        id: row.id,
        provider: row.provider,
        externalId: String(row.external_id ?? ""),
        displayName: row.display_name || String(row.external_id ?? ""),
        credential: String(row.credential ?? ""),
        parsed,
        enabled: row.enabled === 1,
      };
    });
  } finally {
    db.close();
  }
}

/** 支持序号（从 1 开始）、完整 uid、唯一前缀。 */
export function resolveTarget(accounts, spec) {
  const text = String(spec ?? "").trim();
  if (!text) throw new Error("请用 --to <序号|uid> 指定目标账号");
  if (/^\d+$/.test(text)) {
    const index = Number(text);
    if (index >= 1 && index <= accounts.length) return accounts[index - 1];
    throw new Error(`序号 ${index} 超出范围（共 ${accounts.length} 个候选账号）`);
  }
  const exact = accounts.find((account) => account.externalId === text);
  if (exact) return exact;
  const prefixed = accounts.filter((account) => account.externalId.startsWith(text));
  if (prefixed.length === 1) return prefixed[0];
  if (prefixed.length > 1) throw new Error(`uid 前缀「${text}」匹配到多个账号，请写全`);
  throw new Error(`未找到账号「${text}」`);
}

export function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i];
    if (!item.startsWith("--")) {
      args._.push(item);
      continue;
    }
    const key = item.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) args[key] = true;
    else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}
