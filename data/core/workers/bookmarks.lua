local locations = require "core.bookmark_locations"
local worker = {}

function worker.run(payload, context)
  for _, file in ipairs(payload.files) do
    if context.cancelled() then return end
    local info = system.get_file_info(file.path)
    local result = { path = file.path, missing = not info or info.type ~= "file" }
    if not result.missing then
      result.signature = tostring(info.modified) .. ":" .. tostring(info.size)
      if file.lines or not file.live and (file.signature ~= result.signature or file.checking) then
        local lines = file.lines
        if not lines and info.size <= 8 * 1024 * 1024 then
          local fp = io.open(file.path, "rb")
          if fp then
            local text = fp:read(8 * 1024 * 1024 + 1)
            fp:close()
            if context.cancelled() then return end
            if text and #text <= 8 * 1024 * 1024 then
              local charset = encoding.detect(file.path) or "UTF-8"
              if charset ~= "UTF-8" then
                text = encoding.convert("UTF-8", charset, text, { strict = false, handle_from_bom = true })
              else text = encoding.strip_bom(text, "UTF-8") end
              if text then lines = encoding.split_lines(text) end
            end
          end
        end
        result.records = lines and locations.resolve(lines, file.records, context.cancelled()) or {}
        if not lines then
          for _, record in ipairs(file.records) do
            result.records[#result.records + 1] = { id = record.id, status = "location_missing" }
          end
          result.error = "File cannot be read or exceeds the recovery size limit"
        end
      end
    end
    if not context.send { type = "result", payload = result } then return end
  end
end

return worker
