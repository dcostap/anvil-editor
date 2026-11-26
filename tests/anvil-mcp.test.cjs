"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const readline = require("node:readline");

// A stand-in for one Anvil Project process: it records each request and answers with its name.
function anvil(name, token) {
  const seen = [];
  const server = http.createServer((request, response) => {
    let body = "";
    request.on("data", chunk => body += chunk);
    request.on("end", () => {
      seen.push({auth: request.headers.authorization, body: JSON.parse(body)});
      const message = JSON.parse(body);
      response.writeHead(request.headers.authorization === "Bearer " + token ? 200 : 401, {"Content-Type": "application/json"});
      response.end(JSON.stringify({jsonrpc: "2.0", id: message.id, result: {served_by: name}}));
    });
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve({server, seen, token,
    url: `http://127.0.0.1:${server.address().port}`})));
}

// Seam: the stdio bridge between an External Agent and Anvil's discovery files.
test("the bridge follows the Project's endpoint across Anvil restarts", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "anvil-mcp-"));
  const project = path.join(dir, "project");
  await fs.mkdir(path.join(dir, "control"), {recursive: true});
  const first = await anvil("first", "a".repeat(64)), second = await anvil("second", "b".repeat(64));
  const other = await anvil("other", "c".repeat(64));
  const record = (file, target, folder) => fs.writeFile(path.join(dir, "control", file), JSON.stringify({version: 1,
    url: target.url, token: target.token, project: folder, pid: process.pid, created: "01dc000000000000"}));
  const bridge = spawn(process.execPath, [path.join(__dirname, "..", "data", "tools", "agent-sessions", "anvil-mcp.cjs"),
    "--userdir", dir, "--project", project], {stdio: ["pipe", "pipe", "inherit"]});
  const replies = new Map();
  readline.createInterface({input: bridge.stdout}).on("line", line => {
    const message = JSON.parse(line);
    replies.get(message.id)?.(message);
  });
  let next = 1;
  const call = method => new Promise(resolve => {
    const id = next++;
    replies.set(id, resolve);
    bridge.stdin.write(JSON.stringify({jsonrpc: "2.0", id, method, params: {}}) + "\n");
  });
  try {
    // Without Anvil, the client still starts, and its calls say why they fail.
    assert.equal((await call("initialize")).result.serverInfo.name, "anvil");
    assert.match((await call("tools/list")).error.message, /has not loaded the Project/);

    await record("100.json", other, path.join(dir, "elsewhere"));
    await record("200.json", first, project + path.sep);
    assert.equal((await call("tools/list")).result.served_by, "first");
    assert.equal(first.seen[0].auth, "Bearer " + first.token);
    assert.equal(first.seen[0].body.method, "tools/list");

    // A restarted Anvil writes a new record. The bridge needs no new config.
    await fs.rm(path.join(dir, "control", "200.json"));
    await record("300.json", second, project);
    assert.equal((await call("tools/call")).result.served_by, "second");
    assert.equal(other.seen.length, 0, "Another Project's endpoint must not get requests");
  } finally {
    bridge.kill();
    for (const target of [first, second, other]) await new Promise(resolve => target.server.close(resolve));
    await fs.rm(dir, {recursive: true, force: true});
  }
});
