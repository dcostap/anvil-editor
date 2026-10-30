"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");

async function until(check) {
  const deadline = Date.now() + 10000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("Control exchange did not finish");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

test("interactive Pi connects, receives each task once, and reports completion only after settlement", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "anvil-pi-control-"));
  const report = path.join(dir, "terminal-sessions", "terminal.agent");
  const old = process.env.ANVIL_TERMINAL_AGENT_REPORT;
  process.env.ANVIL_TERMINAL_AGENT_REPORT = report;
  const handlers = new Map(), sent = [], deliveries = [], entries = [], servers = [];
  let commands = [], latest, idle = true, aborted = false;
  const ctx = {
    mode: "tui", isIdle: () => idle, abort: () => { aborted = true; },
    model: { provider: "local", id: "scripted" },
    sessionManager: { getSessionFile: () => "test.jsonl", getBranch: () => entries },
    ui: { notify() {} },
  };
  const pi = {
    on(name, fn) { handlers.set(name, fn); },
    registerMcpServer(name, config) { servers.push({ name, config }); },
    unregisterMcpServer() {},
    getThinkingLevel: () => "off",
    appendEntry(customType, data) { entries.push({ type: "custom", customType, data }); },
    sendMessage(message, options) { sent.push(message); deliveries.push(options); idle = false; },
  };
  const server = http.createServer(async (req, res) => {
    assert.equal(req.headers.authorization, "Bearer test-secret");
    let body = "";
    for await (const chunk of req) body += chunk;
    latest = JSON.parse(body);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ commands }));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    await fs.mkdir(path.join(dir, "control", "terminals"), { recursive: true });
    await fs.writeFile(path.join(dir, "control", "terminals", "terminal.json"), JSON.stringify({
      version: 1, url: `http://127.0.0.1:${server.address().port}`, token: "test-secret",
    }));
    require("../data/tools/agent-sessions/pi-control.cjs")(pi);
    await handlers.get("session_start")({ reason: "startup" }, ctx);
    await until(() => latest && servers.length);
    assert.equal(servers[0].name, "anvil");
    assert.equal(servers[0].config.url, `http://127.0.0.1:${server.address().port}/mcp`);
    commands = [{ id: "task-a", action: "send", text: "Review this change", delivery: "queue", from: "other-terminal" }];
    await until(() => sent.length === 1 && latest.receipts?.some(r => r.id === "task-a"));
    assert.ok(sent[0].content.includes("Anvil agent task from other-terminal"));
    assert.ok(sent[0].content.endsWith("Review this change"));
    assert.equal(sent[0].details.from, "other-terminal");
    await handlers.get("message_end")({ message: { role: "assistant", content: [{ type: "text", text: "Looks good" }], stopReason: "stop" } }, ctx);
    if (handlers.has("agent_end")) await handlers.get("agent_end")({}, ctx);
    assert.ok(!latest.tasks?.some(t => t.status === "completed"));
    idle = true;
    await handlers.get("agent_settled")({ aborted: false }, ctx);
    await until(() => latest.tasks?.some(t => t.id === "task-a" && t.status === "completed"));
    assert.equal(latest.tasks.find(t => t.id === "task-a").result, "Looks good");
    assert.equal(sent.length, 1, "A repeated command must not send the task twice");
    idle = false; // The user has started a separate turn.
    commands = Array.from({ length: 17 }, (_, i) => ({id: "queued-" + i, action: "send", delivery: "queue", text: "Wait for idle"}));
    await until(() => latest.receipts?.some(r => r.id === "queued-16" && r.status === "failed"));
    assert.equal(sent.length, 1, "Queued work must not interrupt the user's turn");
    commands = [{id: "steer-a", action: "send", delivery: "steer", text: "Use this constraint", from: "other-terminal"}];
    await until(() => latest.receipts?.some(r => r.id === "steer-a"));
    assert.equal(sent[1].customType, "anvil-steering");
    assert.equal(deliveries[1].deliverAs, "steer");
    commands = [{ id: "stop-a", action: "interrupt" }];
    await until(() => aborted && latest.tasks?.filter(t => t.id.startsWith("queued-") && t.status === "interrupted").length === 16);
    await handlers.get("session_shutdown")({ reason: "reload" }, ctx);
    commands = [{ id: "task-a", action: "send", text: "Review this change", delivery: "queue" }];
    handlers.clear();
    require("../data/tools/agent-sessions/pi-control.cjs")(pi);
    latest = null;
    await handlers.get("session_start")({ reason: "reload" }, ctx);
    await until(() => latest?.tasks?.some(t => t.id === "task-a" && t.status === "completed"));
    assert.equal(sent.length, 2, "Reload must retain completed task receipts and cancelled queues");
  } finally {
    if (handlers.has("session_shutdown")) await handlers.get("session_shutdown")({ reason: "quit" }, ctx);
    await new Promise(resolve => server.close(resolve));
    if (old === undefined) delete process.env.ANVIL_TERMINAL_AGENT_REPORT;
    else process.env.ANVIL_TERMINAL_AGENT_REPORT = old;
    await fs.rm(dir, { recursive: true, force: true });
  }
});
