local core = require "core"
local command = require "core.command"
local test = require "core.test"
local Editor = require "core.editor"
local panes = require "core.panes"
local syntax = require "core.syntax"
local document_format = require "plugins.document_format"

local function remove_buffer(buffer)
  for i = #core.buffers, 1, -1 do
    if core.buffers[i] == buffer then
      table.remove(core.buffers, i)
      buffer:on_close()
      return
    end
  end
end

local function open_json(context, text)
  local buffer = core.open_buffer()
  context.buffers[#context.buffers + 1] = buffer
  buffer:text_input(text)
  buffer.syntax = assert(syntax.find("Untitled.json"))
  local view = panes.place(function() return Editor(buffer) end, {
    placement = "new",
    focus = true,
  })
  return view, buffer
end

test.describe("document formatting", function()
  test.before_each(function(context)
    context.buffers = {}
    context.run = document_format.run
  end)

  test.after_each(function(context)
    document_format.run = context.run
    panes.reset_for_tests()
    for _, buffer in ipairs(context.buffers) do
      if buffer:is_dirty() then buffer:clean() end
      remove_buffer(buffer)
    end
  end)

  test.it("formats the complete Buffer as one undoable change", function(context)
    local view, buffer = open_json(context, '{\n"one":1,\n"two":2\n}')
    view:with_selection_state(function()
      buffer:set_selection(4, 2, 4, 2)
    end)
    local changes = 0
    function buffer:on_text_change() changes = changes + 1 end

    document_format.run = function(request, complete)
      test.equal(request.language, "JSON")
      test.equal(request.filename, "Untitled.json")
      local formatted = '{\n  "one": 1,\n  "two": 2\n}\n'
      core.add_thread(function()
        coroutine.yield()
        complete(formatted)
      end)
    end

    test.ok(command.perform("editor:format_document"))
    coroutine.yield(0.1)
    test.equal(table.concat(buffer.lines), '{\n  "one": 1,\n  "two": 2\n}\n')
    test.same({ buffer:get_selection() }, { 4, 2, 4, 2 })
    test.equal(changes, 1)

    buffer:undo()
    test.equal(table.concat(buffer.lines), '{\n"one":1,\n"two":2\n}\n')
  end)

  test.it("rejects formatter output after the Buffer changes", function(context)
    local _, buffer = open_json(context, '{"one":1}')
    local complete
    document_format.run = function(_, callback) complete = callback end

    test.ok(command.perform("editor:format_document"))
    buffer:insert(1, 1, " ")
    complete('{\n  "one": 1\n}\n')

    test.equal(table.concat(buffer.lines), ' {"one":1}\n')
  end)

  test.it("applies a formatter result that replaces the complete Buffer", function(context)
    local _, buffer = open_json(context, '{"values":[1,2]}')
    document_format.run = function(_, complete)
      core.add_thread(function()
        coroutine.yield()
        complete('{\n  "values": [\n    1,\n    2\n  ]\n}\n')
      end)
    end

    test.ok(command.perform("editor:format_document"))
    coroutine.yield(0.1)
    test.equal(table.concat(buffer.lines), '{\n  "values": [\n    1,\n    2\n  ]\n}\n')
  end)

  test.it("formats JSON with the bundled dprint runtime", function()
    local finished, output, format_error = false
    document_format.run({
      language = "JSON",
      filename = "sample.json",
      text = '{"one":1,"two":[2,3]}\n',
    }, function(result, error_message)
      output, format_error, finished = result, error_message, true
    end)

    local started = system.get_time()
    while not finished and system.get_time() - started < 10 do coroutine.yield(0.05) end
    test.ok(finished, "bundled dprint did not finish")
    test.equal(format_error, nil)
    test.equal(output, '{ "one": 1, "two": [2, 3] }\n')
  end)

  test.it("bundles formatters for TOML, YAML, and XML", function()
    local cases = {
      { language = "TOML", filename = "sample.toml", text = "one=1\n" },
      { language = "YAML", filename = "sample.yaml", text = "one: [1,2]\n" },
      { language = "XML", filename = "sample.xml", text = "<root><item/></root>\n" },
    }
    for _, case in ipairs(cases) do
      local finished, output, format_error = false
      document_format.run(case, function(result, error_message)
        output, format_error, finished = result, error_message, true
      end)
      local started = system.get_time()
      while not finished and system.get_time() - started < 10 do coroutine.yield(0.05) end
      test.ok(finished, case.language .. " formatter did not finish")
      test.equal(format_error, nil)
      test.ok(output ~= case.text, case.language .. " formatter did not change the sample")
    end
  end)

  test.it("does not offer formatting for unsupported Language Modes", function(context)
    open_json(context, "plain")
    core.current_editor().buffer.syntax = syntax.plain_text_syntax
    test.not_ok(command.is_valid("editor:format_document"))
  end)

  test.it("offers formatting for each bundled structured Language Mode", function(context)
    local _, buffer = open_json(context, "{}")
    for _, filename in ipairs { "data.json", "data.jsonc", "data.toml", "data.yaml", "data.xml" } do
      buffer.syntax = assert(syntax.find(filename), filename)
      test.ok(command.is_valid("editor:format_document"), filename)
    end
  end)
end)
