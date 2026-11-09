local common = require "core.common"
local json = require "core.json"
local test = require "core.test"

-- Seam: real Pi tool results, through ConPTY and the terminal render model.
-- Compare with a fresh Light session, not fixed theme colors. No provider is contacted.
test.describe("Pi terminal appearance", function()
  test.it("matches a fresh Light session after live theme changes and reconnect", function()
    test.skip_if(PLATFORM ~= "Windows", "Windows Terminal test")
    local pi, node = os.getenv("ANVIL_TEST_PI"), os.getenv("ANVIL_TEST_NODE")
    test.skip_if(not pi or not node, "Set ANVIL_TEST_PI and ANVIL_TEST_NODE to run real Pi checks")
    local native = require "terminal_native"
    local root = USERDIR .. "/terminal-pi-appearance"
    assert(common.mkdirp(root))
    assert(common.mkdirp(root .. "/agent"))
    assert(common.mkdirp(root .. "/sessions"))
    local saved = {}
    for key, value in pairs {
      PI_CODING_AGENT_DIR = root .. "/agent", PI_CODING_AGENT_SESSION_DIR = root .. "/sessions",
      ANVIL_PI_STATUS = "0", ANVIL_PI_CONTROL = "0",
    } do
      saved[key] = os.getenv(key) or ""
      system.setenv(key, value)
    end
    local function save(path, text)
      local file = assert(io.open(path, "wb"))
      file:write(text)
      file:close()
    end
    local sessions = {}
    local stream
    local function wait(check, seconds)
      local deadline = system.get_time() + (seconds or 30)
      repeat
        for _, session in ipairs(sessions) do session:update() end
        if check() then return true end
        coroutine.yield(0.01)
      until system.get_time() >= deadline
      return false
    end
    local function colors(session)
      local snapshot = session:snapshot()
      local result = {}
      for _, row in ipairs(snapshot.rows or {}) do
        for _, run in ipairs(row.text_runs or {}) do
          for _, marker in ipairs {"ANVIL_APPEARANCE_TOOL", "ANVIL_APPEARANCE_DONE"} do
            if run.text:find(marker, 1, true) then
              local background = snapshot.background
              for _, span in ipairs(row.backgrounds or {}) do
                if run.col >= span.col and run.col < span.col + span.columns then background = span.color end
              end
              result[marker] = {foreground = run.fg, background = background}
            end
          end
        end
      end
      return result
    end
    local light = {foreground = 0x202020, background = 0xffffff}
    local dark = {foreground = 0xeeeeee, background = 0x101010}
    local function start(appearance, record)
      local options = {cols = 120, rows = 40, cell_width = 8, cell_height = 16,
        foreground = appearance.foreground, background = appearance.background, cwd = root}
      if record then
        options.session_id, options.host_pid = record.session_id, record.host_pid
        options.host_creation_time, options.pipe_name = record.host_creation_time, record.pipe_name
      else
        options.shell = [[powershell.exe -NoLogo -NoProfile -Command "$env:PATH=']]
          .. (DATADIR .. "/plugins/fuzzy_searcher;"):gsub("'", "''") .. [['+$env:PATH; & ']] .. pi:gsub("'", "''")
          .. [[' --provider anvil-test --model scripted --thinking off --no-session --no-extensions --no-skills --no-prompt-templates --tools read --use-theme light/dark 'Read the sample file.'"]]
      end
      local session = assert(native.new(options))
      sessions[#sessions + 1] = session
      test.ok(wait(function() return colors(session).ANVIL_APPEARANCE_DONE end, 90), "Pi did not finish its test tool")
      local rows = {}
      for _, row in ipairs(session:snapshot().rows or {}) do
        local parts = {}
        for _, run in ipairs(row.text_runs or {}) do parts[#parts + 1] = run.text end
        rows[#rows + 1] = table.concat(parts)
      end
      test.ok(colors(session).ANVIL_APPEARANCE_TOOL, "Pi did not show its tool output: " .. table.concat(rows, "\n"))
      return session
    end
    local ok, err = pcall(function()
      save(root .. "/ANVIL_APPEARANCE_TOOL.txt", "A test tool result.\n")
      save(root .. "/agent/settings.json", json.encode {quietStartup = true, tuiMode = "fullscreen"})
      stream = assert(require("core.process_stream").start(
        {node, system.getcwd() .. "/tests/fixtures/terminal-appearance-model.cjs", root}, {stderr = true}))
      local port
      test.ok(wait(function() port = stream:read_line(); return port end), "Scripted model did not start")
      save(root .. "/agent/models.json", json.encode {providers = {["anvil-test"] = {
        baseUrl = "http://127.0.0.1:" .. port .. "/v1", api = "openai-completions", apiKey = "local-test",
        models = {{id = "scripted", name = "Scripted", reasoning = false, input = {"text"},
          contextWindow = 32768, maxTokens = 1024, cost = {input = 0, output = 0, cacheRead = 0, cacheWrite = 0}}},
      }}})
      local fresh = start(light)
      local expected = colors(fresh)
      fresh:close()
      local session = start(dark)
      local previous = colors(session)
      test.not_equal(previous.ANVIL_APPEARANCE_TOOL.background, expected.ANVIL_APPEARANCE_TOOL.background)
      local function matches(value)
        local actual = colors(session)
        for marker, wanted in pairs(value) do
          local found = actual[marker]
          if not found or found.foreground ~= wanted.foreground or found.background ~= wanted.background then return false end
        end
        return true
      end
      test.ok(session:set_colors(light))
      local changed = wait(function() return matches(expected) end)
      test.ok(changed,
        "Live Light colors differ from fresh Pi: " .. json.encode(colors(session)))
      test.ok(session:set_colors(dark))
      test.ok(wait(function() return matches(previous) end), "Pi did not return to Dark colors")
      local id = session:stats().session_id
      session:detach()
      local record
      test.ok(wait(function()
        local text = native.read_session_record(id)
        record = text and assert(load(text, "record", "t", {}))()
        return record and not record.attached
      end), "Terminal Session did not detach")
      session = start(light, record)
      changed = wait(function() return matches(expected) end)
      test.ok(changed,
        "Reconnected Light colors differ from fresh Pi: " .. json.encode(colors(session)))
    end)
    for _, session in ipairs(sessions) do session:close() end
    native.finish_close_commands()
    if stream then stream:cancel() end
    for key, value in pairs(saved) do system.setenv(key, value) end
    test.ok(test.remove_tree(root))
    test.ok(ok, err)
  end)
end)
