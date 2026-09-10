local core = require "core"
local common = require "core.common"
local Editor = require "core.editor"
local panes = require "core.panes"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local symbol_index = require "core.treesitter.symbol_index"
local treesitter = require "core.treesitter"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

local function wait_until(predicate)
  local deadline = system.get_time() + 10
  repeat
    if predicate() then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return predicate()
end

test.describe("Project Symbol Search refresh", function()
  test.before_each(function(context)
    panes.reset_for_tests()
    symbol_index.reset_for_tests()
    context.projects = core.projects
    context.root = common.normalize_path(USERDIR .. PATHSEP .. "symbol-preview-"
      .. system.get_process_id() .. "-" .. math.floor(system.get_time() * 1000000))
    test.ok(common.mkdirp(context.root))
    context.path = context.root .. PATHSEP .. "IMPRESORAS.md"
    local file = test.not_nil(io.open(context.path, "wb"))
    file:write("# Software de monitoreo obsoleto\n\n# Software de monitorización\n")
    file:close()
    core.projects = { Project(context.root) }
    project_paths.configure_workspace {}
    context.buffer = core.open_buffer(context.path)
    panes.place(function() return Editor(context.buffer) end, { placement = "new", focus = true })
    test.ok(wait_until(function()
      treesitter.poll_buffer(context.buffer)
      return context.buffer.treesitter and context.buffer.treesitter.status == "ready"
    end), "the open file did not finish parsing")
    local index = symbol_index.ensure_scan(context.root)
    test.ok(wait_until(function() return index.status == "ready" end), index.reason)
  end)

  test.after_each(function(context)
    if context.restore_workers then context.restore_workers() end
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    panes.reset_for_tests()
    if context.buffer then
      context.buffer:clean()
      for i = #core.buffers, 1, -1 do
        if core.buffers[i] == context.buffer then table.remove(core.buffers, i) end
      end
      context.buffer:on_close()
    end
    symbol_index.reset_for_tests()
    core.projects = context.projects
    project_paths.configure_workspace {}
    if context.root then common.rm(context.root, true) end
  end)

  test.it("keeps matching headings while refining a search with a file preview", function()
    fuzzy_searcher.open("impreso$soft")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    for _, query in ipairs { "soft", "softw", "softwa", "softw", "soft" } do
      picker.input:set_text("impreso$" .. query)
      test.ok(wait_until(function()
        local first = picker.results and picker.results[1]
        return picker.status == "0 symbols — Tree-sitter"
          or (first and first.query == query and picker.status == "2 symbols — Tree-sitter")
      end), "the search did not finish for " .. query .. ": " .. tostring(picker.status))
      test.equal(#picker.results, 2, "missing headings for " .. query)
      local names = {}
      for _, result in ipairs(picker.results) do names[result.name] = true end
      test.same(names, { ["Software de monitoreo obsoleto"] = true, ["Software de monitorización"] = true })
      test.not_nil(picker:update_preview_view(), "the selected file needs a preview")
    end
  end)

  test.it("does not publish missing headings while the open file's symbols arrive", function(context)
    -- Delay worker replies so the query can finish before the file's symbols arrive.
    local pool = require("core.worker_pool").system()
    local submit = pool.submit
    local replies = {}
    local held = true
    pool.submit = function(self, spec)
      if spec.native_kind == "treesitter_index_text" and spec.native_payload.path == context.path then
        for _, name in ipairs { "on_result", "on_complete" } do
          local callback = spec[name]
          spec[name] = function(message)
            if held then
              replies[#replies + 1] = function() callback(message) end
            else
              callback(message)
            end
          end
        end
      end
      return submit(self, spec)
    end
    context.restore_workers = function()
      pool.submit = submit
      held = false
      for _, reply in ipairs(replies) do reply() end
      replies = {}
    end

    local request, reason, status = symbol_index.workspace_symbols_async("softw", { root = context.root })
    if request then
      test.ok(wait_until(function() return request.done end))
      if request.status == "fresh" then
        test.equal(#request.results, 2, "the query finished before the open file's symbols arrived")
      end
    else
      test.equal(status, "pending", reason)
      test.ok(wait_until(function() return #replies > 0 end))
    end
    context.restore_workers()
    test.ok(wait_until(function()
      local results, _, current = symbol_index.workspace_symbols("softw", { root = context.root })
      return current == "fresh" and results and #results == 2
    end), "the completed search must include both headings")
  end)

  test.it("does not invalidate a symbol search when opening a read-only preview", function(context)
    test.ok(wait_until(function()
      local results, _, status = symbol_index.workspace_symbols("soft", { root = context.root })
      return status == "fresh" and results and #results == 2
    end))
    local request = test.not_nil(symbol_index.workspace_symbols_async("soft", { root = context.root }))
    local picker = fuzzy_searcher.open_static_results("Preview", {
      { kind = "file", file = "IMPRESORAS.md", abs_path = context.path },
    })
    test.not_nil(picker:update_preview_view())
    test.ok(wait_until(function() return request.done end))
    test.equal(request.status, "fresh", "a read-only preview must not change the searched symbols")
    test.equal(#request.results, 2)
  end)
end)
