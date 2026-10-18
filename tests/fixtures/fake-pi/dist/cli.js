// A stand-in for Pi's npm build. It writes its session file the way Pi does
// and logs the arguments of each launch beside its sessions.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const option = (name) => { const index = args.indexOf(name); return index >= 0 ? args[index + 1] : undefined; };
let file = option("--session");
const dir = file ? path.dirname(file) : option("--session-dir");
fs.appendFileSync(path.join(dir, "launches.log"), JSON.stringify(args) + "\n");
if (!file) {
  const id = crypto.randomUUID();
  file = path.join(dir, `2026-10-18T10-00-00-000Z_${id}.jsonl`);
  const fd = fs.openSync(file, "wx");
  try { fs.writeFileSync(fd, JSON.stringify({ type: "session", id }) + "\n"); } finally { fs.closeSync(fd); }
}
fs.appendFileSync(file, JSON.stringify({ type: "message" }) + "\n");
console.log("FAKE_PI_READY");
setInterval(() => {}, 1000);
