// Read-only Pi data. Never send prompts, append entries, or expose system/thinking blocks.
"use strict";

function contentText(content, includeTools) {
  if (typeof content === "string") return content;
  return (Array.isArray(content) ? content : []).map(block => {
    if (block.type === "text") return block.text;
    if (block.type === "image") return "[image]";
    if (includeTools && block.type === "toolCall") {
      return `TOOL CALL ${block.name} [${block.id}]:\n${JSON.stringify(block.arguments)}`;
    }
    return "";
  }).filter(Boolean).join("\n");
}

function conversationEntry(entry, options) {
  const result = {id: entry.id, timestamp: entry.timestamp};
  if (entry.type === "compaction" || entry.type === "branch_summary") {
    if (options.include_summaries === false) return;
    result.role = entry.type === "compaction" ? "compaction_summary" : "branch_summary";
    result.text = entry.summary;
  } else {
    const message = entry.type === "custom_message" ? {role: "custom", ...entry} : entry.message;
    if (entry.type !== "message" && entry.type !== "custom_message" || !message) return;
    if (message.role === "toolResult" && options.include_tools) {
      result.tool_name = message.toolName;
      result.tool_call_id = message.toolCallId;
      result.is_error = message.isError;
    } else if (message.role !== "user" && message.role !== "assistant" && message.role !== "custom") return;
    result.role = message.role;
    result.text = contentText(message.content, options.include_tools);
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

function readTranscript(ctx, options = {}, partial) {
  const limit = options.limit ?? 10, budget = options.max_chars ?? 12000;
  if (!Number.isInteger(limit) || limit < 1 || limit > 100
      || !Number.isInteger(budget) || budget < 256 || budget > 32000) throw new Error("Invalid transcript limits");
  if (options.entry_id && options.before || options.offset !== undefined && !options.entry_id) {
    throw new Error("Use entry_id with offset, or before for older messages");
  }
  const branch = ctx.sessionManager.getBranch();
  const locate = id => {
    const index = branch.findIndex(entry => entry.id === id);
    if (index < 0) throw new Error("Entry is not on the current branch");
    return index;
  };
  const messages = [];
  let nextBefore;
  if (options.entry_id) {
    const entry = conversationEntry(branch[locate(options.entry_id)], options);
    if (!entry) throw new Error("Entry has no text with these filters");
    messages.push(entry);
  } else {
    const end = options.before ? locate(options.before) : branch.length;
    for (let index = end - 1; index >= 0; index--) {
      const entry = conversationEntry(branch[index], options);
      if (!entry) continue;
      if (messages.length === limit) { nextBefore = messages[0].id; break; }
      messages.unshift(entry);
    }
  }
  let remaining = budget;
  for (let index = 0; index < messages.length; index++) {
    const message = messages[index];
    const chunk = textChunk(message.text, options.offset ?? 0, Math.floor(remaining / (messages.length - index)));
    remaining -= chunk.text.length;
    Object.assign(message, chunk);
  }
  const result = {messages, next_before: nextBefore, active_turn: !ctx.isIdle(),
    leaf_id: ctx.sessionManager.getLeafId?.(), session_name: ctx.sessionManager.getSessionName?.(),
    truncated: messages.some(message => message.truncated)};
  if (options.include_partial && partial) {
    const text = contentText(partial.content, false);
    if (text) result.partial_message = {role: "assistant", partial: true, ...textChunk(text, 0, 1000)};
  }
  return result;
}

module.exports = function inspection(pi) {
  let phase = "idle", since = Date.now(), prompt, partial;
  const tools = new Map();
  const setPhase = value => {
    if (phase !== value) { phase = value; since = Date.now(); }
  };
  const resume = ctx => setPhase(tools.size ? "running_tools" : ctx.isIdle() ? "idle" : "waiting_model");
  pi.on("session_start", () => { tools.clear(); prompt = partial = undefined; setPhase("idle"); });
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
  pi.on("session_before_compact", () => { if (!prompt) setPhase("compacting"); });
  pi.on("session_compact", (_, ctx) => { if (!prompt) resume(ctx); });
  pi.on("session_compact_failed", (_, ctx) => { if (!prompt) resume(ctx); });
  pi.on("agent_settled", () => { tools.clear(); partial = undefined; if (!prompt) setPhase("idle"); });
  pi.on("session_shutdown", () => { tools.clear(); prompt = partial = undefined; setPhase("idle"); });
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
