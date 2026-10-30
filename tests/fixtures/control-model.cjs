// A local scripted OpenAI endpoint. It never contacts a provider or runs inference.
"use strict";
const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
function text(content) {
  return typeof content === "string" ? content : (content || []).filter(p => p.type === "text").map(p => p.text).join("\n");
}
const server = http.createServer(async (req, res) => {
  try {
    let body = "";
    for await (const chunk of req) body += chunk;
    const request = JSON.parse(body), messages = request.messages || [];
    const user = messages.filter(m => m.role === "user").map(m => text(m.content)).join("\n");
    const names = (request.tools || []).map(t => t.function.name);
    if (!names.includes("mcp__anvil__workspace_state")) throw new Error("Pi did not receive Anvil MCP tools");
    if (!messages.some(m => m.role === "system" && text(m.content).includes("You run inside an Anvil"))) {
      throw new Error("Pi did not receive Anvil instructions");
    }
    let name, args, answer;
    if (!user.includes("ANVIL_PARENT_TASK")) {
      if (!user.includes("ANVIL_CHILD_TASK")) throw new Error("Unknown test task: " + user.slice(-500));
      answer = "ANVIL_CHILD_RESULT";
    } else {
      const last = messages.filter(m => m.role === "tool").at(-1);
      const call = last && messages.flatMap(m => m.tool_calls || []).find(c => c.id === last.tool_call_id);
      let data = last && JSON.parse(text(last.content));
      if (data?.structuredContent) data = data.structuredContent;
      if (!last) { name = "workspace_state"; args = {}; }
      else if (call.function.name.endsWith("workspace_state")) {
        name = "pi_start";
        args = {cwd: root, provider: "anvil-test", model: "scripted", thinking: "off", task: "ANVIL_CHILD_TASK",
          pane: data.caller_pane, placement: "split", direction: "right", request_id: "test-child"};
      } else if (data.operation && data.status === "starting") {
        name = "operation_read"; args = {operation: data.operation};
        await new Promise(resolve => setTimeout(resolve, 250));
      } else if (data.terminal && data.instance && data.task && data.status !== "completed") {
        if (data.status === "failed" || data.status === "interrupted") throw new Error(JSON.stringify(data));
        name = "agent_wait"; args = {terminal: data.terminal, instance: data.instance, task: data.task, timeout_ms: 10000};
      } else if (data.status === "completed" && data.result === "ANVIL_CHILD_RESULT") answer = "ANVIL_PARENT_RESULT";
      else throw new Error("Unexpected tool result: " + JSON.stringify(data));
    }
    const delta = answer ? {role: "assistant", content: answer} : {role: "assistant", tool_calls: [{index: 0,
      id: "call_" + messages.length, type: "function", function: {name: "mcp__anvil__" + name, arguments: JSON.stringify(args)}}]};
    res.writeHead(200, {"content-type": "text/event-stream"});
    const send = (delta, finish) => res.write("data: " + JSON.stringify({id: "scripted", object: "chat.completion.chunk",
      created: 1, model: "scripted", choices: [{index: 0, delta, finish_reason: finish}]}) + "\n\n");
    send(delta, null); send({}, answer ? "stop" : "tool_calls");
    res.end("data: [DONE]\n\n");
  } catch (error) {
    fs.writeFileSync(path.join(root, "model-error.txt"), error.stack);
    res.writeHead(500, {"content-type": "application/json"});
    res.end(JSON.stringify({error: {message: error.message, type: "test_error"}}));
  }
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
