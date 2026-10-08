local locations = require "core.bookmark_locations"
local worker = {}

function worker.run(payload, context)
  for _, file in ipairs(payload.files) do
    if context.cancelled() then return end
    local info = system.get_file_info(file.path)
    local result = { path = file.path, missing = not info or info.type ~= "file" }
    if not result.missing then
      -- Equal size and modification time do not prove equal contents.
      if file.recovering or file.lines or not file.live then
        local snapshot = file.lines and locations.snapshot(file.lines)
        local lines = snapshot and snapshot.lines
        if not lines and not file.live and info.size <= locations.recovery_limit then
          local fp = io.open(file.path, "rb")
          if fp then
            local text = fp:read(locations.recovery_limit + 1)
            fp:close()
            if context.cancelled() then return end
            if text and #text <= locations.recovery_limit then
              local charset = encoding.detect(file.path) or "UTF-8"
              if charset ~= "UTF-8" then
                text = encoding.convert("UTF-8", charset, text, { strict = false, handle_from_bom = true })
              else text = encoding.strip_bom(text, "UTF-8") end
              if text then
                snapshot = locations.parse(text, context.cancelled)
                lines = snapshot and snapshot.lines
              end
            end
          end
        end
        result.records = lines and locations.resolve(lines, file.records, context.cancelled, file.snapshots) or {}
        if lines then
          for _, record in ipairs(result.records or {}) do
            if record.line then result.snapshot = snapshot; break end
          end
        end
        if not lines then
          for _, record in ipairs(file.records) do
            result.records[#result.records + 1] = {
              id = record.id, status = record.live and "ready" or "location_missing",
              line = record.live and record.line or nil, live = record.live,
            }
          end
          result.error = "File cannot be read or exceeds the recovery byte or line limit"
        end
      end
    end
    if not context.send { type = "result", payload = result } then return end
  end
end

return worker
