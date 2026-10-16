const fs = require("fs");
const ASAR = "C:/Users/27490/AppData/Local/Programs/WorkBuddy/resources/app.asar";
const buf = fs.readFileSync(ASAR);
console.log("asar size:", buf.length);

// --- 解析 asar 头，建立 offset -> 文件名 映射 ---
let fileMap = [];   // {name, offset, size}
let dataStart = null;
try {
  const headerSize = buf.readUInt32LE(4);
  const jsonLen = buf.readUInt32LE(12);
  const json = JSON.parse(buf.slice(16, 16 + jsonLen).toString("utf8"));
  dataStart = 8 + headerSize;
  (function walk(node, prefix) {
    if (!node || typeof node !== "object") return;
    if (node.files) for (const [k, v] of Object.entries(node.files)) walk(v, prefix + "/" + k);
    else if (typeof node.offset === "string" || typeof node.offset === "number")
      fileMap.push({ name: prefix, offset: Number(node.offset), size: Number(node.size) });
  })(json, "");
  console.log("header parsed OK, dataStart:", dataStart, "files:", fileMap.length);
} catch (e) {
  console.log("asar header parse failed:", e.message, "-> 仅按裸字节搜索");
}
function whichFile(off) {
  if (dataStart == null) return "(未知)";
  const rel = off - dataStart;
  const hit = fileMap
    .filter((f) => rel >= f.offset && rel < f.offset + f.size)
    .sort((a, b) => (a.offset < b.offset ? 1 : -1))[0];
  return hit ? hit.name : "(未匹配)";
}
function scan(marker, max = 3, before = 500, after = 1100) {
  let i = -1, n = 0;
  const b = Buffer.from(marker, "utf8");
  while ((i = buf.indexOf(b, i + 1)) !== -1 && n < max) {
    console.log(`\n=== ${JSON.stringify(marker)} @${i}  file=${whichFile(i)} ===`);
    console.log(buf.slice(Math.max(0, i - before), i + after).toString("utf8").replace(/\n/g, "\\n"));
    n++;
  }
  if (!n) console.log(`\n=== ${JSON.stringify(marker)}: 0 hits ===`);
}
console.log("\n######## file list containing likely dirs ########");
for (const f of fileMap) if (/workbuddy[-_]?storage|atRest|protector|envelope|crypto/i.test(f.name)) console.log(f.name);

scan("WB-AAD", 3);
scan("WBEV1", 3);
scan("WBEF1", 2);
scan("sym-v1", 3);
scan("atRestSecretKey", 3);
scan("$wbEncrypted", 3);
scan("electron_browser_workbuddy_storage", 3);
