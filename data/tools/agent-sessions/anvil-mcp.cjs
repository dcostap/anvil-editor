// A stdio MCP server for agents outside Anvil's Terminals, such as Antigravity. It sends each request to Anvil's
// MCP server, which serves all Projects of this user folder. It reads the discovery file again for each request, so
// the agent's MCP config stays the same when Anvil restarts with a new port and token.
// Usage: node anvil-mcp.cjs --userdir <Anvil user folder> [--project <default Project path>]
// A tool call without `project` uses the default Project.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

function option(name) {
  const index = process.argv.indexOf(name);
  return index > 0 ? process.argv[index + 1] : undefined;
}
const userdir = option("--userdir") || process.env.ANVIL_USERDIR;
const project = option("--project");

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === "EPERM"; }
}

// The live endpoint of the Machine server.
function endpoint() {
  let record;
  try { record = JSON.parse(fs.readFileSync(path.join(userdir, "machine", "mcp.json"), "utf8")); } catch { return undefined; }
  if (record?.version !== 1 || !/^http:\/\/127\.0\.0\.1:\d+$/.test(record.url) || typeof record.token !== "string") return undefined;
  return Number.isInteger(record.pid) && alive(record.pid) ? record : undefined;
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function failure(id, message) {
  send({jsonrpc: "2.0", id, error: {code: -32000, message}});
}

async function handle(line) {
  let message;
  try { message = JSON.parse(line); } catch {
    return send({jsonrpc: "2.0", id: null, error: {code: -32700, message: "Parse error"}});
  }
  const answers = message?.id !== undefined && message?.id !== null;
  const target = endpoint();
  if (!target) {
    const missing = "Anvil is not running";
    // The client starts without Anvil. Its tool calls fail until Anvil runs.
    if (message.method === "initialize") {
      return send({jsonrpc: "2.0", id: message.id, result: {protocolVersion: message.params?.protocolVersion || "2025-06-18",
        capabilities: {tools: {listChanged: false}}, serverInfo: {name: "anvil", version: "1"}, instructions: missing}});
    }
    if (answers) failure(message.id, missing);
    return;
  }
  const args = message.method === "tools/call" && message.params?.arguments;
  if (project && args && typeof args === "object" && args.project === undefined) {
    args.project = project;
    line = JSON.stringify(message);
  }
  try {
    const response = await fetch(target.url + "/mcp", {method: "POST", body: line, redirect: "error",
      headers: {Authorization: "Bearer " + target.token, "Content-Type": "application/json", Accept: "application/json"}});
    if (!answers) return;
    if (!response.ok) throw new Error(`Anvil refused the request (HTTP ${response.status})`);
    send(await response.json());
  } catch (error) {
    if (answers) failure(message.id, String(error.message || error));
  }
}

if (!userdir) {
  process.stderr.write("anvil-mcp: pass --userdir <Anvil user folder>\n");
  process.exit(2);
}
readline.createInterface({input: process.stdin}).on("line", line => {
  if (line.trim()) handle(line);
});
