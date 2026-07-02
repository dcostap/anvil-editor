local core = require "core"
local command = require "core.command"
local common = require "core.common"
local test = require "core.test"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text or "")
  file:close()
end

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

test.describe("open file prompt", function()
  local old_error
  local errors

  test.before_each(function()
    old_error = core.error
    errors = {}
    core.error = function(fmt, ...)
      errors[#errors + 1] = string.format(fmt, ...)
    end
  end)

  test.after_each(function()
    core.error = old_error
    if core.global_prompt_bar then
      core.global_prompt_bar:exit(true)
    end
  end)

  test.it("validates an absolute path with spaces outside the project", function()
    local dir = join_path(USERDIR, "open file prompt spaces")
    local path = join_path(dir, "01 comprobacion consumo comunes Materiales.sql")
    test.ok(common.mkdirp(dir))
    write_file(path, "select 1\n")

    command.perform("core:open-file")

    test.ok(core.global_prompt_bar.state.validate(path), errors[1])
  end)

  test.it("accepts a pasted absolute path with trailing CRLF", function()
    local dir = join_path(USERDIR, "open file prompt crlf")
    local path = join_path(dir, "01 comprobacion consumo comunes Materiales.sql")
    test.ok(common.mkdirp(dir))
    write_file(path, "select 1\n")

    command.perform("core:open-file")

    test.ok(core.global_prompt_bar.state.validate(path .. "\r\n"), errors[1])
  end)
end)
