local test = require "core.test"
local common = require "core.common"
local filetree = require "plugins.filetree"

test.describe("File Tree I/O failure audit", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "audit-copy-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.io_open = io.open
  end)
  test.after_each(function(context)
    io.open = context.io_open
    if context.view then context.view:on_close() end
    test.ok(test.remove_tree(context.root))
  end)
  test.it("does not report a successful copy after a source read error", function(context)
    local source, target = context.root .. PATHSEP .. "source.txt", context.root .. PATHSEP .. "target.txt"
    local f = assert(io.open(source, "wb")); assert(f:write("complete source text\n")); assert(f:close())
    context.view = assert(filetree.new())
    context.view.current_dir = context.root
    context.view:refresh(false, false)
    local injected = 0
    io.open = function(path, mode, ...)
      if common.path_equals(path, source) and mode == "rb" then
        return {
          read = function() injected = injected + 1; return nil, "injected source read error", 5 end,
          close = function() return true end,
        }
      end
      return context.io_open(path, mode, ...)
    end
    local result = context.view:apply_plan {
      creates = {}, moves = {}, trashes = {},
      copies = { { from = source, to = target, type = "file" } },
    }
    io.open = context.io_open
    local info = system.get_file_info(target)
    print(string.format("AUDIT copy read_errors=%d reported_success=%s target_bytes=%s",
      injected, tostring(result), info and tostring(info.size) or "missing"))
    test.ok(injected > 0, "probe did not reach source read")
    test.ok(not result, "File Tree reported a successful copy after a read error")
  end)
end)
