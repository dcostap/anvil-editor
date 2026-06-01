-- mod-version:3 priority:250
-- Project-scoped PowerShell command slots with read-only side-panel output.
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local json = require "core.json"
local process = require "core.process"
local storage = require "core.storage"
local Doc = require "core.doc"
local DocView = require "core.docview"
local sidepanel = require "core.sidepanel"

local M = core.command_slots or {}
core.command_slots = M

local SLOT_DEFS = {
  { index = 1, key = "a", label = "A" },
  { index = 2, key = "s", label = "S" },
  { index = 3, key = "d", label = "D" },
  { index = 4, key = "f", label = "F" },
}

local STORAGE_MODULE = "command-slots"
local DONE_PREFIX = "__ANVIL_COMMAND_SLOT_DONE__"
local MARKER_TAIL_BYTES = 512
local DEFAULT_MAX_OUTPUT_BYTES = 10 * 1024 * 1024
local READ_CHUNK_BYTES = 8192

config.plugins.command_slots = common.merge({
  max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
  max_history = 100,
  prewarm = true,
  strip_ansi = true,
  powershell_candidates = { "pwsh.exe", "powershell.exe" },
}, config.plugins.command_slots or {})

M.slots = M.slots or {}
M.project_state_cache = M.project_state_cache or {}
M.token_counter = M.token_counter or 0

local function running_lua_tests()
  for _, arg in ipairs(ARGS or {}) do
    if arg == "test" then return true end
  end
  return false
end

local function root_project_path()
  local project = core.root_project and core.root_project()
  return project and project.path or system.getcwd()
end

local function slot_for_index(index)
  return M.slots[index]
end

local function is_blank(text)
  return not text or text:match("^%s*$") ~= nil
end

local function normalize_history(history)
  local result, seen = {}, {}
  if type(history) == "table" then
    for _, value in ipairs(history) do
      if type(value) == "string" and not is_blank(value) and not seen[value] then
        seen[value] = true
        result[#result + 1] = value
      end
    end
  end
  return result
end

local function project_state(project_path)
  project_path = project_path or root_project_path()
  local state = M.project_state_cache[project_path]
  if not state then
    local loaded = storage.load(STORAGE_MODULE, project_path)
    state = { commands = {}, history = {} }
    if type(loaded) == "table" then
      local loaded_commands = type(loaded.commands) == "table" and loaded.commands or loaded
      for i = 1, #SLOT_DEFS do
        local value = loaded_commands[i]
        state.commands[i] = type(value) == "string" and value or ""
      end
      state.history = normalize_history(loaded.history)
    end
    M.project_state_cache[project_path] = state
  end
  return state, project_path
end

local function project_commands(project_path)
  local state, key = project_state(project_path)
  return state.commands, key, state
end

local function save_project_state(project_path, state)
  storage.save(STORAGE_MODULE, project_path, {
    commands = state.commands,
    history = state.history,
  })
end

function M.get_command(index, project_path)
  local commands = project_commands(project_path)
  return commands[index] or ""
end

function M.set_command(index, text, project_path)
  local commands, key, state = project_commands(project_path)
  commands[index] = text or ""
  save_project_state(key, state)
  core.log_quiet("Command Slot %d: stored command for project %s", index, tostring(key))
end

function M.record_history(command_text, project_path)
  if is_blank(command_text) then return end
  local state, key = project_state(project_path)
  local history = normalize_history(state.history)
  for i = #history, 1, -1 do
    if history[i] == command_text then table.remove(history, i) end
  end
  table.insert(history, 1, command_text)
  local max_history = math.max(1, tonumber(config.plugins.command_slots.max_history) or 100)
  while #history > max_history do table.remove(history) end
  state.history = history
  save_project_state(key, state)
end

local function suggestion_matches(text, candidate)
  if is_blank(text) then return true end
  text = text:lower()
  return tostring(candidate or ""):lower():find(text, 1, true) ~= nil
end

function M.suggest_commands(text, project_path)
  local state = project_state(project_path)
  local result, seen = {}, {}
  local function add(value)
    if type(value) ~= "string" or is_blank(value) or seen[value] or not suggestion_matches(text, value) then return end
    seen[value] = true
    result[#result + 1] = { text = value }
  end
  for _, value in ipairs(state.history or {}) do add(value) end
  for i = 1, #SLOT_DEFS do add(state.commands[i]) end
  return result
end

function M._build_powershell_controller()
  return table.concat({
    "$global:LASTEXITCODE = $null",
    "$__anvil_token = 'unknown'",
    "$__anvil_exit = 1",
    "try {",
    "  [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)",
    "  [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)",
    "  $OutputEncoding = [Console]::OutputEncoding",
    "  if (Get-Variable -Name PSStyle -Scope Global -ErrorAction SilentlyContinue) { $PSStyle.OutputRendering = 'PlainText' }",
    "  $env:NO_COLOR = '1'",
    "  $env:CLICOLOR = '0'",
    "  $env:TERM = 'dumb'",
    "  $__anvil_payload_text = [Console]::In.ReadToEnd()",
    "  $__anvil_payload = $__anvil_payload_text | ConvertFrom-Json",
    "  $__anvil_token = [string]$__anvil_payload.token",
    "  Set-Location -LiteralPath ([string]$__anvil_payload.cwd)",
    "  $__anvil_script = [scriptblock]::Create([string]$__anvil_payload.command)",
    "  & $__anvil_script",
    "  $__anvil_success = $?",
    "  $__anvil_native_exit = $global:LASTEXITCODE",
    "  if ($null -ne $__anvil_native_exit) { $__anvil_exit = [int]$__anvil_native_exit } elseif ($__anvil_success) { $__anvil_exit = 0 } else { $__anvil_exit = 1 }",
    "} catch {",
    "  Write-Error $_",
    "  $__anvil_exit = 1",
    "}",
    "[Console]::Out.WriteLine('" .. DONE_PREFIX .. "' + $__anvil_token + ':' + $__anvil_exit)",
    "exit $__anvil_exit",
  }, "\n")
end

function M._build_powershell_payload(command_text, cwd, token)
  return json.encode({
    command = command_text or "",
    cwd = cwd or root_project_path(),
    token = tostring(token or "unknown"),
  })
end

local CommandOutputDoc = Doc:extend()

function CommandOutputDoc:__tostring() return "CommandOutputDoc" end

function CommandOutputDoc:new()
  CommandOutputDoc.super.new(self)
  self.output_text = ""
  self:clean()
end

function CommandOutputDoc:is_dirty()
  return false
end

function CommandOutputDoc:save()
  return true
end

function CommandOutputDoc:reload()
end

function CommandOutputDoc:_with_internal_mutation(fn)
  self.__command_output_mutating = true
  local ok, a, b, c = pcall(fn)
  self.__command_output_mutating = false
  if not ok then error(a, 2) end
  return a, b, c
end

function CommandOutputDoc:insert(line, col, text)
  if not self.__command_output_mutating then return end
  return CommandOutputDoc.super.insert(self, line, col, text)
end

function CommandOutputDoc:remove(line1, col1, line2, col2)
  if not self.__command_output_mutating then return end
  return CommandOutputDoc.super.remove(self, line1, col1, line2, col2)
end

function CommandOutputDoc:text_input()
end

function CommandOutputDoc:ime_text_editing()
end

function CommandOutputDoc:undo()
end

function CommandOutputDoc:redo()
end

function CommandOutputDoc:delete_to_cursor()
end

function CommandOutputDoc:delete_to()
end

function CommandOutputDoc:replace()
end

function CommandOutputDoc:indent_text()
end

function CommandOutputDoc:_display_text()
  local text = self.output_text or ""
  if text == "" or text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  return text
end

function CommandOutputDoc:_replace_display_text()
  self:reset()
  CommandOutputDoc.super.insert(self, 1, 1, self:_display_text())
  self:set_selection(#self.lines, 1)
  self:clear_undo_redo()
  self:clean()
end

function CommandOutputDoc:set_text(text)
  self.output_text = tostring(text or "")
  self:_with_internal_mutation(function()
    self:_replace_display_text()
  end)
end

function CommandOutputDoc:append(text)
  if not text or text == "" then return end
  self.output_text = (self.output_text or "") .. text
  self:_with_internal_mutation(function()
    self:_replace_display_text()
  end)
end

local CommandOutputView = DocView:extend()

function CommandOutputView:__tostring() return "CommandOutputView" end

function CommandOutputView:new(slot)
  CommandOutputView.super.new(self, CommandOutputDoc())
  self.slot = slot
  self.command_output_view = true
end

function CommandOutputView:get_name()
  local label = self.slot and self.slot.label or "?"
  return "Command " .. label .. " Output"
end

function CommandOutputView:get_filename()
  return nil
end

function CommandOutputView:supports_text_input()
  return false
end

function CommandOutputView:on_text_input()
end

function CommandOutputView:try_close(do_close)
  if self.slot and self.slot.running then
    M.kill_slot(self.slot.index, "closed")
  end
  do_close()
end

function CommandOutputView:clear_for_run(command_text, cwd)
  local header = string.format("PS %s> %s\n\n", tostring(cwd or ""), tostring(command_text or ""))
  self.doc:set_text(header)
  self:scroll_to_make_visible(#self.doc.lines, math.huge, true)
end

function CommandOutputView:append_text(text)
  self.doc:append(text)
  self:scroll_to_make_visible(#self.doc.lines, math.huge, true)
  core.redraw = true
end

M.CommandOutputDoc = CommandOutputDoc
M.CommandOutputView = CommandOutputView

local function ensure_output_view(slot, focus)
  if slot.view and sidepanel.contains_view(slot.view) then
    sidepanel.attach_view("command-slot-" .. slot.index, slot.view)
    sidepanel.add_view(slot.view)
  else
    slot.view = CommandOutputView(slot)
    sidepanel.register_panel("command-slot-" .. slot.index, slot.view)
  end
  sidepanel.show(slot.view, { focus = focus == true })
  return slot.view
end

local function strip_ansi(text)
  text = tostring(text or "")
  -- PowerShell 7 emits ANSI SGR color by default when stdout is a pipe, and
  -- many native tools do the same. Command Output Views are plain text, not a
  -- terminal emulator, so remove common ANSI control sequences before display.
  text = text:gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%][^\7]*\7", "")
  text = text:gsub("\27%][^\27]*\27\\", "")
  text = text:gsub("\27%([A-Za-z0-9]", "")
  return text
end

M._strip_ansi = strip_ansi

local function append_to_output(slot, text, force)
  if not text or text == "" then return end
  if config.plugins.command_slots.strip_ansi ~= false then
    text = strip_ansi(text)
    if text == "" then return end
  end
  local view = slot.view
  if not view then return end

  if force then
    view:append_text(text)
    return
  end

  local max_bytes = tonumber(config.plugins.command_slots.max_output_bytes) or DEFAULT_MAX_OUTPUT_BYTES
  if slot.truncated or slot.output_bytes >= max_bytes then
    slot.truncated = true
    return
  end

  local allowed = max_bytes - slot.output_bytes
  if #text > allowed then
    if allowed > 0 then
      view:append_text(text:sub(1, allowed))
      slot.output_bytes = slot.output_bytes + allowed
    end
    slot.truncated = true
    append_to_output(
      slot,
      string.format("\n--- output truncated after %.1f MB; command is still being drained ---\n", max_bytes / (1024 * 1024)),
      true
    )
  else
    view:append_text(text)
    slot.output_bytes = slot.output_bytes + #text
  end
end

local function flush_pending(slot)
  if slot.pending_output and slot.pending_output ~= "" then
    append_to_output(slot, slot.pending_output)
    slot.pending_output = ""
  end
end

local function finish_run(slot, kind, exit_code, detail)
  if not slot.running then return end
  flush_pending(slot)

  local elapsed = math.max(0, system.get_time() - (slot.start_time or system.get_time()))
  local footer
  if kind == "exited" then
    footer = string.format("\n--- exited with code %s in %.1fs ---\n", tostring(exit_code), elapsed)
  elseif kind == "killed" then
    footer = string.format("\n--- killed after %.1fs ---\n", elapsed)
  elseif kind == "start-error" then
    footer = string.format("\n--- could not start PowerShell: %s ---\n", tostring(detail or "unknown error"))
  elseif kind == "write-error" then
    footer = string.format("\n--- could not send command to PowerShell: %s ---\n", tostring(detail or "unknown error"))
  else
    footer = string.format("\n--- PowerShell worker exited before the command completed%s in %.1fs ---\n", exit_code and (" with code " .. tostring(exit_code)) or "", elapsed)
  end

  append_to_output(slot, footer, true)
  core.log_quiet(
    "Command Slot %d: run finished kind=%s exit=%s detail=%s elapsed=%.1fs",
    slot.index,
    tostring(kind),
    tostring(exit_code),
    tostring(detail),
    elapsed
  )

  slot.running = false
  slot.token = nil
  slot.start_time = nil
  slot.pending_output = ""
end

function M._process_worker_output(slot, chunk)
  if not chunk or chunk == "" then return false end
  if not slot.running or not slot.token then
    core.log_quiet("Command Slot %d: dropping idle PowerShell output (%d bytes)", slot.index, #chunk)
    return false
  end

  local pending = (slot.pending_output or "") .. chunk
  local marker = DONE_PREFIX .. tostring(slot.token) .. ":"
  local marker_start, marker_end = pending:find(marker, 1, true)
  if marker_start then
    local after_marker = pending:sub(marker_end + 1)
    local exit_text = after_marker:match("^(-?%d+)")
    if not exit_text then
      if marker_start > 1 then
        append_to_output(slot, pending:sub(1, marker_start - 1))
      end
      slot.pending_output = pending:sub(marker_start)
      return false
    end

    append_to_output(slot, pending:sub(1, marker_start - 1))
    slot.pending_output = ""
    finish_run(slot, "exited", tonumber(exit_text) or 0)
    return true
  end

  if #pending > MARKER_TAIL_BYTES then
    local flush_len = #pending - MARKER_TAIL_BYTES
    append_to_output(slot, pending:sub(1, flush_len))
    pending = pending:sub(flush_len + 1)
  end
  slot.pending_output = pending
  return false
end

local function powershell_args(exe)
  return { exe, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", M._build_powershell_controller() }
end

local function start_worker(slot)
  local cwd = root_project_path()
  local errors = {}
  for _, exe in ipairs(config.plugins.command_slots.powershell_candidates or {}) do
    local proc, err = process.start(powershell_args(exe), {
      cwd = cwd,
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_STDOUT,
      env = {
        NO_COLOR = "1",
        CLICOLOR = "0",
        TERM = "dumb",
      },
    })
    if proc then
      slot.proc = proc
      slot.worker_consumed = false
      slot.worker_exe = exe
      slot.worker_generation = (slot.worker_generation or 0) + 1
      local generation = slot.worker_generation
      core.log_quiet("Command Slot %d: started disposable PowerShell worker %s", slot.index, exe)

      core.add_thread(function()
        while slot.proc == proc and slot.worker_generation == generation do
          local chunk, read_err = proc:read_stdout(READ_CHUNK_BYTES)
          if chunk and #chunk > 0 then
            M._process_worker_output(slot, chunk)
          elseif chunk == "" then
            coroutine.yield(1 / config.fps)
          else
            if read_err then
              core.log_quiet("Command Slot %d: PowerShell read ended: %s", slot.index, tostring(read_err))
            end
            break
          end
        end

        if slot.proc == proc and slot.worker_generation == generation then
          local exit_code = proc:returncode()
          slot.proc = nil
          slot.worker_consumed = false
          core.log_quiet("Command Slot %d: PowerShell worker exited code=%s", slot.index, tostring(exit_code))
          if slot.running then
            finish_run(slot, "worker-exited", exit_code)
          elseif config.plugins.command_slots.prewarm ~= false then
            start_worker(slot)
          end
        end
      end)

      return proc
    end
    errors[#errors + 1] = string.format("%s: %s", tostring(exe), tostring(err or "start failed"))
    core.log_quiet("Command Slot %d: failed to start %s: %s", slot.index, tostring(exe), tostring(err))
  end
  return nil, table.concat(errors, "; ")
end

local function kill_worker(slot)
  local proc = slot.proc
  slot.proc = nil
  slot.worker_consumed = false
  slot.worker_generation = (slot.worker_generation or 0) + 1
  if proc then
    pcall(proc.kill, proc)
  end
end

local function ensure_worker(slot)
  if slot.proc and slot.proc:running() and not slot.worker_consumed then return slot.proc end
  if slot.proc and slot.proc:running() and slot.worker_consumed then kill_worker(slot) end
  slot.proc = nil
  slot.worker_consumed = false
  return start_worker(slot)
end

function M.kill_slot(index, reason)
  local slot = slot_for_index(index)
  if not slot then return false end
  local was_running = slot.running
  if was_running then
    finish_run(slot, "killed")
  end
  slot.run_generation = (slot.run_generation or 0) + 1
  kill_worker(slot)
  core.log_quiet("Command Slot %d: killed worker reason=%s", index, tostring(reason or "manual"))
  return was_running
end

local function next_token(slot)
  M.token_counter = M.token_counter + 1
  return string.format("%d_%d_%d", slot.index, math.floor(system.get_time() * 1000000), M.token_counter)
end

local function default_run_command(slot, command_text)
  if slot.running then
    M.kill_slot(slot.index, "rerun")
  end

  local cwd = root_project_path()
  local view = ensure_output_view(slot, true)
  view:clear_for_run(command_text, cwd)

  slot.running = true
  slot.token = next_token(slot)
  slot.run_generation = (slot.run_generation or 0) + 1
  local run_generation = slot.run_generation
  local run_token = slot.token
  slot.start_time = system.get_time()
  slot.pending_output = ""
  slot.output_bytes = 0
  slot.truncated = false
  slot.last_command_text = command_text
  slot.last_cwd = cwd

  M.record_history(command_text, cwd)
  core.log_quiet("Command Slot %d: running command in %s: %s", slot.index, cwd, command_text)

  core.add_thread(function()
    local function current_run()
      return slot.running and slot.run_generation == run_generation and slot.token == run_token
    end

    if not current_run() then return end
    local proc, start_err = ensure_worker(slot)
    if not proc then
      if current_run() then finish_run(slot, "start-error", nil, start_err) end
      return
    end

    if not current_run() then return end
    local payload = M._build_powershell_payload(command_text, cwd, run_token)
    local written, write_err = proc.stdin:write(payload)
    if written and written >= #payload then
      if current_run() then slot.worker_consumed = true end
      proc.stdin:close()
      return
    end

    if not current_run() then return end
    core.log_quiet("Command Slot %d: PowerShell write failed; restarting worker: %s", slot.index, tostring(write_err))
    kill_worker(slot)
    proc, start_err = ensure_worker(slot)
    if not proc then
      if current_run() then finish_run(slot, "start-error", nil, start_err) end
      return
    end

    if not current_run() then return end
    written, write_err = proc.stdin:write(payload)
    if written and written >= #payload then
      if current_run() then slot.worker_consumed = true end
      proc.stdin:close()
      return
    end

    if current_run() then
      finish_run(slot, "write-error", nil, write_err)
      kill_worker(slot)
    end
  end)

  return view
end

M._default_run_command = default_run_command
M._run_command_impl = M._run_command_impl or default_run_command

function M.run_command(index, command_text)
  local slot = slot_for_index(index)
  if not slot or is_blank(command_text) then return nil end
  return M._run_command_impl(slot, command_text)
end

function M.run_slot(index)
  local text = M.get_command(index)
  if is_blank(text) then
    return M.prompt_slot(index, false)
  end
  return M.run_command(index, text)
end

function M.prompt_slot(index, select_existing)
  local slot = slot_for_index(index)
  if not slot then return end
  local text = M.get_command(index)
  core.global_prompt_bar:enter("Command Slot " .. slot.label, {
    text = text,
    select_text = select_existing == true and not is_blank(text),
    suggest = function(input)
      return M.suggest_commands(input)
    end,
    show_suggestions = true,
    typeahead = false,
    submit = function(input)
      if is_blank(input) then
        core.log_quiet("Command Slot %d: blank prompt submit ignored", index)
        return
      end
      M.set_command(index, input)
      M.run_command(index, input)
    end,
  })
end

local function install_commands()
  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    local index = def.index
    map["command-slots:run-" .. def.key] = function()
      return M.run_slot(index)
    end
    map["command-slots:edit-" .. def.key] = function()
      return M.prompt_slot(index, true)
    end
  end
  map["command-slots:kill-active"] = function()
    local view = core.active_view
    if view and view.command_output_view and view.slot then
      return M.kill_slot(view.slot.index, "command")
    end
    return false
  end
  command.add(nil, map)
end

local function install_keymaps()
  local map = {}
  for _, def in ipairs(SLOT_DEFS) do
    map["alt+" .. def.key] = "command-slots:run-" .. def.key
    map["alt+shift+" .. def.key] = "command-slots:edit-" .. def.key
  end
  keymap.add_direct(map)
end

local function output_view_active()
  return core.active_view and core.active_view.command_output_view == true
end

local function wrap_command_to_block_output_view(name)
  local base = command.map[name]
  if not base or base.__command_slots_blocks_output_view then return end
  command.add(function(...)
    if output_view_active() then return false end
    return base.predicate(...)
  end, {
    [name] = function(...)
      return base.perform(...)
    end,
  })
  command.map[name].__command_slots_blocks_output_view = true
end

local function install_readonly_command_guards()
  local blocked = {
    "doc:cut",
    "doc:undo",
    "doc:redo",
    "doc:paste",
    "doc:paste-primary-selection",
    "doc:newline",
    "doc:newline-below",
    "doc:newline-above",
    "doc:delete",
    "doc:backspace",
    "doc:join-lines",
    "doc:indent",
    "doc:unindent",
    "doc:duplicate-lines",
    "doc:delete-lines",
    "doc:move-lines-up",
    "doc:move-lines-down",
    "doc:toggle-block-comments",
    "doc:toggle-line-comments",
    "doc:upper-case",
    "doc:lower-case",
    "doc:toggle-line-ending",
    "doc:change-encoding",
    "doc:reload-with-encoding",
    "doc:toggle-overwrite",
    "doc:save-as",
    "doc:save",
    "doc:reload",
    "file:rename",
    "file:delete",
  }
  local translations = {
    "previous-char",
    "next-char",
    "previous-word-start",
    "next-word-end",
    "previous-block-start",
    "next-block-end",
    "start-of-doc",
    "end-of-doc",
    "start-of-line",
    "end-of-line",
    "start-of-word",
    "start-of-indentation",
    "end-of-word",
    "previous-line",
    "next-line",
    "previous-page",
    "next-page",
  }
  for _, name in ipairs(translations) do
    blocked[#blocked + 1] = "doc:delete-to-" .. name
  end
  for _, name in ipairs(blocked) do
    wrap_command_to_block_output_view(name)
  end
end

function M.prewarm()
  if config.plugins.command_slots.prewarm == false then return end
  core.add_thread(function()
    coroutine.yield(0.2)
    for _, def in ipairs(SLOT_DEFS) do
      local slot = slot_for_index(def.index)
      if slot then
        ensure_worker(slot)
        coroutine.yield(0.05)
      end
    end
  end)
end

function M._reset_for_tests()
  for _, slot in ipairs(M.slots) do
    if slot.proc then kill_worker(slot) end
    slot.proc = nil
    slot.worker_consumed = false
    slot.running = false
    slot.run_generation = 0
    slot.token = nil
    slot.pending_output = ""
    slot.view = nil
  end
  M.project_state_cache = {}
  M._run_command_impl = default_run_command
end

for _, def in ipairs(SLOT_DEFS) do
  local slot = M.slots[def.index] or {}
  slot.index = def.index
  slot.key = def.key
  slot.label = def.label
  slot.pending_output = slot.pending_output or ""
  M.slots[def.index] = slot
end

install_commands()
install_keymaps()
install_readonly_command_guards()

if not running_lua_tests() then
  M.prewarm()
end

return M
