local test = require "core.test"
local common = require "core.common"
local filetree = require "plugins.filetree"

test.describe("File Tree I/O failure audit", function()
  test.before_each(function(context)
    context.root = USERDIR .. PATHSEP .. "audit-copy-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.root))
    context.io_open = io.open
    context.list_dir = system.list_dir
    context.file_info = system.get_file_info
  end)
  test.after_each(function(context)
    io.open = context.io_open
    system.list_dir = context.list_dir
    system.get_file_info = context.file_info
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
    test.not_ok(info, "incomplete destination remains")
  end)

  for _, failure in ipairs { "write", "close", "list", "link" } do
    test.it("rejects a copy after a " .. failure .. " failure", function(context)
      local source = context.root .. PATHSEP .. "source"
      local target = context.root .. PATHSEP .. "target"
      local is_dir = failure == "list" or failure == "link"
      if is_dir then
        test.ok(common.mkdirp(source))
      else
        local f = assert(io.open(source, "wb"))
        assert(f:write("source text")); assert(f:close())
      end
      context.view = assert(filetree.new())
      local injected = false
      io.open = function(path, mode)
        local f, err = context.io_open(path, mode)
        if not f or path ~= target or mode ~= "wb" then return f, err end
        return {
          write = function(_, text)
            if failure == "write" then injected = true; return nil, "write failed" end
            return f:write(text)
          end,
          close = function()
            local ok, close_err = f:close()
            if failure == "close" then injected = true; return nil, "close failed" end
            return ok, close_err
          end,
        }
      end
      system.list_dir = function(path)
        if path == source and failure == "list" then
          injected = true
          return nil, "list failed"
        end
        return context.list_dir(path)
      end
      system.get_file_info = function(path)
        local info = context.file_info(path)
        if path == source and failure == "link" then
          injected = true
          info.symlink = true
        end
        return info
      end
      local result = context.view:apply_plan {
        creates = {}, moves = {}, trashes = {},
        copies = { { from = source, to = target, type = is_dir and "dir" or "file" } },
      }
      test.ok(injected)
      test.not_ok(result)
      test.not_ok(system.get_file_info(target), "incomplete destination remains")
      test.ok(system.get_file_info(source), "source was removed")
    end)
  end
end)
