-- Temporary command prompt scoped to the active Pane.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Editor = require "core.editor"
local file_context = require "core.file_context"
local panes = require "core.panes"

local M = core.pane_command_bar or {}
core.pane_command_bar = M

local function arguments(text)
  local result, current = {}, {}
  local quote, escaped
  local function push()
    if #current > 0 then
      result[#result + 1] = table.concat(current)
      current = {}
    end
  end
  for index = 1, #text do
    local char = text:sub(index, index)
    if escaped then
      current[#current + 1] = char
      escaped = false
    elseif char == "\\" and quote then
      escaped = true
    elseif quote then
      if char == quote then quote = nil else current[#current + 1] = char end
    elseif char == "\"" or char == "'" then
      quote = char
    elseif char:match("%s") then
      push()
    else
      current[#current + 1] = char
    end
  end
  if escaped then current[#current + 1] = "\\" end
  if quote then return nil, "unterminated quote" end
  push()
  return result
end

local function fail(message)
  core.error("Pane Command Bar: %s", message)
  return false
end

local function edit(pane, source_view, args)
  if #args == 0 then
    return panes.place(function() return Editor(core.open_buffer()) end, {
      pane = pane,
      placement = "current",
      focus = true,
      reason = "pane-command-edit",
    }) ~= nil
  end
  if #args ~= 1 then return fail(":edit accepts one file path") end
  local path = file_context.resolve_path(args[1], source_view)
  local info = path and system.get_file_info(path)
  if info and info.type == "dir" then return fail(":edit target is a directory") end
  return core.open_file(path, {
    pane = pane,
    placement = "current",
    focus = true,
    reason = "pane-command-edit",
  }) ~= nil
end

local function tree(pane, source_view, args)
  if #args > 1 then return fail(":tree accepts one target") end
  local view, err = require("plugins.filetree").open(args[1], {
    pane = pane,
    placement = "current",
    focus = true,
    source_view = source_view,
    reason = "pane-command-tree",
  })
  if not view then return fail(err or "could not open File Tree") end
  return true
end

local function terminal(pane, source_view, args)
  if #args > 0 then return fail(":terminal does not accept arguments") end
  return require("plugins.terminal").open {
    pane = pane,
    placement = "current",
    focus = true,
    cwd = file_context.source_directory(source_view),
    reason = "pane-command-terminal",
  } ~= nil
end

local internal = {
  edit = edit,
  tree = tree,
  terminal = terminal,
}

function M.execute(text, context)
  context = context or {}
  text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
  if text == "" then return false end
  local pane = panes.find(context.pane or M.source_pane or panes.active())
  if not pane then return fail("no active Pane") end
  local source_view = context.source_view or M.source_view or pane.current_view

  if text:sub(1, 1) == ":" then
    local parts, err = arguments(text:sub(2))
    if not parts then return fail(err) end
    local name = table.remove(parts, 1)
    local handler = name and internal[name]
    if not handler then return fail("unknown internal command: :" .. tostring(name or "")) end
    return handler(pane, source_view, parts)
  end

  return require("plugins.command_slots").run_once(text, {
    cwd = file_context.source_directory(source_view) or system.getcwd(),
    focus = true,
  }) ~= nil
end

function M.open(target)
  local pane = panes.find(target or panes.active())
  if not pane then return false end
  M.source_pane = pane
  M.source_view = pane.current_view
  core.global_prompt_bar:enter("Pane", {
    pane_scope = pane,
    pane_source_view = M.source_view,
    show_suggestions = false,
    typeahead = false,
    submit = function(text)
      local source_pane, source_view = M.source_pane, M.source_view
      M.source_pane, M.source_view = nil, nil
      M.execute(text, { pane = source_pane, source_view = source_view })
    end,
    cancel = function()
      M.source_pane, M.source_view = nil, nil
    end,
  })
  return true
end

command.add(nil, {
  ["view:open-command-bar"] = function() return M.open() end,
})

return M
