local common = require "core.common"
local json = require "core.json"

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

local function percent_decode(text)
  return (text or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function filesystem_path_from_url(url)
  local path = percent_decode((url or ""):match("^[^#?]+") or (url or ""))
  if path:match("^file://") then
    local body = path:gsub("^file://", "")
    if body:match("^/%a:[/\\]") then
      return body:sub(2)
    elseif body:match("^%a:[/\\]") then
      return body
    elseif body:sub(1, 1) ~= "/" and body ~= "" then
      return "\\\\" .. body:gsub("/", "\\")
    end
    return body
  end
  return path
end

local function is_absolute_path(path)
  return path:match("^%a:[/\\]") or path:sub(1, 1) == "/" or path:sub(1, 1) == "\\"
end

local function file_exists(path)
  local info = path and system.get_file_info(path)
  return info and info.type == "file"
end

local function try_relative_file(root, rel)
  if not root then return nil end
  local path = join_path(root, rel)
  return file_exists(path) and path or nil
end

local function read_file(path)
  local fp = io.open(path, "rb")
  if not fp then return nil end
  local text = fp:read("*a")
  fp:close()
  return text
end

local function find_obsidian_vault_root(source_dir, project_root)
  local seen = {}
  local function scan_up(dir)
    while dir and dir ~= "" and not seen[dir] do
      seen[dir] = true
      local app_json = join_path(join_path(dir, ".obsidian"), "app.json")
      if file_exists(app_json) then return dir end
      local parent = dirname(dir)
      if parent == dir then return nil end
      dir = parent
    end
  end
  return scan_up(source_dir) or scan_up(project_root)
end

local function obsidian_attachment_folder(root)
  if not root then return nil end
  local app_json = join_path(join_path(root, ".obsidian"), "app.json")
  local settings = read_file(app_json)
  if not settings then return nil end
  local decoded = json.decode(settings)
  local folder = type(decoded) == "table" and decoded.attachmentFolderPath or nil
  if type(folder) ~= "string" or folder == "" then return nil end
  folder = folder:gsub("^%./", ""):gsub("^%.\\", "")
  if folder == "." then return root end
  if is_absolute_path(folder) then return folder end
  return join_path(root, folder)
end

local function resolve_in_obsidian_attachment_folder(rel, source_dir, project_root)
  local root = find_obsidian_vault_root(source_dir, project_root)
  local folder = obsidian_attachment_folder(root)
  return try_relative_file(folder, rel)
end

function images.resolve_local_path(url, opts)
  opts = opts or {}
  if type(url) ~= "string" or url == "" or images.is_remote(url) then return nil end
  local filesystem_url = filesystem_path_from_url(url)
  if filesystem_url == "" then return nil end
  if is_absolute_path(filesystem_url) then
    return file_exists(filesystem_url) and filesystem_url or nil
  end

  local source_dir = dirname(opts.source_path)
  local path = try_relative_file(source_dir, filesystem_url)
  if path then return path end

  path = try_relative_file(opts.project_root, filesystem_url)
  if path then return path end

  return resolve_in_obsidian_attachment_folder(filesystem_url, source_dir, opts.project_root)
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

local assets = {}
local asset_clock = 0
local MAX_ASSETS = 256

local function touch(entry)
  asset_clock = asset_clock + 1
  entry.last_used = asset_clock
end

local function prune_assets()
  local count = 0
  for _ in pairs(assets) do count = count + 1 end
  while count > MAX_ASSETS do
    local oldest_key, oldest
    for key, entry in pairs(assets) do
      if entry.status ~= "loading" and not next(entry.subscribers or {})
        and (not oldest or (entry.last_used or 0) < (oldest.last_used or 0))
      then
        oldest_key, oldest = key, entry
      end
    end
    if not oldest_key then return end
    assets[oldest_key] = nil
    count = count - 1
  end
end

local function normalize_context_path(path)
  return path and common.path_compare_key(common.normalize_path(path)) or ""
end

function images.asset_key(url, opts)
  opts = opts or {}
  local local_path = images.resolve_local_path(url, opts)
  if local_path then return "local\0" .. normalize_context_path(local_path) end
  if images.is_remote(url) then
    return table.concat({
      "remote", tostring(url or ""),
      normalize_context_path(opts.cache_dir or images.default_cache_dir),
      opts.download_remote and "on" or "off",
    }, "\0")
  end
  return table.concat({
    "missing", tostring(url or ""),
    normalize_context_path(opts.source_path),
    normalize_context_path(opts.project_root),
  }, "\0")
end

local function notify(entry)
  for owner, callback in pairs(entry.subscribers or {}) do
    local ok, err = pcall(callback, entry)
    if not ok then
      local core = require "core"
      core.log_quiet("Markdown image asset subscriber failed: %s", tostring(err))
      entry.subscribers[owner] = nil
    end
  end
end

local function apply_loaded(entry, loaded)
  entry.image = nil
  entry.errmsg = nil
  for key, value in pairs(loaded) do entry[key] = value end
  local info = entry.path and system.get_file_info(entry.path)
  entry.modified = info and info.modified
  entry.size = info and info.size
end

local function refresh_asset(entry, url, opts)
  entry.alt = opts.alt
  entry.url = url
  entry.retry_generation = opts.retry_generation
  entry.status = "idle"
  entry.image = nil
  entry.errmsg = nil

  local local_path = images.resolve_local_path(url, opts)
  if local_path then
    entry.path = local_path
    apply_loaded(entry, images.load_from_path(local_path, opts))
    notify(entry)
    return entry
  end

  if images.is_remote(url) then
    local cache_path = images.get_image_cache_path(url, opts.cache_dir)
    entry.path = cache_path
    if system.get_file_info(cache_path) then
      apply_loaded(entry, images.load_from_path(cache_path, opts))
      notify(entry)
      return entry
    end
    if not opts.download_remote then
      entry.status = "remote-disabled"
      entry.errmsg = "remote image downloads are disabled"
      notify(entry)
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
      on_done = function(ok, err, filename)
        if ok and filename then
          entry.path = filename
          apply_loaded(entry, images.load_from_path(filename, opts))
        else
          entry.status = "error"
          entry.errmsg = err or "image download failed"
        end
        notify(entry)
      end,
    })
    return entry
  end

  entry.status = "error"
  entry.errmsg = "unsupported image source"
  notify(entry)
  return entry
end

function images.get_asset(url, opts)
  opts = opts or {}
  local key = images.asset_key(url, opts)
  local entry = assets[key]
  if not entry then
    entry = {
      key = key,
      status = "idle",
      subscribers = setmetatable({}, { __mode = "k" }),
    }
    assets[key] = entry
    touch(entry)
    prune_assets()
    return refresh_asset(entry, url, opts)
  end

  touch(entry)
  local retry = entry.retry_generation ~= opts.retry_generation
  if retry and entry.status ~= "loading" then
    local info = entry.path and system.get_file_info(entry.path)
    local changed = info and (info.modified ~= entry.modified or info.size ~= entry.size)
    if entry.status == "error" or entry.status == "remote-disabled" or changed then
      refresh_asset(entry, url, opts)
    else
      entry.retry_generation = opts.retry_generation
    end
  end
  return entry
end

function images.subscribe(entry, owner, callback)
  assert(entry and entry.subscribers, "Markdown image asset entry is required")
  assert(owner ~= nil, "Markdown image asset subscriber owner is required")
  assert(type(callback) == "function", "Markdown image asset subscriber must be a function")
  entry.subscribers[owner] = callback
end

function images.unsubscribe(entry, owner)
  if not (entry and entry.subscribers and entry.subscribers[owner]) then return false end
  entry.subscribers[owner] = nil
  return true
end

function images.clear_assets()
  assets = {}
  asset_clock = 0
end

function images.scale_size(width, height, max_width, resize, allow_upscale)
  if not width or not height then return nil, nil end
  local target_width = width
  local target_height = height

  if resize then
    if resize.width and resize.height then
      local scale = math.min(resize.width / width, resize.height / height)
      if not allow_upscale then scale = math.min(scale, 1) end
      target_width = math.max(math.floor(width * scale), 1)
      target_height = math.max(math.floor(height * scale), 1)
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
