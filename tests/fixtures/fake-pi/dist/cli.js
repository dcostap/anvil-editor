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
// A subcommand such as `pi update` ends when its work is done.
if (args[0] === "update") process.exit(0);
if (!file) {
  const id = crypto.randomUUID();
  file = path.join(dir, `2026-10-18T10-00-00-000Z_${id}.jsonl`);
  const fd = fs.openSync(file, "wx");
  try { fs.writeFileSync(fd, JSON.stringify({ type: "session", id }) + "\n"); } finally { fs.closeSync(fd); }
}
fs.appendFileSync(file, JSON.stringify({ type: "message" }) + "\n");
// Like Pi, load each extension and send it the events of a run that is in a tool call.
const handlers = {};
const pi = { on: (name, handler) => { (handlers[name] = handlers[name] || []).push(handler); return () => {}; } };
for (let i = 0; i + 1 < args.length; i++) {
  if (args[i] !== "--extension") continue;
  const factory = require(args[i + 1]);
  (factory.default || factory)(pi);
}
let model = { id: "gpt-test", name: "GPT Test" };
const emit = (name, event) => (handlers[name] || []).forEach((handler) => handler(event, {model}));
if (process.env.PI_PROGRAM_STATUS === "1") process.stdout.write("\x1b]7501;state=working:app=pi\x1b\\");
emit("session_start", { type: "session_start" });
if (args.includes("--model-events")) {
  process.stdin.setRawMode(true);
  let input = "";
  process.stdin.on("data", (data) => {
    input += data.toString();
    let end;
    while ((end = input.search(/[\r\n]/)) >= 0) {
      const name = input.slice(0, end);
      input = input.slice(end + 1);
      if (!name) continue;
      if (name === "idle") {
        emit("agent_end", { type: "agent_end" });
        process.stdout.write("\x1b]7501;state=idle:app=pi\x1b\\");
      } else {
        model = {id: "selected-model", name};
        emit("model_select", {type: "model_select", model, source: "set"});
      }
    }
  });
}
emit("turn_start", { type: "turn_start" });
emit("message_update", { type: "message_update", assistantMessageEvent: { type: "thinking_start" } });
emit("tool_execution_start", { type: "tool_execution_start", toolCallId: "1", toolName: "bash",
  args: { command: "npm test\nnpm run lint" } });
console.log("FAKE_PI_READY");
setInterval(() => {}, 1000);
