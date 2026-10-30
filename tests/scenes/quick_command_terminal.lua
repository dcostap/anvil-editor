-- Deterministic Terminal I/O for Quick Command tests and scenarios.
local next_session = 0

return function(context)
  local native = {}
  function native.read_session_record(id) return context.records[id], 2 end
  function native.new(options)
    next_session = next_session + 1
    local session = {
      id = options.session_id or string.format("%032x", next_session),
      writes = {}, busy = false, capture = "",
    }
    function session:update()
      return false, { kind = context.connecting and "reconnecting" or "running",
        revision = 1, attach_count = 1, busy = self.busy }
    end
    function session:snapshot(previous)
      return previous or {
        rows = {}, cols = 80, row_count = 24, foreground = 0xffffff, background = 0,
        cursor = { visible = true, x = 0, y = 0, style = "block" }, events = {},
      }
    end
    function session:write(text)
      self.writes[#self.writes + 1] = text
      if context.on_write then context.on_write() end
      return true
    end
    function session:text_capture()
      return { text = self.capture, cursor_line = 1, cursor_col = 1, viewport_line = 1 }
    end
    function session:stats()
      return { session_id = self.id, attach_count = 1, host_pid = 1, shell_pid = 1, replay_bytes = 0 }
    end
    setmetatable(session, { __index = function() return function() return true end end })
    context.sessions[#context.sessions + 1] = session
    return session
  end
  return native
end
