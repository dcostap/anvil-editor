-- The image on the system clipboard. Programs put screenshots and copied images there in different formats, so
-- a reader takes the first format that the clipboard has.
local FORMATS = {
  { mime = "image/png", extension = "png" },
  { mime = "image/jpeg", extension = "jpg" },
  { mime = "image/bmp", extension = "bmp" },
}

---Returns the clipboard image's bytes and its format `{mime, extension}`, or nil when the clipboard has no image.
return function()
  if type(system.get_clipboard_data) ~= "function" then return nil end
  for _, format in ipairs(FORMATS) do
    local data = system.get_clipboard_data(format.mime)
    if data and #data > 0 then return data, format end
  end
end
