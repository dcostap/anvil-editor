local common = require "core.common"
local Buffer = require "core.buffer"
local test = require "core.test"

local function median(values)
  table.sort(values)
  return values[math.floor((#values + 1) / 2)]
end

local function benchmark_detection(path, iterations)
  local samples = {}
  local charset
  for i = 1, iterations do
    local started = system.get_time()
    charset = assert(encoding.detect(path))
    samples[i] = (system.get_time() - started) * 1000
  end
  return charset, median(samples)
end

local function write_repeated(file, text, count)
  for _ = 1, count do file:write(text) end
end

local function benchmark_load(path)
  collectgarbage("collect")
  local started = system.get_time()
  local buffer = Buffer(path, path, false)
  local elapsed = (system.get_time() - started) * 1000
  return buffer.encoding, buffer.binary, #buffer.lines, elapsed
end

test.describe("encoding detection benchmark", function()
  test.test("reports large file detection time", function()
    local root = USERDIR .. PATHSEP .. "encoding-benchmark-" .. system.get_process_id()
    local ok, err = common.mkdirp(root)
    test.ok(ok, err)

    local utf8_path = root .. PATHSEP .. "large-utf8.txt"
    local utf8_file = assert(io.open(utf8_path, "wb"))
    write_repeated(utf8_file, "Plain UTF-8 text with café and 日本語.\n", 200000)
    utf8_file:close()

    local invalid_path = root .. PATHSEP .. "large-invalid.bin"
    local invalid_file = assert(io.open(invalid_path, "wb"))
    write_repeated(invalid_file, "\000\255\001\254binary payload\n", 400000)
    invalid_file:close()

    local utf8_info = assert(system.get_file_info(utf8_path))
    local invalid_info = assert(system.get_file_info(invalid_path))
    local utf8_charset, utf8_ms = benchmark_detection(utf8_path, 3)
    local invalid_charset, invalid_ms = benchmark_detection(invalid_path, 3)

    print(string.format(
      "Encoding detect valid UTF-8: bytes=%d charset=%s median_ms=%.3f",
      utf8_info.size, utf8_charset, utf8_ms
    ))
    print(string.format(
      "Encoding detect invalid binary-like: bytes=%d charset=%s median_ms=%.3f",
      invalid_info.size, invalid_charset, invalid_ms
    ))

    local loaded_charset, binary, lines, load_ms = benchmark_load(invalid_path)
    print(string.format(
      "Encoding load invalid binary-like: bytes=%d charset=%s binary=%s lines=%d ms=%.3f",
      invalid_info.size, loaded_charset, tostring(binary), lines, load_ms
    ))

    local removed, remove_err = common.rm(root, true)
    test.ok(removed, remove_err)
  end)
end)
