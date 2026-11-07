// Read-only Pi data. Never send prompts or append entries. Thinking text appears only on request.
"use strict";

// Clip to `max` UTF-16 units without splitting a surrogate pair.
function clip(text, max) {
  if (text.length <= max) return text;
  let end = max;
  if (end > 0 && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
  return text.slice(0, end);
}

// `toolChars` caps each tool call's arguments in a page. A capped entry has no valid offsets.
function contentText(content, options, toolChars, state = {}) {
  if (typeof content === "string") return content;
  return (Array.isArray(content) ? content : []).map(block => {
    if (block.type === "text") return block.text;
    if (block.type === "image") return "[image]";
    if (options.include_thinking && block.type === "thinking" && typeof block.thinking === "string" && block.thinking.trim()) {
      return `(thinking) ${block.thinking}`;
    }
    if (options.include_tools && block.type === "toolCall") {
      let args = JSON.stringify(block.arguments ?? {});
      if (toolChars !== undefined && args.length > toolChars) { args = clip(args, toolChars) + "…"; state.capped = true; }
      return `→ ${block.name} ${args}`;
    }
    return "";
  }).filter(Boolean).join("\n");
}

function conversationEntry(entry, options, toolChars) {
  const result = {id: entry.id, timestamp: entry.timestamp};
  if (entry.type === "compaction" || entry.type === "branch_summary") {
    if (options.include_summaries === false) return;
    result.role = entry.type === "compaction" ? "compaction_summary" : "branch_summary";
    result.text = entry.summary;
  } else if (entry.type === "model_change") {
    result.role = "model";
    result.text = `${entry.provider}/${entry.modelId}`;
  } else if (entry.type === "thinking_level_change") {
    result.role = "thinking_level";
    result.text = entry.thinkingLevel;
  } else {
    const message = entry.type === "custom_message" ? {role: "custom", ...entry} : entry.message;
    if (entry.type !== "message" && entry.type !== "custom_message" || !message) return;
    if (message.role === "toolResult" && options.include_tools) {
      result.tool_name = message.toolName;
      result.tool_call_id = message.toolCallId;
      result.is_error = message.isError;
      if (Number.isFinite(message.durationMs)) result.duration_ms = message.durationMs;
    } else if (message.role !== "user" && message.role !== "assistant" && message.role !== "custom") return;
    result.role = message.role;
    const state = {};
    result.text = contentText(message.content, options, message.role === "assistant" ? toolChars : undefined, state);
    if (state.capped) result.capped = true;
    if (message.role === "custom") {
      result.custom_type = message.customType;
      if (message.customType === "anvil-task" || message.customType === "anvil-steering") result.from = message.details?.from;
    }
    if (message.role === "assistant") result.stop_reason = message.stopReason;
  }
  return typeof result.text === "string" && result.text.trim() ? result : undefined;
}

// Offsets count UTF-16 code units. Never return half of a surrogate pair.
function textChunk(text, offset, budget) {
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > text.length
      || offset > 0 && /[\uDC00-\uDFFF]/.test(text[offset]) && /[\uD800-\uDBFF]/.test(text[offset - 1])) {
    throw new Error("Invalid text offset");
  }
  let end = Math.min(text.length, offset + budget);
  if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) end--;
  return {text: text.slice(offset, end), offset, total_chars: text.length, truncated: end < text.length,
    ...(end < text.length ? {next_offset: end} : {})};
}

function messageText(message) {
  return contentText(message?.content, {}).trim();
}

// Whole-branch facts for one cheap "what did this agent do" read.
function overview(branch) {
  const counts = {user: 0, assistant: 0, agent_tasks: 0, tool_results: 0, tool_errors: 0, compactions: 0, branch_summaries: 0};
  const usage = {input: 0, output: 0, cache_read: 0, cache_write: 0, cost: 0};
  const tools = {}, models = [], thinking = [];
  let first, last, start, end, context;
  const excerpt = (entry, text) => entry && text && {id: entry.id, text: clip(text, 500), total_chars: text.length};
  for (const entry of branch) {
    if (entry.timestamp) { start ??= entry.timestamp; end = entry.timestamp; }
    if (entry.type === "compaction") counts.compactions++;
    else if (entry.type === "branch_summary") counts.branch_summaries++;
    else if (entry.type === "model_change") {
      const model = `${entry.provider}/${entry.modelId}`;
      if (models.at(-1) !== model) models.push(model);
    } else if (entry.type === "thinking_level_change") {
      if (thinking.at(-1) !== entry.thinkingLevel) thinking.push(entry.thinkingLevel);
    } else if (entry.type === "custom_message" && entry.customType === "anvil-task") {
      counts.agent_tasks++;
      first ??= excerpt(entry, messageText(entry));
    } else if (entry.type === "message") {
      const message = entry.message || {};
      if (message.role === "user") { counts.user++; first ??= excerpt(entry, messageText(message)); }
      else if (message.role === "toolResult") { counts.tool_results++; if (message.isError) counts.tool_errors++; }
      else if (message.role === "assistant") {
        counts.assistant++;
        for (const block of Array.isArray(message.content) ? message.content : []) {
          if (block.type === "toolCall") tools[block.name] = (tools[block.name] || 0) + 1;
        }
        const text = messageText(message);
        if (text) last = excerpt(entry, text);
        const u = message.usage;
        if (u) {
          usage.input += u.input || 0; usage.output += u.output || 0;
          usage.cache_read += u.cacheRead || 0; usage.cache_write += u.cacheWrite || 0;
          usage.cost += u.cost?.total || 0;
          context = (u.input || 0) + (u.cacheRead || 0) + (u.cacheWrite || 0) + (u.output || 0);
        }
      }
    }
  }
  return {start, end, counts, tools, models, thinking_levels: thinking, usage, context_tokens: context,
    first_request: first, last_answer: last};
}

function tokens(count) {
  return count >= 1e6 ? (count / 1e6).toFixed(1) + "M" : count >= 1e3 ? Math.round(count / 1e3) + "k" : String(count);
}

const ROLE_LABELS = {compaction_summary: "compaction summary", branch_summary: "branch summary", thinking_level: "thinking level"};

function roleLabel(message) {
  if (message.role === "toolResult") {
    return ["tool", message.tool_name, message.is_error && "error",
      message.duration_ms !== undefined && `${message.duration_ms}ms`].filter(Boolean).join(" ");
  }
  if (message.role === "custom") return [message.custom_type, message.from && `from ${message.from}`].filter(Boolean).join(" ");
  return ROLE_LABELS[message.role] || message.role;
}

// Plain text for models. It avoids the JSON escaping of text that is often JSON itself.
function renderText(result) {
  const out = [];
  if (result.overview) {
    const o = result.overview, c = o.counts, u = o.usage;
    const minutes = o.start && o.end ? Math.round((Date.parse(o.end) - Date.parse(o.start)) / 60000) : 0;
    out.push([result.session_name && `session "${result.session_name}"`, result.active_turn ? "turn active" : "idle",
      result.session_file && `file ${result.session_file}`].filter(Boolean).join(" · "));
    if (o.start) out.push(`${o.start.slice(0, 19).replace("T", " ")} → ${o.end.slice(0, 19).replace("T", " ")} UTC (${minutes} min)`);
    out.push([`${c.user} user`, c.agent_tasks && `${c.agent_tasks} agent tasks`, `${c.assistant} assistant`,
      `${c.tool_results} tool results (${c.tool_errors} errors)`, c.compactions && `${c.compactions} compactions`,
      c.branch_summaries && `${c.branch_summaries} branch summaries`].filter(Boolean).join(" · "));
    const tools = Object.entries(o.tools).sort((a, b) => b[1] - a[1]);
    if (tools.length) out.push("tools: " + tools.map(([name, count]) => `${name} ${count}`).join(", "));
    if (o.models.length || o.thinking_levels.length) {
      out.push([o.models.length && "models: " + o.models.join(" → "),
        o.thinking_levels.length && "thinking: " + o.thinking_levels.join(" → ")].filter(Boolean).join(" · "));
    }
    out.push(`tokens: input ${tokens(u.input)} · output ${tokens(u.output)} · cache read ${tokens(u.cache_read)}`
      + ` · cache write ${tokens(u.cache_write)} · cost $${u.cost.toFixed(2)}`
      + (o.context_tokens !== undefined ? ` · context ${tokens(o.context_tokens)}` : ""));
    for (const [label, part] of [["first request", o.first_request], ["last answer", o.last_answer]]) {
      if (part) out.push(`${label} [${part.id}]: ${part.text}${part.total_chars > part.text.length ? `… (${part.total_chars} chars)` : ""}`);
    }
    return out.join("\n");
  }
  out.push([result.session_name && `session "${result.session_name}"`, result.active_turn ? "turn active" : "idle",
    `${result.messages.length} entries`, result.next_before && `older: before=${result.next_before}`,
    result.next_after && `newer: after=${result.next_after}`, "times UTC"].filter(Boolean).join(" · "));
  let day;
  for (const message of result.messages) {
    const iso = typeof message.timestamp === "string" ? message.timestamp : "";
    const time = iso.slice(0, 10) !== day ? iso.slice(0, 19).replace("T", " ") : iso.slice(11, 19);
    day = iso.slice(0, 10);
    let body = (message.offset > 0 ? "…" : "") + message.text;
    if (message.capped) body += `\n… tool input cut: entry_id=${message.id}`;
    else if (message.truncated) body += `\n… ${message.total_chars - message.offset - message.text.length} more chars: entry_id=${message.id} offset=${message.next_offset}`;
    out.push(`\n[${message.id} ${time} ${roleLabel(message)}]\n${body}`);
  }
  if (result.partial_message) out.push(`\n[streaming assistant]\n${result.partial_message.text}`);
  return out.join("\n");
}

function readTranscript(ctx, options = {}, partial) {
  const limit = options.limit ?? 10, budget = options.max_chars ?? 12000, toolChars = options.tool_chars ?? 400;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100 || !Number.isInteger(budget) || budget < 256 || budget > 32000
      || !Number.isInteger(toolChars) || toolChars < 0 || toolChars > 32000) throw new Error("Invalid transcript limits");
  if ([options.before, options.after, options.from_start, options.entry_id].filter(Boolean).length > 1) {
    throw new Error("Use one of before, after, from_start or entry_id");
  }
  if (options.offset !== undefined && !options.entry_id) throw new Error("An offset needs entry_id");
  let query;
  if (options.query !== undefined) {
    try { query = new RegExp(String(options.query).slice(0, 512), "i"); } catch { throw new Error("Invalid query regular expression"); }
  }
  const branch = ctx.sessionManager.getBranch();
  const base = {active_turn: !ctx.isIdle(), leaf_id: ctx.sessionManager.getLeafId?.(),
    session_name: ctx.sessionManager.getSessionName?.()};
  const finish = result => options.format === "json" ? result : {text: renderText(result)};
  if (options.overview) {
    return finish({...base, session_file: ctx.sessionManager.getSessionFile?.(), overview: overview(branch)});
  }
  const locate = id => {
    const index = branch.findIndex(entry => entry.id === id);
    if (index < 0) throw new Error("Entry is not on the current branch");
    return index;
  };
  const page = !options.entry_id, cap = page ? toolChars : undefined;
  const eligible = index => {
    const entry = conversationEntry(branch[index], options, cap);
    return entry && (!query || query.test(entry.text)) ? entry : undefined;
  };
  const messages = [];
  let nextBefore, nextAfter;
  if (options.entry_id) {
    const entry = conversationEntry(branch[locate(options.entry_id)], options);
    if (!entry) throw new Error("Entry has no text with these filters");
    messages.push(entry);
  } else if (options.after || options.from_start) {
    for (let index = options.after ? locate(options.after) + 1 : 0; index < branch.length; index++) {
      const entry = eligible(index);
      if (!entry) continue;
      if (messages.length === limit) { nextAfter = messages.at(-1).id; break; }
      messages.push(entry);
    }
  } else {
    const end = options.before ? locate(options.before) : branch.length;
    for (let index = end - 1; index >= 0; index--) {
      const entry = eligible(index);
      if (!entry) continue;
      if (messages.length === limit) { nextBefore = messages[0].id; break; }
      messages.unshift(entry);
    }
  }
  let remaining = budget;
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    let share = Math.floor(remaining / (messages.length - index)), start = options.offset ?? 0;
    if (page && message.role === "toolResult") share = Math.min(share, toolChars);
    if (page && query && !message.capped && message.text.length > share) {
      // Show the text near the first match, not only the start of a long tool result.
      start = Math.max(0, message.text.search(query) - 80);
      if (start > 0 && /[\uDC00-\uDFFF]/.test(message.text[start])) start--;
    }
    const chunk = textChunk(message.text, start, share);
    remaining -= chunk.text.length;
    Object.assign(message, chunk);
    if (message.capped) { message.truncated = true; delete message.next_offset; }
  }
  const result = {...base, messages, next_before: nextBefore, next_after: nextAfter,
    truncated: messages.some(message => message.truncated)};
  if (options.include_partial && partial) {
    const text = contentText(partial.content, {include_thinking: options.include_thinking});
    if (text) result.partial_message = {role: "assistant", partial: true, ...textChunk(text, 0, 1000)};
  }
  return finish(result);
}

module.exports = function inspection(pi) {
  let phase = "idle", since = Date.now(), prompt, partial, compacting = false;
  const tools = new Map();
  const setPhase = value => {
    if (phase !== value) { phase = value; since = Date.now(); }
  };
  const resume = ctx => setPhase(tools.size ? "running_tools" : compacting ? "compacting" : ctx.isIdle() ? "idle" : "waiting_model");
  pi.on("session_start", () => { tools.clear(); prompt = partial = undefined; compacting = false; setPhase("idle"); });
  pi.on("agent_start", () => setPhase("waiting_model"));
  pi.on("turn_start", () => { partial = undefined; if (!prompt) setPhase(tools.size ? "running_tools" : "waiting_model"); });
  pi.on("message_update", event => {
    partial = event.message;
    if (tools.size || prompt) return;
    const type = event.assistantMessageEvent?.type;
    if (type?.startsWith("thinking_")) setPhase("thinking");
    else if (type?.startsWith("text_")) setPhase("writing");
    else if (type?.startsWith("toolcall_")) setPhase("preparing_tool");
  });
  pi.on("message_end", event => { if (event.message.role === "assistant") partial = undefined; });
  pi.on("tool_execution_start", event => {
    const args = event.args || {};
    const detail = ["command", "path", "file_path", "pattern", "query", "url", "title"]
      .map(key => args[key]).find(value => typeof value === "string" && value.trim()) || "";
    tools.set(event.toolCallId, {id: event.toolCallId, name: event.toolName,
      parent_id: event.parentToolCallId, detail: detail.slice(0, 500), detail_truncated: detail.length > 500,
      started_at: Date.now()});
    if (!prompt) setPhase("running_tools");
  });
  pi.on("tool_execution_end", (event, ctx) => { tools.delete(event.toolCallId); if (!prompt) resume(ctx); });
  pi.on("ui_prompt_start", event => {
    prompt = {kind: event.kind, title: event.title?.slice(0, 500)};
    setPhase("waiting_user");
  });
  pi.on("ui_prompt_end", (_, ctx) => { prompt = undefined; resume(ctx); });
  pi.on("session_before_compact", () => { compacting = true; if (!prompt) setPhase("compacting"); });
  pi.on("session_compact", (_, ctx) => { compacting = false; if (!prompt) resume(ctx); });
  pi.on("session_compact_failed", (_, ctx) => { compacting = false; if (!prompt) resume(ctx); });
  pi.on("agent_settled", () => { tools.clear(); partial = undefined; if (!prompt) setPhase("idle"); });
  pi.on("session_shutdown", () => { tools.clear(); prompt = partial = undefined; compacting = false; setPhase("idle"); });
  return {
    activity(ctx) {
      if (!prompt && phase !== "compacting" && !tools.size) {
        if (ctx.isIdle()) setPhase("idle");
        else if (phase === "idle") setPhase("waiting_model");
      }
      return {phase, since, tool_count: tools.size, tools: [...tools.values()].slice(0, 32),
        tools_truncated: tools.size > 32, prompt};
    },
    transcript: (ctx, options) => readTranscript(ctx, options, partial),
  };
};
