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
    on(name, fn) {
      const previous = handlers.get(name);
      handlers.set(name, async (...args) => { await previous?.(...args); return fn(...args); });
    },
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
    const prompt = {systemPromptOptions: {sections: {}}};
    await handlers.get("before_agent_start")(prompt, ctx);
    assert.ok(prompt.systemPromptOptions.sections.anvil.includes("An Anvil Agent is an agent running inside Anvil."));
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

// Seam: Anvil's read-only exchange with a live Pi extension. No model or clipboard is involved.
test("Pi exposes paged conversation text and live parallel tools without starting a turn", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "anvil-pi-inspect-"));
  const old = process.env.ANVIL_TERMINAL_AGENT_REPORT;
  process.env.ANVIL_TERMINAL_AGENT_REPORT = path.join(dir, "terminal-sessions", "inspect.agent");
  const handlers = new Map();
  let requests = [], acks = [], latest, idle = false, sent = 0, sessionName = "Inspection";
  const timestamp = "2026-01-01T00:00:00.000Z";
  const entries = [
    {id: "system", type: "message", timestamp, message: {role: "system", content: "PRIVATE SYSTEM"}},
    {id: "user", type: "message", timestamp, message: {role: "user", content: "Check this"}},
    {id: "summary", type: "compaction", timestamp, summary: "Earlier work"},
    {id: "assistant", type: "message", timestamp, message: {role: "assistant", content: [
      {type: "thinking", thinking: "PRIVATE THINKING"}, {type: "text", text: "Checking"},
      {type: "toolCall", id: "call-a", name: "bash", arguments: {command: "npm test"}},
    ]}},
    {id: "tool", type: "message", timestamp, message: {role: "toolResult", toolName: "bash", toolCallId: "call-a",
      content: [{type: "text", text: "Passed"}], isError: false}},
    {id: "agent", type: "custom_message", timestamp, customType: "anvil-task", content: "Review this",
      details: {from: "other-terminal"}},
    {id: "long", type: "message", timestamp, message: {role: "assistant", content: [{type: "text", text: "😀".repeat(2000)}]}},
  ];
  const ctx = {mode: "tui", isIdle: () => idle, model: {provider: "local", id: "scripted"},
    sessionManager: {getSessionFile: () => "inspect.jsonl", getBranch: () => entries,
      getLeafId: () => entries.at(-1)?.id, getSessionName: () => sessionName}};
  const pi = {on(name, fn) {
      const previous = handlers.get(name);
      handlers.set(name, async (...args) => { await previous?.(...args); return fn(...args); });
    }, registerMcpServer() {}, unregisterMcpServer() {},
    getThinkingLevel: () => "off", appendEntry() {throw new Error("Inspection must not write session entries");},
    sendMessage() {sent++;}};
  const replies = new Map();
  const server = http.createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    latest = JSON.parse(body);
    // Anvil bounds each transcript reply, including metadata outside the text budget.
    if (latest.transcripts?.some(reply => Buffer.byteLength(JSON.stringify(reply)) > 256 * 1024)) {
      res.writeHead(400);
      res.end();
      return;
    }
    for (const reply of latest.transcripts || []) {
      replies.set(reply.id, reply);
      requests = requests.filter(request => request.id !== reply.id);
      acks.push(reply.id);
    }
    res.writeHead(200, {"content-type": "application/json"});
    res.end(JSON.stringify({commands: [], transcript_requests: requests, transcript_acks: acks}));
    acks = [];
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  let sequence = 0;
  const read = async options => {
    const id = "read-" + ++sequence;
    requests.push({id, options});
    await until(() => replies.has(id));
    const reply = replies.get(id);
    if (reply.error) throw new Error(reply.error);
    return reply.result;
  };
  try {
    await fs.mkdir(path.join(dir, "control", "terminals"), {recursive: true});
    await fs.writeFile(path.join(dir, "control", "terminals", "inspect.json"), JSON.stringify({
      version: 1, url: `http://127.0.0.1:${server.address().port}`, token: "test-secret",
    }));
    require("../data/tools/agent-sessions/pi-control.cjs")(pi);
    await handlers.get("session_start")({reason: "startup"}, ctx);
    await until(() => latest);
    assert.equal(latest.capabilities?.transcript, true);
    let page = await read({limit: 2, max_chars: 1000});
    assert.deepEqual(page.messages.map(m => m.id), ["agent", "long"]);
    assert.equal(page.messages[0].role, "custom");
    assert.equal(page.messages[0].from, "other-terminal");
    assert.equal(page.messages[1].truncated, true);
    assert.equal(page.next_before, "agent");
    assert.equal(page.active_turn, true);
    let text = page.messages[1].text, offset = page.messages[1].next_offset;
    while (offset !== undefined) {
      const more = await read({entry_id: "long", offset, max_chars: 999});
      text += more.messages[0].text;
      offset = more.messages[0].next_offset;
    }
    assert.equal(text, "😀".repeat(2000), "Text chunks must not lose or split Unicode characters");
    page = await read({before: page.next_before, limit: 10});
    assert.deepEqual(page.messages.map(m => m.id), ["user", "summary", "assistant"]);
    assert.equal(page.messages[2].text, "Checking");
    assert.equal(page.next_before, undefined);
    const detailed = await read({before: "agent", include_tools: true, include_summaries: false});
    assert.deepEqual(detailed.messages.map(m => m.id), ["user", "assistant", "tool"]);
    assert.match(detailed.messages[1].text, /npm test/);
    assert.equal(detailed.messages[2].tool_call_id, "call-a");
    assert.ok(!JSON.stringify(detailed).includes("PRIVATE"));
    await assert.rejects(read({before: "missing"}), /branch/);
    await assert.rejects(read({entry_id: "long", offset: 1}), /offset/);
    // Navigation changes the active branch. Reads must not return abandoned messages.
    entries.splice(3);
    await assert.rejects(read({entry_id: "long"}), /branch/);
    assert.deepEqual((await read({limit: 1})).messages.map(m => m.id), ["summary"]);
    await handlers.get("tool_execution_start")({toolCallId: "a", toolName: "bash", args: {command: "npm test"}}, ctx);
    await handlers.get("tool_execution_start")({toolCallId: "b", parentToolCallId: "a", toolName: "read", args: {path: "src/main.c"}}, ctx);
    await handlers.get("message_update")({message: {role: "assistant", content: []}, assistantMessageEvent: {type: "text_delta"}}, ctx);
    await until(() => latest.activity?.tool_count === 2);
    assert.equal(latest.activity.phase, "running_tools");
    assert.equal(latest.activity.tools[0].detail, "npm test");
    assert.equal(latest.activity.tools[1].parent_id, "a");
    assert.ok(latest.activity.tools.every(tool => tool.started_at > 0));
    await handlers.get("ui_prompt_start")({kind: "confirm", title: "Allow command?"}, ctx);
    await until(() => latest.activity?.phase === "waiting_user");
    await handlers.get("ui_prompt_end")({}, ctx);
    await handlers.get("tool_execution_end")({toolCallId: "a"}, ctx);
    await until(() => latest.activity?.tool_count === 1);
    assert.equal(latest.activity.tools[0].id, "b");
    await handlers.get("tool_execution_end")({toolCallId: "b"}, ctx);
    await handlers.get("session_before_compact")({}, ctx);
    await until(() => latest.activity?.phase === "compacting");
    await handlers.get("ui_prompt_start")({kind: "confirm", title: "Use this summary?"}, ctx);
    await until(() => latest.activity?.phase === "waiting_user");
    await handlers.get("ui_prompt_end")({}, ctx);
    await until(() => latest.activity?.phase === "compacting");
    await handlers.get("session_compact")({}, ctx);
    await until(() => latest.activity?.phase === "waiting_model");
    await handlers.get("message_update")({message: {role: "assistant", content: [{type: "text", text: "Still writing"}]},
      assistantMessageEvent: {type: "text_delta"}}, ctx);
    await until(() => latest.activity?.phase === "writing");
    assert.equal((await read({include_partial: true})).partial_message.text, "Still writing");
    assert.equal((await read({})).partial_message, undefined);
    idle = true;
    await handlers.get("agent_settled")({aborted: false}, ctx);
    await until(() => latest.activity?.phase === "idle");
    assert.equal(latest.activity.tool_count, 0);
    entries.splice(0);
    assert.deepEqual((await read({})).messages, []);
    sessionName = "界".repeat(100000);
    await assert.rejects(read({max_chars: 256}), /too large/);
    sessionName = "Inspection";
    assert.deepEqual((await read({})).messages, [], "A failed read must not block later control exchanges");
    assert.equal(sent, 0);
  } finally {
    await handlers.get("session_shutdown")?.({reason: "quit"}, ctx);
    await new Promise(resolve => server.close(resolve));
    if (old === undefined) delete process.env.ANVIL_TERMINAL_AGENT_REPORT;
    else process.env.ANVIL_TERMINAL_AGENT_REPORT = old;
    await fs.rm(dir, {recursive: true, force: true});
  }
});
