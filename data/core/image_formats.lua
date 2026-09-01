local image_formats = {}

local supported_extensions = {
  avif = true,
  bmp = true,
  cur = true,
  gif = true,
  ico = true,
  jpg = true, jpeg = true, jfif = true, pjpeg = true, pjp = true,
  jxl = true,
  lbm = true, iff = true,
  pcx = true,
  png = true,
  pnm = true, pbm = true, pgm = true, ppm = true,
  qoi = true,
  svg = true,
  tga = true,
  tif = true, tiff = true,
  webp = true,
  xcf = true,
  xpm = true,
  xv = true,
}

function image_formats.is_supported(path)
  local ext = path and path:match("%.(%a+)$")
  if ext then
    ext = ext:ulower()
    if supported_extensions[ext] then return true, ext end
  end
  return false, ext
end

return image_formats
