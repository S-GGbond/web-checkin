const fs = require("fs");
const ASAR = "C:/Users/27490/AppData/Local/Programs/WorkBuddy/resources/app.asar";
const buf = fs.readFileSync(ASAR);
const start = 76933000, end = 76948500;
fs.writeFileSync("C:/Users/27490/Documents/Trae-CN/temp_20261016_01/wb_region.txt", buf.slice(start, end).toString("utf8"));
console.log("dumped", end - start, "bytes");

// 再找 keyId / secret key 的来源
const marks = ["deriveKeyId", "atRestSecretKey", "workbuddy_storage", "keyId", "sha256", "WB-WRAP"];
for (const m of marks) {
  let i = -1, n = 0;
  while ((i = buf.indexOf(Buffer.from(m, "utf8"), i + 1)) !== -1 && n < 4) {
    console.log(`\n##### ${m} @${i} #####`);
    console.log(buf.slice(Math.max(0, i - 220), i + 320).toString("utf8").replace(/\n/g, "\\n"));
    n++;
  }
  if (!n) console.log(`\n##### ${m}: 0 hits #####`);
}
