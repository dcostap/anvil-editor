-- On-demand report glue. Native counters own the byte accounting.
local M = {}

function M.snapshot()
  local snapshot = system.memory_stats()
  snapshot.pid = system.get_process_id()
  snapshot.time = os.date("!%Y-%m-%dT%H:%M:%SZ")
  snapshot.terminals = PLATFORM == "Windows" and require("terminal_native").memory_stats() or {}
  table.sort(snapshot.terminals, function(a, b) return a.memory_id < b.memory_id end)
  return snapshot
end

function M.capture(collect)
  if collect then return require("core.heap_census").run(M.snapshot) end
  return { memory_before = M.snapshot() }
end

local function bytes(value)
  return value and string.format("%.0f", value) or "n/a"
end

local function row(name, before, after)
  local change = before and after and after - before
  return string.format("%-32s %14s %14s %14s", name, bytes(before), bytes(after), bytes(change))
end

local function terminals(lines, label, snapshot)
  local prepared, remote = 0, 0
  for _, item in ipairs(snapshot.terminals) do
    if item.prepared then prepared = prepared + 1 end
    if item.remote then remote = remote + 1 end
  end
  lines[#lines + 1] = string.format("\nTerminals %s: %d sessions, %d prepared, %d remote", label, #snapshot.terminals, prepared, remote)
  lines[#lines + 1] = "Queues: used/capacity/high-water bytes. Model: allocator-usable bytes, including alignment padding."
  for _, item in ipairs(snapshot.terminals) do
    lines[#lines + 1] = string.format(
      "  #%d session=%s host=%d %s%s%s model=%d peak=%d objects=%d read=%d/%d/%d write=%d/%d/%d replay=%d snapshot_text=%d",
      item.memory_id, item.session_id ~= "" and item.session_id or "pending", item.host_pid, item.state,
      item.prepared and " prepared" or "", item.remote and " remote" or "",
      item.model_bytes, item.model_peak_bytes, item.model_objects,
      item.read_queue_bytes, item.read_queue_capacity, item.read_queue_high_water,
      item.write_queue_bytes, item.write_queue_capacity, item.write_queue_high_water,
      item.replay_capacity, item.snapshot_text_capacity)
  end
end

function M.format(report)
  local before, after = report.memory_before, report.memory_after_collection
  local current = after or before
  local lines = {
    "Anvil memory report",
    string.format("PID %d | %s%s", before.pid, before.time, after and (" -> " .. after.time) or ""),
    after and string.format("Explicit collection: %.2f ms. No worker-state collection.", report.collection_ms)
      or "Collection: not requested.",
    "All counters below use bytes. Samples are not an atomic process snapshot; background work continues.",
    "Changes include report overhead. A decrease does not prove a leak or future recoverable savings.",
    "",
    string.format("%-32s %14s %14s %14s", "Metric", "before", "after GC", "change"),
    row("lua_heap_bytes", before.lua_bytes, after and after.lua_bytes),
  }
  for _, key in ipairs { "private_commit_bytes", "private_working_set_bytes", "working_set_bytes" } do
    lines[#lines + 1] = row(key, before.process[key], after and after.process[key])
  end
  local names = {}
  for name in pairs(before.categories) do names[#names + 1] = name end
  table.sort(names)
  for _, graphics in ipairs { false, true } do
    lines[#lines + 1] = graphics and "\nGraphics payload (not CPU commit or GPU residency):" or "\nNative allocations:"
    for _, name in ipairs(names) do
      local first, last = before.categories[name], current.categories[name]
      if (first.basis == "texture_payload") == graphics then
        lines[#lines + 1] = row(name, first.bytes, after and last.bytes)
          .. string.format("  basis=%s peak=%d objects=%d", last.basis, last.peak_bytes, last.objects)
      end
    end
  end
  terminals(lines, after and "before collection" or "at sample", before)
  if after then terminals(lines, "after collection", after) end
  lines[#lines + 1] = "\nLua state samples (not additional bytes to add to this state's heap):"
  for _, state in ipairs(current.lua_states) do
    lines[#lines + 1] = string.format("  #%d %s bytes=%d age_ms=%d", state.id, state.name, state.bytes, state.age_ms)
  end
  lines[#lines + 1] = string.format("  Omitted states: %d", current.lua_states_omitted)
  lines[#lines + 1] = "\nLimits: counters omit uninstrumented native allocations and allocator-retained free pages."
  lines[#lines + 1] = "Terminal rows cover this Lua state's native sessions, including prepared sessions without Views."
  lines[#lines + 1] = "Host processes and remote Machines have separate memory. Temporary SDL image decode storage is not counted here."
  lines[#lines + 1] = "Graphics payload excludes driver storage and swapchains. Do not add it to CPU allocation counters."
  if after then
    lines[#lines + 1] = "Lua owners are reachability estimates, not allocation stacks. Userdata and prototype payload sizes are omitted."
    lines[#lines + 1] = "The census runs after both snapshots. Its temporary tables do not enter the reported collection change.\n"
    lines[#lines + 1] = require("core.heap_census").format(report)
  end
  return table.concat(lines, "\n") .. "\n"
end

return M
