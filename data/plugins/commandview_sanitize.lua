--- mod-version:3
-- Sanitize invisible CR characters in the built-in bottom CommandView input.
-- Windows clipboard/text injection can sometimes provide CRLF; CommandView's
-- single-line doc strips \n but can leave a hidden \r, which makes file paths
-- fail with "filename, directory name, or volume label syntax is incorrect".

local core = require "core"
local common = require "core.common"
local CommandView = require "core.commandview"

-- Pragtical's Windows absolute-path check only recognizes C:\\..., not C:/...
-- Pasted paths commonly use forward slashes, and Open File then prepends the
-- project directory, producing invalid paths like project\\C:/Users/...
if not common.__local_windows_forward_absolute_patched then
  common.__local_windows_forward_absolute_patched = true
  local is_absolute_path = common.is_absolute_path
  function common.is_absolute_path(path)
    return is_absolute_path(path) or tostring(path or ""):match("^(%a):/") ~= nil
  end
end

local function clean(text)
  return tostring(text or ""):gsub("\r", "")
end

local function clean_doc(doc)
  if not doc or not doc.lines then return end
  for i, line in ipairs(doc.lines) do
    if type(line) == "string" and line:find("\r", 1, true) then
      doc.lines[i] = line:gsub("\r", "")
    end
  end
end

local function patch_command_doc(doc)
  if not doc or doc.__local_commandview_cr_patched then return end
  doc.__local_commandview_cr_patched = true

  local insert = doc.insert
  function doc:insert(line, col, text, ...)
    return insert(self, line, col, clean(text), ...)
  end

  local text_input = doc.text_input
  function doc:text_input(text, ...)
    return text_input(self, clean(text), ...)
  end
end

local function sanitize_options(options)
  if type(options) ~= "table" or options.__local_commandview_cr_sanitized then return options end
  options.__local_commandview_cr_sanitized = true

  for _, name in ipairs({ "submit", "suggest", "validate" }) do
    local fn = options[name]
    if type(fn) == "function" then
      options[name] = function(text, ...)
        return fn(clean(text), ...)
      end
    end
  end
  if type(options.text) == "string" then
    options.text = clean(options.text)
  end
  return options
end

if not CommandView.__local_sanitize_cr_patched_v2 then
  CommandView.__local_sanitize_cr_patched_v2 = true

  local new = CommandView.new
  function CommandView:new(...)
    local res = new(self, ...)
    patch_command_doc(self.doc)
    return res
  end

  local enter = CommandView.enter
  function CommandView:enter(label, ...)
    local first = select(1, ...)
    if type(first) == "table" then
      return enter(self, label, sanitize_options(first))
    end
    return enter(self, label, ...)
  end

  local get_text = CommandView.get_text
  function CommandView:get_text(...)
    clean_doc(self.doc)
    return clean(get_text(self, ...))
  end

  local set_text = CommandView.set_text
  function CommandView:set_text(text, ...)
    patch_command_doc(self.doc)
    return set_text(self, clean(text), ...)
  end

  local on_text_input = CommandView.on_text_input
  function CommandView:on_text_input(text, ...)
    patch_command_doc(self.doc)
    return on_text_input(self, clean(text), ...)
  end
end

-- Patch the already-created global command view too; it exists before user
-- plugins are loaded.
if core.command_view then
  patch_command_doc(core.command_view.doc)
  clean_doc(core.command_view.doc)
end
