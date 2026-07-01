local core = require "core"
local command = require "core.command"
local diagnostic_hints = require "core.lsp.diagnostic_hints"
local diagnostic_underlines = require "core.lsp.diagnostic_underlines"
local diagnostics = require "core.lsp.diagnostics"
local hover = require "core.lsp.hover"
local manager = require "core.lsp.manager"
local signature_help = require "core.lsp.signature_help"
local StatusBar = require "core.statusbar"
local style = require "core.style"

local function install_statusbar_item()
  if not core.status_bar or core.status_bar:get_item("lsp:progress") then return end
  core.status_bar:add_item({
    name = "lsp:progress",
    alignment = StatusBar.Item.RIGHT,
    separator = StatusBar.separator2,
    predicate = function()
      return manager.active_progress_status() ~= nil
    end,
    get_item = function()
      local text = manager.active_progress_status()
      return text and { style.accent, text } or {}
    end,
    command = "lsp:show-status",
    tooltip = "language server work",
  })
end

install_statusbar_item()

local function is_doc_view(value)
  return type(value) == "table" and value.doc ~= nil
end

local function active_or_arg_view(view)
  if is_doc_view(view) then return view end
  if is_doc_view(core.active_view) then return core.active_view end
end

local function doc_view_predicate(view)
  local docview = active_or_arg_view(view)
  return docview ~= nil, docview
end

command.add(nil, {
  ["lsp:enable"] = function()
    manager.enable()
    if core.log then core.log("LSP enabled globally") end
  end,
  ["lsp:disable"] = function()
    manager.disable()
    if core.log then core.log("LSP disabled globally") end
  end,
  ["lsp:toggle"] = function()
    local enabled = not manager.is_enabled()
    manager.set_enabled(enabled)
    if core.log then core.log(enabled and "LSP enabled globally" or "LSP disabled globally") end
  end,
  ["lsp:show-status"] = function()
    if core.log then core.log("%s", manager.status()) end
  end,
})

command.add(doc_view_predicate, {
  ["lsp:start-current-document"] = function(view)
    local ok, err = manager.start_current_document(view)
    if core.log then
      core.log(ok and "LSP start scheduled" or "LSP start skipped: %s", err or "unavailable")
    end
  end,
  ["lsp:restart-current-document"] = function(view)
    local ok, err = manager.restart_current_document(view)
    if core.log then
      core.log(ok and "LSP restart scheduled" or "LSP restart skipped: %s", err or "unavailable")
    end
  end,
  ["lsp:hover-current-position"] = function(view)
    local _hover, reason, status = hover.start_current_position(view)
    if status ~= "fresh" and core.log_quiet then
      core.log_quiet("LSP hover: %s", tostring(reason or status or "pending"))
    end
  end,
  ["lsp:signature-help-current-position"] = function(view)
    local _signature_help, reason, status = signature_help.start_current_position(view)
    if status ~= "fresh" and core.log_quiet then
      core.log_quiet("LSP signature help: %s", tostring(reason or status or "pending"))
    end
  end,
})

return {
  diagnostic_hints = diagnostic_hints,
  diagnostic_underlines = diagnostic_underlines,
  diagnostics = diagnostics,
  hover = hover,
  manager = manager,
  signature_help = signature_help,
}
