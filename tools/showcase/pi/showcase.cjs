// A Pi extension for screenshots. run_showcase.py loads it into the real Pi, which talks to a canned local model.
// It types the scenario's prompt, asks before the scenario's gated command, and backdates Pi's status so the
// Project Sidebar shows believable times. A backdated report repeats the fields that Pi or pi-status.cjs sends,
// and the Terminal host keeps the earlier start time whichever report arrives first.
"use strict";
const fs = require("fs");

module.exports = function (pi) {
  const agent = JSON.parse(fs.readFileSync(process.env.ANVIL_SHOWCASE_AGENTS, "utf8"))[process.env.ANVIL_SHOWCASE_AGENT];
  if (!agent) return;
  const ages = agent.ages || {};
  const base64 = (text) => Buffer.from(text, "utf8").toString("base64");
  const report = (pairs, ago) => setTimeout(() => {
    process.stdout.write(`\x1b]7501;${pairs}:since=${Math.floor(Date.now() / 1000) - ago}\x1b\\`);
  }, 300);
  const reportStep = (step) => {
    if (step === agent.step) report(`state=working:id=step:msg=${base64(step)}`, ages.step);
  };

  pi.on("session_start", () => setTimeout(() => pi.sendUserMessage(agent.prompt), 500));
  pi.on("agent_start", () => { if (ages.working) report("state=working:app=pi", ages.working); });
  pi.on("agent_end", () => { if (ages.done) report("state=done:app=pi", ages.done); });
  pi.on("tool_execution_start", (event) => {
    const args = event.args || {};
    reportStep(`${event.toolName}: ${args.command || args.path || ""}`);
  });
  pi.on("message_update", (event) => {
    if (event.assistantMessageEvent && event.assistantMessageEvent.type === "thinking_delta") reportStep("Thinking");
  });
  pi.on("tool_call", async (event, ctx) => {
    const command = event.toolName === "bash" && event.input && event.input.command;
    if (!agent.confirm || !command || !command.startsWith(agent.confirm.command)) return;
    const answer = ctx.ui.confirm(agent.confirm.title, command);
    report(`state=blocked:app=pi:kind=question:msg=${base64(agent.confirm.title)}`, ages.blocked);
    if (!(await answer)) return { block: true, reason: "The user did not allow it." };
  });
};
