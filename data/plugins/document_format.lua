-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local process = require "core.process"
local Editor = require "core.editor"

local document_format = {}

local TIMEOUT_MS = 5000
local MAX_OUTPUT_BYTES = 64 * 1024 * 1024
local READ_BYTES = 64 * 1024

local extensions = {
  JSON = "json",
  TOML = "toml",
  XML = "xml",
  YAML = "yaml",
}

local recognized_extensions = {
  JSON = { json = true, jsonc = true },
  TOML = { toml = true },
  XML = { xml = true },
  YAML = { yaml = true, yml = true },
}

local function buffer_text(buffer)
  return table.concat(buffer.lines)
end

local function language_name(buffer)
  return buffer.syntax and buffer.syntax.name or "Plain Text"
end

local function buffer_is_open(buffer)
  for _, candidate in ipairs(core.buffers) do
    if candidate == buffer then return true end
  end
  return false
end

local function context_filename(buffer, language)
  local path = buffer.abs_filename or buffer.filename
  if path and path ~= "" then
    local name = common.basename(path)
    local extension = name:lower():match("%.([^.]*)$")
    if recognized_extensions[language][extension] then return name end
    return name .. "." .. extensions[language]
  end
  return "Untitled." .. extensions[language]
end

local function formatter_paths()
  local root = DATADIR .. PATHSEP .. "tools" .. PATHSEP .. "dprint"
  return {
    root = root,
    executable = root .. PATHSEP .. (PLATFORM == "Windows" and "dprint.exe" or "dprint"),
    config = root .. PATHSEP .. "anvil.json",
  }
end

local function first_error_line(stderr)
  local line = tostring(stderr or ""):match("[^\r\n]+")
  return line and line:match("^%s*(.-)%s*$") or nil
end

local function finish_process(proc, request, complete)
  local stdout, stderr = {}, {}
  local stdout_bytes = 0
  local started = system.get_time()

  while true do
    local out = proc:read_stdout(READ_BYTES)
    local err = proc:read_stderr(READ_BYTES)
    if out and #out > 0 then
      stdout_bytes = stdout_bytes + #out
      if stdout_bytes > MAX_OUTPUT_BYTES then
        pcall(proc.kill, proc)
        return complete(nil, "Formatter output exceeded 64 MB")
      end
      stdout[#stdout + 1] = out
    end
    if err and #err > 0 then stderr[#stderr + 1] = err end

    if not proc:running() then
      if not (out and #out > 0) and not (err and #err > 0) then break end
    elseif (system.get_time() - started) * 1000 >= TIMEOUT_MS then
      pcall(proc.kill, proc)
      return complete(nil, "Formatting timed out after 5 seconds")
    end
    coroutine.yield(0.01)
  end

  local exit_code = proc:returncode()
  local error_text = table.concat(stderr)
  if exit_code ~= 0 then
    core.log_quiet(
      "dprint failed for %s with code %s: %s",
      request.language, tostring(exit_code), error_text
    )
    return complete(nil, first_error_line(error_text)
      or string.format("dprint exited with code %s", tostring(exit_code)))
  end

  local output = table.concat(stdout)
  if request.text ~= "" and output == "" then
    return complete(nil, "dprint produced no output")
  end
  core.log_quiet(
    "Formatted %s with dprint in %.1fms input=%d output=%d",
    request.language, (system.get_time() - started) * 1000, #request.text, #output
  )
  complete(output)
end

---Run bundled dprint for one immutable formatting request.
---@param request table
---@param complete fun(output?: string, error?: string)
function document_format.run(request, complete)
  local paths = formatter_paths()
  core.add_thread(function()
    local proc, start_error = process.start({
      paths.executable,
      "fmt",
      "--log-level", "silent",
      "--config", paths.config,
      "--stdin", request.filename,
    }, {
      cwd = paths.root,
      stdin = process.REDIRECT_PIPE,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
      env = {
        DPRINT_CACHE_DIR = USERDIR .. PATHSEP .. "cache" .. PATHSEP .. "dprint",
        NO_COLOR = "1",
      },
    })
    if not proc then
      core.log_quiet("Could not start bundled dprint: %s", tostring(start_error))
      return complete(nil, "The bundled dprint formatter could not start")
    end

    local written, write_error = proc.stdin:write(request.text)
    proc.stdin:close()
    if not written then
      pcall(proc.kill, proc)
      return complete(nil, "Could not send the Buffer text to dprint: " .. tostring(write_error))
    end
    finish_process(proc, request, complete)
  end, request.buffer)
end

local function formatted_lines(text)
  text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  local lines = {}
  for line in text:gmatch(".-\n") do lines[#lines + 1] = line end
  if #lines == 0 then lines[1] = "\n" end
  return lines
end

local function formatting_edits(buffer, formatted)
  local old_lines = buffer.lines
  local new_lines = formatted_lines(formatted)
  local edits = {}
  local old_line, new_line = 1, 1
  local old_start, new_start, old_count, new_count

  local function begin_hunk()
    if old_start then return end
    old_start, new_start = old_line, new_line
    old_count, new_count = 0, 0
  end

  local function flush_hunk()
    if not old_start then return end
    local line1, col1, line2, col2
    if old_start <= #old_lines then
      line1, col1 = old_start, 1
    else
      line1, col1 = #old_lines, #old_lines[#old_lines]
    end
    local after_old = old_start + old_count
    if after_old <= #old_lines then
      line2, col2 = after_old, 1
    else
      line2, col2 = #old_lines, #old_lines[#old_lines]
    end

    local replacement = {}
    for i = new_start, new_start + new_count - 1 do
      replacement[#replacement + 1] = new_lines[i]
    end
    local text = table.concat(replacement)
    if new_start + new_count > #new_lines and text:sub(-1) == "\n" then
      text = text:sub(1, -2)
    end
    edits[#edits + 1] = {
      line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = text,
    }
    old_start, new_start, old_count, new_count = nil, nil, nil, nil
  end

  for change in diff.diff_iter(old_lines, new_lines) do
    if change.tag == "equal" then
      flush_hunk()
      old_line, new_line = old_line + 1, new_line + 1
    elseif change.tag == "delete" then
      begin_hunk()
      old_count, old_line = old_count + 1, old_line + 1
    elseif change.tag == "insert" then
      begin_hunk()
      new_count, new_line = new_count + 1, new_line + 1
    else
      begin_hunk()
      old_count, new_count = old_count + 1, new_count + 1
      old_line, new_line = old_line + 1, new_line + 1
    end
  end
  flush_hunk()
  return edits
end

local function request_is_current(request)
  local buffer = request.buffer
  return buffer_is_open(buffer)
    and buffer.text_revision == request.revision
    and language_name(buffer) == request.language
    and (buffer.abs_filename or buffer.filename) == request.path
end

function document_format.format(view)
  if not view:can_edit("format", { warn = true }) then return false end
  local buffer = view.buffer
  local language = language_name(buffer)
  if not extensions[language] then
    core.error("No document formatter is available for %s", language)
    return false
  end
  local request = {
    buffer = buffer,
    revision = buffer.text_revision,
    language = language,
    path = buffer.abs_filename or buffer.filename,
    filename = context_filename(buffer, language),
    text = buffer_text(buffer),
  }

  document_format.run(request, function(output, error_message)
    if error_message then
      core.error("Could not format %s: %s", request.language, error_message)
      return
    end
    if not request_is_current(request) then
      core.log_quiet("Discarded stale %s formatting result", request.language)
      return
    end

    local normalized_output = table.concat(formatted_lines(output))
    if normalized_output == request.text then
      core.log_quiet("%s Buffer was already formatted", request.language)
      return
    end
    local edits = formatting_edits(buffer, normalized_output)
    if not request_is_current(request) then return end
    buffer:apply_edits(edits, {
      type = "format",
      merge_cursors = false,
      merge_undo = false,
      strict = true,
    })
  end)
  return true
end

local function format_target()
  local view = core.current_editor()
  if view and view:extends(Editor) then return true, view end
  return false
end

command.add(format_target, {
  ["editor:format_document"] = command.palette(function(view)
    return document_format.format(view)
  end),
})

return document_format
