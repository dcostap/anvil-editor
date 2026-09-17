local test = require "core.test"
local backend = require "plugins.git.backend"

test.it("reuses immutable revision content while enforcing each request's size limit", function()
  local original = backend.run_git
  local revision = string.rep("a", 40)
  local root = USERDIR .. "/immutable-" .. system.get_time()
  local ok, failure = xpcall(function()
    backend.run_git = function(_, _, _, callback)
      callback({ stdout = "revision content\n" })
    end
    local first
    backend.file_at(root, revision, "file.txt", {}, function(text, err)
      test.equal(err, nil)
      first = text
    end)
    test.equal(first, "revision content\n")
    backend.run_git = function() return { cancel = function() end } end
    local second
    backend.file_at(root, revision, "file.txt", {}, function(text, err)
      test.equal(err, nil)
      second = text
    end)
    test.equal(second, "revision content\n")
    local limited
    backend.file_at(root, revision, "file.txt", { max_output = 3 }, function(text, err)
      test.equal(text, nil)
      limited = err
    end)
    test.equal(limited.kind, "output_too_large")
  end, debug.traceback)
  backend.run_git = original
  if not ok then error(failure) end
end)

test.it("reloads mutable Git references instead of reusing previous content", function()
  local original = backend.run_git
  local ok, failure = xpcall(function()
    local content
    backend.run_git = function(_, _, _, callback) callback({ stdout = content }) end
    for _, revision in ipairs { "HEAD", backend.INDEX, "main", "abcdef0" } do
      for _, expected in ipairs { "before", "after" } do
        content = expected
        local actual
        backend.file_at(USERDIR, revision, "mutable.txt", {}, function(text) actual = text end)
        test.equal(actual, expected)
      end
    end
  end, debug.traceback)
  backend.run_git = original
  if not ok then error(failure) end
end)

test.it("loads known blobs directly and reuses their immutable content", function()
  local original = backend.run_git
  local object_id = string.rep("b", 40)
  local root = USERDIR .. "/object-" .. system.get_time()
  local calls = 0
  local ok, failure = xpcall(function()
    backend.run_git = function(_, args, _, callback)
      calls = calls + 1
      test.same(args, { "cat-file", "blob", object_id })
      callback({ stdout = "blob content\n" })
    end
    local first
    backend.file_at(root, backend.INDEX, "file.txt", { object_id = object_id }, function(text, err)
      test.equal(err, nil)
      first = text
    end)
    test.equal(first, "blob content\n")
    backend.run_git = function() test.fail("immutable blob content was loaded twice") end
    local second
    backend.file_at(root, backend.INDEX, "file.txt", { object_id = object_id }, function(text, err)
      test.equal(err, nil)
      second = text
    end)
    test.equal(second, "blob content\n")
    test.equal(calls, 1)
  end, debug.traceback)
  backend.run_git = original
  if not ok then error(failure) end
end)
