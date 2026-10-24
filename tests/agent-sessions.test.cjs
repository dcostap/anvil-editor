"use strict";
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

// Run compiled programs with the real Bun preload, without starting an editor.
test("the Pi preload leaves other compiled programs unchanged below a Pi package", (t) => {
  const bun = spawnSync("bun", ["--version"], { encoding: "utf8" });
  if (bun.error && bun.error.code === "ENOENT") return t.skip("Bun is not installed");
  assert.equal(bun.status, 0, bun.stderr);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "anvil-agent-preload-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }));
  const bin = path.join(root, ".local", "bin");
  fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(root, "package.json"), JSON.stringify({ name: "@earendil-works/pi-coding-agent" }));
  const source = path.join(root, "probe.cjs");
  fs.writeFileSync(source, `console.log(JSON.stringify({
    args: process.argv.slice(2),
    owner: process.env.ANVIL_TERMINAL_AGENT_OWNER || null
  }));\n`);
  const suffix = process.platform === "win32" ? ".exe" : "";
  const claude = path.join(bin, "claude" + suffix);
  const env = { ...process.env, ANVIL_TERMINAL_AGENT_REPORT: path.join(root, "probe.agent") };
  delete env.ANVIL_TERMINAL_AGENT_OWNER;
  delete env.ANVIL_PI_STATUS;
  delete env.NODE_OPTIONS;
  delete env.BUN_OPTIONS;
  const build = spawnSync("bun", ["build", "--compile", source, "--outfile", claude], {
    env, cwd: root, encoding: "utf8", timeout: 60000
  });
  assert.equal(build.status, 0, build.stderr);

  const preload = path.resolve(__dirname, "../data/tools/agent-sessions/pi.cjs");
  // Relative preload paths also work when the temp or source folder has spaces.
  for (const name of ["pi.cjs", "pi-status.cjs"]) {
    fs.copyFileSync(path.join(path.dirname(preload), name), path.join(root, name));
  }
  env.BUN_OPTIONS = "--preload ./pi.cjs";
  const run = (exe) => {
    const result = spawnSync(exe, [], { env, cwd: root, encoding: "utf8", timeout: 30000 });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout.trim());
  };
  const other = run(claude);
  assert.deepEqual(other.args, [], "Claude received Pi arguments");
  assert.equal(other.owner, null, "Claude claimed the terminal's Pi session");

  const pi = path.join(bin, "pi" + suffix);
  fs.renameSync(claude, pi);
  const agent = run(pi);
  assert.deepEqual(agent.args, ["--extension", path.join(root, "pi-status.cjs")]);
  assert.match(agent.owner, /^\d+$/);
});
