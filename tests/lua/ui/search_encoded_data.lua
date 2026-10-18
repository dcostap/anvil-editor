local core = require "core"
local common = require "core.common"
local command = require "core.command"
local panes = require "core.panes"
local Editor = require "core.editor"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"
require "plugins.intellij_find"

-- A pasted screenshot is one base64 data URI. Short words such as `plan`
-- occur in it by chance, so this payload holds `plan` every 1000 bytes.
local function encoded_payload(bytes)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local seed, chunks = 11, {}
  for i = 1, math.floor(bytes / 1000) do
    local chars = {}
    for j = 1, 996 do
      seed = (seed * 1103515245 + 12345) % 2147483648
      local index = math.floor(seed / 65536) % #alphabet + 1
      chars[j] = alphabet:sub(index, index)
    end
    chunks[i] = table.concat(chars) .. "plan"
  end
  return table.concat(chunks)
end

local function image_line(bytes)
  return "![shot](data:image/png;base64," .. encoded_payload(bytes) .. ")"
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 8)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

local function result_lines(picker)
  local lines = {}
  for _, result in ipairs(picker.results or {}) do lines[#lines + 1] = result.line end
  table.sort(lines)
  return table.concat(lines, ",")
end

local function searching(picker)
  return tostring(picker.status):find("…", 1, true) ~= nil
end

test.describe("Text search past encoded data", function()
  test.describe("Project text search", function()
    test.before_each(function(context)
      context.projects = core.projects
      context.cwd = system.getcwd()
      context.root = USERDIR .. PATHSEP .. "search-encoded-data-"
        .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000)
      test.ok(common.mkdirp(context.root))
      core.projects = { Project(context.root) }
      system.chdir(context.root)
      project_paths.configure_workspace {}
      local file = assert(io.open(context.root .. PATHSEP .. "note.md", "wb"))
      file:write("# Notes\nQuarterly review of the plan\n", image_line(2000000),
        "\nMore text about the plan\n")
      file:close()
    end)

    test.after_each(function(context)
      if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
      project_paths.configure_workspace {}
      core.projects = context.projects
      system.chdir(context.cwd)
      common.rm(context.root, true)
    end)

    for _, case in ipairs {
      { name = "an exact query", query = "#plan", expected = "2,4" },
      { name = "a query of several words", query = "#plan of", expected = "2" },
      { name = "a query with a Search Modifier", query = "#plan sort:name", expected = "2,4" },
    } do
      test.it("lists only the note's own text for " .. case.name, function()
        local started = system.get_time()
        fuzzy_searcher.open(case.query)
        local picker = test.not_nil(core.fuzzy_searcher_active_view)
        test.ok(wait_until(function()
          return result_lines(picker) == case.expected and not searching(picker)
        end), ("results %s, status %s"):format(result_lines(picker), tostring(picker.status)))
        local elapsed = system.get_time() - started
        coroutine.yield(0.2)
        test.equal(result_lines(picker), case.expected)
        test.ok(elapsed < 2, ("the search took %.2fs"):format(elapsed))
      end)
    end
  end)

  test.describe("Find", function()
    test.after_each(function(context)
      command.perform("editor:find_close")
      panes.reset_for_tests()
      if context.buffer then
        context.buffer:clean()
        for i, b in ipairs(core.buffers) do
          if b == context.buffer then table.remove(core.buffers, i); b:on_close(); break end
        end
      end
    end)

    -- Replace All edits these same matches, so it must not rewrite image data.
    test.it("matches only the note's own text", function(context)
      local buffer = core.open_buffer()
      context.buffer = buffer
      -- The second image is long enough to be scanned off the UI thread.
      buffer:text_input("the plan\n" .. image_line(4000) .. "\n" .. image_line(100000)
        .. "\nplan B\n")
      local view = panes.place(function() return Editor(buffer) end, { placement = "new", focus = true })
      view.size.x, view.size.y = 800, 600
      view:set_wrapping_enabled(false)
      view:with_selection_state(function() buffer:set_selection(1, 1) end)
      command.perform("editor:find")
      local input = core.active_view
      local state = input.local_find_state
      input:set_text("plan")
      test.ok(wait_until(function()
        view:update()
        return not state.pending
      end), "Find did not finish")
      local lines = {}
      for _, match in ipairs(state.matches) do lines[#lines + 1] = match.line end
      test.equal(table.concat(lines, ","), "1,4")
    end)
  end)
end)
