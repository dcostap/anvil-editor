// A stdio MCP server for agents outside Anvil's Terminals, such as Antigravity. It sends each request to the
// Project's Anvil MCP endpoint. It reads the discovery files again for each request, so the agent's MCP config
// stays the same when Anvil restarts with a new port and token.
// Usage: node anvil-mcp.cjs --userdir <Anvil user folder> [--project <Project path>]
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

function key(value) {
  if (typeof value !== "string") return "";
  if (/^anvil-machine:\/\//.test(value)) return value;
  const resolved = path.resolve(value).replace(/[\\/]+$/, "");
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === "EPERM"; }
}

// The live endpoint of the Project, or of the newest Project without --project.
function endpoint() {
  const directory = path.join(userdir, "control");
  let names;
  try { names = fs.readdirSync(directory); } catch { return undefined; }
  let newest;
  for (const name of names) {
    if (!/^\d+\.json$/.test(name)) continue;
    let record;
    try { record = JSON.parse(fs.readFileSync(path.join(directory, name), "utf8")); } catch { continue; }
    if (record?.version !== 1 || !/^http:\/\/127\.0\.0\.1:\d+$/.test(record.url) || typeof record.token !== "string") continue;
    if (!Number.isInteger(record.pid) || !alive(record.pid)) continue;
    if (project) {
      if (key(record.project) === key(project)) return record;
    } else if (!newest || String(record.created) > String(newest.created)) newest = record;
  }
  return newest;
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
    const missing = project ? `Anvil has not loaded the Project ${project}` : "Anvil is not running";
    // The client starts without Anvil. Its tool calls fail until Anvil runs.
    if (message.method === "initialize") {
      return send({jsonrpc: "2.0", id: message.id, result: {protocolVersion: message.params?.protocolVersion || "2025-06-18",
        capabilities: {tools: {listChanged: false}}, serverInfo: {name: "anvil", version: "1"}, instructions: missing}});
    }
    if (answers) failure(message.id, missing);
    return;
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
