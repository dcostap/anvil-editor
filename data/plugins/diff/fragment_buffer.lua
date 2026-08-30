local Buffer = require "core.buffer"
local range_marker = require "core.range_marker"

local FragmentBuffer = {}

local next_id = 1

local function marker_range(marker)
  return marker and marker:range()
end

local function range_text(source, marker)
  local range = assert(marker_range(marker), "fragment source range is no longer valid")
  local line1, col1 = source:sanitize_position(range.line1, range.col1)
  local line2, col2 = source:sanitize_position(range.line2, range.col2)
  return source:get_text(line1, col1, line2, col2)
end

local function replace_all(buffer, text)
  local line2 = #buffer.lines
  buffer:apply_edits({ {
    line1 = 1, col1 = 1, line2 = line2, col2 = math.huge,
    text = text,
  } }, { type = "fragment-sync", record_undo = false })
end

function FragmentBuffer.new(source, line1, col1, line2, col2, opts)
  opts = opts or {}
  local marker = range_marker.new(source, {
    line1 = line1, col1 = col1, line2 = line2, col2 = col2,
    sticky_right = true,
    preserve_on_replace = true,
    kind = "diff-fragment",
  })
  local buffer = Buffer(nil, nil, true)
  buffer.display_name = opts.name
  buffer.fragment_source = source
  buffer.fragment_marker = marker
  local initial_text = range_text(source, marker)
  buffer.fragment_has_trailing_newline = initial_text:sub(-1) == "\n"
  buffer.fragment_syncing = true
  replace_all(buffer, initial_text)
  buffer:clear_undo_redo()
  buffer:clean()
  buffer.new_file = false
  buffer.fragment_syncing = false

  local id = "diff-fragment-" .. tostring(next_id)
  next_id = next_id + 1
  buffer.fragment_listener_id = id

  source:add_text_change_listener(id, {
    after_change = function(_, change)
      if buffer.fragment_closed or buffer.fragment_syncing then return end
      if not marker:is_valid() then
        local transaction = change and change.transaction
        local inverse = transaction and transaction.inverse_edits
        if not (inverse and #inverse == 1) then return end
        marker:set_range(
          inverse[1].line1, inverse[1].col1,
          inverse[1].line2, inverse[1].col2
        )
      end
      buffer.fragment_syncing = true
      replace_all(buffer, range_text(source, marker))
      buffer:clear_undo_redo()
      buffer:clean()
      buffer.fragment_syncing = false
    end,
  })

  buffer:add_text_change_listener(id, {
    after_change = function()
      if buffer.fragment_closed or buffer.fragment_syncing then return end
      local range = marker_range(marker)
      if not range then return end
      buffer.fragment_syncing = true
      local text = table.concat(buffer.lines)
      if not buffer.fragment_has_trailing_newline then text = text:gsub("\n$", "") end
      local transaction = source:apply_edits({ {
        line1 = range.line1, col1 = range.col1,
        line2 = range.line2, col2 = range.col2,
        text = text,
      } }, { type = "diff-fragment" })
      local inverse = transaction and transaction.inverse_edits and transaction.inverse_edits[1]
      if inverse then
        marker:set_range(inverse.line1, inverse.col1, inverse.line2, inverse.col2)
      end
      buffer.fragment_syncing = false
    end,
  })

  local close = buffer.on_close
  buffer.on_close = function(self, ...)
    if not self.fragment_closed then
      self.fragment_closed = true
      source:remove_text_change_listener(id)
      self:remove_text_change_listener(id)
      range_marker.remove(marker)
    end
    return close(self, ...)
  end

  return buffer
end

function FragmentBuffer.map_line(buffer, line)
  local range = buffer and marker_range(buffer.fragment_marker)
  return range and range.line1 + math.max(1, tonumber(line) or 1) - 1 or line
end

function FragmentBuffer.source_range(buffer)
  return buffer and marker_range(buffer.fragment_marker) or nil
end

return FragmentBuffer
