#!/usr/bin/env node
/**
 * Electron app.asar 只读探针（逆向辅助）
 *
 * 解析 asar 头建立「文件偏移 → 文件路径」映射，再按关键字打印命中位置的上下文，
 * 用于对照客户端 bundle 里的加密常量（WB-AAD / WBEV1 / atRestSecretKey 等）。
 *
 * 用法：
 *   node scan-asar.mjs --asar <app.asar>                 扫描默认关键字
 *   node scan-asar.mjs --asar <app.asar> --marker WB-AAD  只扫指定关键字
 *   node scan-asar.mjs --asar <app.asar> --range 76933000-76948500
 *   node scan-asar.mjs --asar <app.asar> --list           只列出可能相关的文件
 */
import fs from "node:fs";
import path from "node:path";

import { parseArgs } from "./lib/accounts.mjs";

const DEFAULT_MARKERS = [
  "WB-AAD",
  "WBEV1",
  "WBEF1",
  "sym-v1",
  "atRestSecretKey",
  "$wbEncrypted",
  "electron_browser_workbuddy_storage",
];

function parseAsar(buffer) {
  try {
    const headerSize = buffer.readUInt32LE(4);
    const jsonLength = buffer.readUInt32LE(12);
    const header = JSON.parse(buffer.subarray(16, 16 + jsonLength).toString("utf8"));
    const dataStart = 8 + headerSize;
    const files = [];
    const walk = (node, prefix) => {
      if (!node || typeof node !== "object") return;
      if (node.files) {
        for (const [name, child] of Object.entries(node.files)) walk(child, `${prefix}/${name}`);
      } else if (node.offset !== undefined) {
        files.push({ name: prefix, offset: Number(node.offset), size: Number(node.size) });
      }
    };
    walk(header, "");
    return { dataStart, files };
  } catch {
    return { dataStart: null, files: [] };
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const asar = args.asar;
  if (typeof asar !== "string") {
    console.error("请用 --asar <path/to/app.asar> 指定要扫描的文件");
    return 2;
  }
  const buffer = fs.readFileSync(asar);
  const { dataStart, files } = parseAsar(buffer);
  console.log(`asar：${path.resolve(asar)}  大小 ${buffer.length}B  条目 ${files.length}`);

  const whichFile = (offset) => {
    if (dataStart === null) return "(未知)";
    const relative = offset - dataStart;
    const hit = files
      .filter((item) => relative >= item.offset && relative < item.offset + item.size)
      .sort((a, b) => b.offset - a.offset)[0];
    return hit ? hit.name : "(未匹配)";
  };

  if (typeof args.range === "string") {
    const [start, end] = args.range.split("-").map(Number);
    if (Number.isFinite(start) && Number.isFinite(end)) {
      console.log(buffer.subarray(start, end).toString("utf8"));
    }
  }

  if (args.list === true || files.length) {
    console.log("\n可能相关的文件：");
    for (const item of files) {
      if (/workbuddy[-_]?storage|atRest|protector|envelope|crypto|byteCrypto/i.test(item.name)) {
        console.log(`  ${item.name}`);
      }
    }
  }
  if (args.list === true) return 0;

  const markers = typeof args.marker === "string" ? [args.marker] : DEFAULT_MARKERS;
  for (const marker of markers) {
    let index = -1;
    let count = 0;
    const needle = Buffer.from(marker, "utf8");
    while ((index = buffer.indexOf(needle, index + 1)) !== -1 && count < 3) {
      console.log(`\n=== ${JSON.stringify(marker)} @${index}  file=${whichFile(index)} ===`);
      console.log(
        buffer
          .subarray(Math.max(0, index - 400), index + 900)
          .toString("utf8")
          .replace(/\n/g, "\\n"),
      );
      count += 1;
    }
    if (!count) console.log(`\n=== ${JSON.stringify(marker)}：0 命中 ===`);
  }
  return 0;
}

process.exit(main());
