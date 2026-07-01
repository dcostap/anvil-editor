local test = require "core.test"
local uri = require "core.lsp.uri"

test.describe("core.lsp.uri", function()
  test.test("converts Windows paths to file URIs", function()
    local file_uri = uri.path_to_uri([[C:\foo bar\a.cpp]])
    test.equal(file_uri, "file:///C:/foo%20bar/a.cpp")
  end)

  test.test("normalizes equivalent Windows file URI spellings", function()
    local normalized = uri.normalize_file_uri("file:///C%3A/foo%20bar/a.cpp")
    test.equal(normalized, "file:///C:/foo%20bar/a.cpp")
  end)

  test.test("round-trips Windows paths with drive letters and slash variants", function()
    local original = [[C:\foo bar\dir\a.cpp]]
    local file_uri = uri.path_to_uri(original)
    local path = test.not_nil(uri.uri_to_path(file_uri))
    if PLATFORM == "Windows" then
      test.equal(path, original)
    else
      test.equal(path, "/C:/foo bar/dir/a.cpp")
    end

    local forward_uri = uri.path_to_uri("C:/foo bar/dir/a.cpp")
    test.equal(forward_uri, "file:///C:/foo%20bar/dir/a.cpp")
  end)

  test.test("escapes and unescapes reserved and UTF-8 path bytes", function()
    local path = "C:/foo bar/%hash#query?/mañana.cpp"
    local escaped = uri.escape_path(path)
    test.equal(escaped, "C:/foo%20bar/%25hash%23query%3F/ma%C3%B1ana.cpp")
    test.equal(uri.unescape_path(escaped), path)
  end)

  test.test("converts escaped file URIs back to native paths", function()
    local file_uri = "file:///C:/foo%20bar/%25hash%23query%3F/ma%C3%B1ana.cpp"
    local path = test.not_nil(uri.uri_to_path(file_uri))
    if PLATFORM == "Windows" then
      test.equal(path, [[C:\foo bar\%hash#query?\mañana.cpp]])
    else
      test.equal(path, "/C:/foo bar/%hash#query?/mañana.cpp")
    end
  end)

  test.test("rejects unsupported URI schemes for file operations", function()
    local path, err = uri.uri_to_path("untitled:///scratch.cpp")
    test.is_nil(path)
    test.contains(err, "unsupported URI scheme")

    path, err = uri.file_operation_path("https://example.com/a.cpp")
    test.is_nil(path)
    test.contains(err, "unsupported URI scheme")
  end)

  test.test("builds normalized comparison keys for equivalent file paths", function()
    local key1 = test.not_nil(uri.comparison_key([[C:\Foo Bar\..\Foo Bar\a.cpp]]))
    local key2 = test.not_nil(uri.comparison_key("file:///C:/Foo%20Bar/a.cpp"))
    test.equal(key1, key2)
  end)
end)
