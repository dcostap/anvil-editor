// Terminal Sessions load this file into every Node and Bun process they start,
// through NODE_OPTIONS and BUN_OPTIONS. In Pi, it reports which session file Pi
// writes, so a revived Terminal Session can resume that Agent Session. It also
// loads pi-status.cjs into an interactive Pi, which reports Pi's current step to
// the Terminal Session. Other programs return at the executable or package check.
"use strict";
// A failure here must never stop the program that loaded this file.
try { (() => {
  const report = process.env.ANVIL_TERMINAL_AGENT_REPORT;
  if (!report) return;
  const fs = require("fs");
  const path = require("path");

  const runtime = /^(node|bun)(\.exe)?$/i.test(path.basename(process.execPath));
  // A compiled program can sit below an unrelated Pi package, such as ~/.local/bin/claude.exe.
  if (!runtime && !/^pi(\.exe)?$/i.test(path.basename(process.execPath))) return;
  const script = runtime && process.argv[1] ? path.resolve(process.argv[1]) : null;
  if (runtime && !script) return;
  const name = (() => {
    let dir = script ? path.dirname(script) : path.dirname(process.execPath);
    for (let depth = 0; depth < 4; depth++) {
      try { return JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")).name; } catch {}
      const parent = path.dirname(dir);
      if (parent === dir) return null;
      dir = parent;
    }
    return null;
  })();
  if (typeof name !== "string" || !/(^|\/)pi-coding-agent$/.test(name)) return;
  // A Pi that this Pi starts, such as a subagent, is not the terminal's Pi.
  if (process.env.ANVIL_TERMINAL_AGENT_OWNER) return;
  process.env.ANVIL_TERMINAL_AGENT_OWNER = String(process.pid);

  // Pi reads its arguments after this file runs. In every runtime, including Pi's
  // compiled build, they start at process.argv[2]. A subcommand such as
  // `pi update` reads --extension as a package to install, so it gets none, and
  // neither does a run that prints data or turns extensions off.
  // ANVIL_PI_STATUS=0 turns the extension off.
  const subcommands = new Set(["install", "remove", "uninstall", "update", "list", "config", "auth", "mcp"]);
  const skip = new Set(["-p", "--print", "--mode", "-h", "--help", "-v", "--version", "-ne",
    "--no-extensions", "--export", "--list-models"]);
  const given = process.argv.slice(2);
  const options = given.indexOf("--") >= 0 ? given.slice(0, given.indexOf("--")) : given;
  if (!subcommands.has(given[0]) && !options.some((arg) => skip.has(arg.split("=")[0]))) {
    for (const [name, flag] of [["pi-status.cjs", "ANVIL_PI_STATUS"], ["pi-control.cjs", "ANVIL_PI_CONTROL"]]) {
      const extension = path.join(__dirname, name);
      if (process.env[flag] !== "0" && fs.existsSync(extension)) process.argv.splice(2, 0, "--extension", extension);
    }
  }

  const { writeFileSync, renameSync, openSync, appendFileSync } = fs;
  const args = process.argv.slice(script ? 2 : 1);
  let explicit = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--session" && i + 1 < args.length) explicit = args[i + 1];
    else if (args[i].startsWith("--session=")) explicit = args[i].slice(10);
  }
  if (explicit && /\.jsonl$/i.test(explicit)) explicit = path.resolve(explicit);
  let current = null;
  const save = (session) => {
    if (session === current) return;
    current = session;
    const lines = [`pid=${process.pid}`, `ppid=${process.ppid}`, `exe=${process.execPath}`];
    if (script) lines.push(`script=${script}`);
    lines.push(`session=${session}`);
    try {
      writeFileSync(report + ".tmp", lines.join("\n") + "\n");
      renameSync(report + ".tmp", report);
    } catch {}
  };
  if (explicit) save(explicit);

  // Pi names a new session file <ISO time>_<session ID>.jsonl.
  const sessionName = /^\d{4}-\d\d-\d\dT[\d-]+Z_[0-9a-f-]+\.jsonl$/i;
  const written = (file) => {
    if (typeof file !== "string") return;
    const full = path.resolve(file);
    if (sessionName.test(path.basename(full)) || full === explicit) save(full);
  };
  fs.openSync = function (file, flags, ...rest) {
    const fd = openSync.call(this, file, flags, ...rest);
    if (typeof flags === "string" && /[wa]/.test(flags)) written(file);
    return fd;
  };
  fs.appendFileSync = function (file, ...rest) {
    const result = appendFileSync.call(this, file, ...rest);
    written(file);
    return result;
  };
  fs.writeFileSync = function (file, ...rest) {
    const result = writeFileSync.call(this, file, ...rest);
    written(file);
    return result;
  };
  try { require("module").syncBuiltinESMExports(); } catch {}
})(); } catch {}
