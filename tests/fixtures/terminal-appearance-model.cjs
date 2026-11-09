// A local scripted model. It reads one test file and never runs inference.
"use strict";
const http = require("node:http");
const path = require("node:path");
const root = process.argv[2];
const server = http.createServer(async (req, res) => {
  try {
    let body = "";
    for await (const chunk of req) body += chunk;
    const request = JSON.parse(body);
    const done = request.messages.some(message => message.role === "tool");
    const delta = done
      ? {role: "assistant", content: "ANVIL_APPEARANCE_DONE"}
      : {role: "assistant", tool_calls: [{index: 0, id: "appearance_read", type: "function",
        function: {name: "read", arguments: JSON.stringify({path: path.join(root, "ANVIL_APPEARANCE_TOOL.txt")})}}]};
    res.writeHead(200, {"content-type": "text/event-stream"});
    const send = (delta, finish) => res.write("data: " + JSON.stringify({id: "appearance",
      object: "chat.completion.chunk", created: 1, model: "scripted",
      choices: [{index: 0, delta, finish_reason: finish}]}) + "\n\n");
    send(delta, null);
    send({}, done ? "stop" : "tool_calls");
    res.end("data: [DONE]\n\n");
  } catch (error) {
    res.writeHead(500, {"content-type": "application/json"});
    res.end(JSON.stringify({error: {message: error.message, type: "test_error"}}));
  }
});
server.listen(0, "127.0.0.1", () => console.log(server.address().port));
