local core = require "core"
local command = require "core.command"
local diagnostics = require "core.lsp.diagnostics"
local manager = require "core.lsp.manager"

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
  ["lsp:show-status"] = function()
    if core.log then core.log("%s", manager.status()) end
  end,
})

return {
  diagnostics = diagnostics,
  manager = manager,
}
