// A Pi extension that reports what Pi does, such as "Thinking" or "bash: npm test", to the Anvil Terminal Session
// it runs in. The pi.cjs preload loads it into an interactive Pi in an Anvil Terminal Session.
// It sends a "step" child record of the Program Status Protocol (OSC 7501) beside Pi's own status. It only
// listens: it adds no tools, commands or session entries, and it does not change what the model sees.
"use strict";

// Tool arguments that say best what a tool works on, in order of preference.
const DETAIL_KEYS = ["command", "path", "file_path", "pattern", "query", "url", "title"];
const DETAIL_MAX = 200;

function detail(args) {
  if (!args || typeof args !== "object") return "";
  for (const key of DETAIL_KEYS) {
    const value = args[key];
    if (typeof value !== "string" || !value.trim()) continue;
    const line = value.trim().split(/\r?\n/)[0].replace(/\s+/g, " ");
    return line.length > DETAIL_MAX ? line.slice(0, DETAIL_MAX) + "\u2026" : line;
  }
  return "";
}

module.exports = function (pi) {
  // Pi's interactive TUI writes to a terminal. In print, JSON and RPC modes, standard output carries data.
  if (!process.env.ANVIL_TERMINAL_AGENT_REPORT) return;
  let current = null;
  const report = (step) => {
    if (step === current || !process.stdout.isTTY) return;
    current = step;
    try {
      process.stdout.write(step === null ? "\x1b]7501;state=clear:id=step\x1b\\"
        : `\x1b]7501;state=working:id=step:msg=${Buffer.from(step, "utf8").toString("base64")}\x1b\\`);
    } catch {}
  };
  // Tools can run at the same time. The step names the newest one that still runs.
  const tools = new Map();
  const newestTool = () => {
    let step = null;
    for (const value of tools.values()) step = value;
    return step;
  };
  const on = (event, handler) => pi.on(event, (...args) => { try { handler(...args); } catch {} });

  on("turn_start", () => report(newestTool() || "Waiting for the model"));
  on("message_update", (event) => {
    if (tools.size) return;
    const type = event.assistantMessageEvent && event.assistantMessageEvent.type;
    if (type === "thinking_start" || type === "thinking_delta") report("Thinking");
    else if (type === "text_start" || type === "text_delta") report("Writing");
    else if (type === "toolcall_start" || type === "toolcall_delta") report("Preparing a tool call");
  });
  on("tool_execution_start", (event) => {
    const text = detail(event.args);
    tools.set(event.toolCallId, text ? `${event.toolName}: ${text}` : event.toolName);
    report(newestTool());
  });
  on("tool_execution_end", (event) => {
    tools.delete(event.toolCallId);
    report(newestTool() || "Waiting for the model");
  });
  on("agent_end", () => { tools.clear(); report(null); });
  on("session_shutdown", () => { tools.clear(); report(null); });
};
