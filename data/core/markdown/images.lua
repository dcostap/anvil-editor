local common = require "core.common"

local images = {}

images.default_cache_dir = USERDIR .. PATHSEP .. "cache"

local function hash_text(text)
  local hash = 2166136261
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967296
  end
  return string.format("%08x", hash)
end

function images.is_remote(url)
  return type(url) == "string" and url:match("^https?://") ~= nil
end

function images.get_image_cache_path(url, cache_dir)
  cache_dir = cache_dir or images.default_cache_dir
  local normalized = (url or ""):match("^[^?#]+") or (url or "")
  local ext = normalized:match("%.([%w]+)$")
  ext = ext and ext:lower() or "img"
  return cache_dir .. PATHSEP .. "markdown-image-" .. hash_text(url or "") .. "." .. ext
end

function images.parse_resize(text)
  local links = require "core.markdown.links"
  return links.parse_resize(text)
end

local function dirname(path)
  if not path then return nil end
  return path:match("^(.*)[/\\][^/\\]*$")
end

local function join_path(a, b)
  if not a or a == "" then return b end
  if a:sub(-1) == PATHSEP or a:sub(-1) == "/" or a:sub(-1) == "\\" then
    return a .. b
  end
  return a .. PATHSEP .. b
end

function images.resolve_local_path(url, opts)
  opts = opts or {}
  if type(url) ~= "string" or url == "" or images.is_remote(url) then return nil end
  local filesystem_url = url:match("^[^#?]+") or url
  if filesystem_url == "" then return nil end
  if filesystem_url:match("^%a:[/\\]") or filesystem_url:sub(1, 1) == "/" or filesystem_url:sub(1, 1) == "\\" then
    return system.get_file_info(filesystem_url) and filesystem_url or nil
  end

  local source_dir = dirname(opts.source_path)
  if source_dir then
    local path = join_path(source_dir, filesystem_url)
    if system.get_file_info(path) then return path end
  end

  if opts.project_root then
    local path = join_path(opts.project_root, filesystem_url)
    if system.get_file_info(path) then return path end
  end
end

function images.load_from_path(path, opts)
  opts = opts or {}
  local loader = opts.loader or function(filename) return canvas.load_image(filename) end
  local image, errmsg = loader(path)
  if not image then
    return { status = "error", path = path, errmsg = errmsg or "image could not be loaded" }
  end
  return { status = "ready", path = path, image = image }
end

function images.ensure_entry(url, opts)
  opts = opts or {}
  local entry = {
    alt = opts.alt,
    url = url,
    status = "idle",
  }

  local local_path = images.resolve_local_path(url, opts)
  if local_path then
    local loaded = images.load_from_path(local_path, opts)
    for key, value in pairs(loaded) do entry[key] = value end
    return entry
  end

  if images.is_remote(url) then
    local cache_path = images.get_image_cache_path(url, opts.cache_dir)
    entry.path = cache_path
    if system.get_file_info(cache_path) then
      local loaded = images.load_from_path(cache_path, opts)
      for key, value in pairs(loaded) do entry[key] = value end
      return entry
    end

    if not opts.download_remote then
      entry.status = "remote-disabled"
      entry.errmsg = "remote image downloads are disabled"
      return entry
    end

    local downloader = opts.downloader
    if not downloader then
      local http = require "core.http"
      downloader = http.download
    end

    entry.status = "loading"
    downloader(url, {
      directory = opts.cache_dir or images.default_cache_dir,
      filename = common.basename(cache_path),
      on_done = opts.on_done,
    })
    return entry
  end

  entry.status = "error"
  entry.errmsg = "unsupported image source"
  return entry
end

function images.scale_size(width, height, max_width, resize, allow_upscale)
  if not width or not height then return nil, nil end
  local target_width = width
  local target_height = height

  if resize then
    if resize.width and resize.height then
      target_width = resize.width
      target_height = resize.height
    elseif resize.width then
      target_width = resize.width
      target_height = math.max(math.floor(height * (target_width / width)), 1)
    end
  end

  if max_width and target_width > max_width then
    local scale = max_width / target_width
    target_width = max_width
    target_height = math.max(math.floor(target_height * scale), 1)
  end

  if not allow_upscale then
    if target_width > width then
      local scale = width / target_width
      target_width = width
      target_height = math.max(math.floor(target_height * scale), 1)
    end
    if target_height > height then
      local scale = height / target_height
      target_height = height
      target_width = math.max(math.floor(target_width * scale), 1)
    end
  end

  return math.max(math.floor(target_width), 1), math.max(math.floor(target_height), 1)
end

return images
