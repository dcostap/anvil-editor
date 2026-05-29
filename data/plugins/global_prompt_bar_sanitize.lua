--- mod-version:3
-- Sanitize invisible CR characters in the built-in bottom Global Prompt Bar input.
-- Windows clipboard/text injection can sometimes provide CRLF; keep this as a
-- defensive patch around prompt text paths so hidden \r characters cannot make
-- file operations fail with "filename, directory name, or volume label syntax is incorrect".

local core = require "core"
local common = require "core.common"
local GlobalPromptBar = require "core.global_prompt_bar"

-- Anvil's Windows absolute-path check only recognizes C:\\..., not C:/...
-- Pasted paths commonly use forward slashes, and Open File then prepends the
-- project directory, producing invalid paths like project\\C:/Users/...
if not common.__local_windows_forward_absolute_patched then
  common.__local_windows_forward_absolute_patched = true
  local is_absolute_path = common.is_absolute_path
  function common.is_absolute_path(path)
    local res = is_absolute_path(path)
    if res then return true end
    return tostring(path or ""):match("^(%a):/") and true or nil
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

local function patch_prompt_doc(doc)
  if not doc or doc.__local_global_prompt_bar_cr_patched then return end
  doc.__local_global_prompt_bar_cr_patched = true

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
  if type(options) ~= "table" or options.__local_global_prompt_bar_cr_sanitized then return options end
  options.__local_global_prompt_bar_cr_sanitized = true

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

if not GlobalPromptBar.__local_sanitize_cr_patched_v2 then
  GlobalPromptBar.__local_sanitize_cr_patched_v2 = true

  local new = GlobalPromptBar.new
  function GlobalPromptBar:new(...)
    local res = new(self, ...)
    patch_prompt_doc(self.doc)
    return res
  end

  local enter = GlobalPromptBar.enter
  function GlobalPromptBar:enter(label, ...)
    local first = select(1, ...)
    if type(first) == "table" then
      return enter(self, label, sanitize_options(first))
    end
    return enter(self, label, ...)
  end

  local get_text = GlobalPromptBar.get_text
  function GlobalPromptBar:get_text(...)
    clean_doc(self.doc)
    return clean(get_text(self, ...))
  end

  local set_text = GlobalPromptBar.set_text
  function GlobalPromptBar:set_text(text, ...)
    patch_prompt_doc(self.doc)
    return set_text(self, clean(text), ...)
  end

  local on_text_input = GlobalPromptBar.on_text_input
  function GlobalPromptBar:on_text_input(text, ...)
    patch_prompt_doc(self.doc)
    return on_text_input(self, clean(text), ...)
  end
end

-- Patch the already-created Global Prompt Bar too; it exists before user
-- plugins are loaded.
if core.global_prompt_bar then
  patch_prompt_doc(core.global_prompt_bar.doc)
  clean_doc(core.global_prompt_bar.doc)
end
