-- Plays animated images one frame at a time.
--
-- Each player owns one streaming decoder and one frame canvas, so memory
-- depends on the image's size, never on its frame count. A player advances
-- only while something keeps drawing it, and closes once it goes undrawn.
local core = require "core"

local image_animation = {}

-- More players than this show their first frame without animating.
local MAX_PLAYERS = 8
-- Larger images would decode each frame on the UI thread for too long.
local MAX_PIXELS = 1000000
-- A player that was not drawn for this long closes its decoder.
local IDLE_CLOSE_SECONDS = 1
-- Browsers treat GIF delays of 10 ms or less as 100 ms. Many GIFs rely on it.
local MIN_DELAY_MS = 10
local DEFAULT_DELAY_MS = 100

local GIF_SIGNATURES = { ["GIF87a"] = true, ["GIF89a"] = true }

---@class core.image_animation.player
---@field version any
---@field animation userdata?
---@field canvas renderer.canvas?
---@field static boolean?
---@field due number?
---@field drawn_at number
---@field redraw_requested_for number?

---@type table<any, core.image_animation.player>
local players = {}
local open_count = 0
local clock_key = nil
local clock_wake_at = math.huge

---Return the animated format of image bytes, or nil for a still format.
---@param head string The first bytes of the image.
---@return string?
function image_animation.detect_type(head)
  if head and GIF_SIGNATURES[head:sub(1, 6)] then return "gif" end
  return nil
end

---Return the animated format of an image file, or nil.
---@param path string
---@return string?
function image_animation.detect_file_type(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local head = file:read(6)
  file:close()
  return image_animation.detect_type(head)
end

local function frame_delay(duration_ms)
  if not duration_ms or duration_ms <= MIN_DELAY_MS then duration_ms = DEFAULT_DELAY_MS end
  return duration_ms / 1000
end

local function close_player(key, player)
  if player.animation then
    player.animation:close()
    player.animation = nil
    player.canvas = nil
    open_count = open_count - 1
  end
  players[key] = nil
end

local function run_clock()
  while true do
    local now = system.get_time()
    local wake_at = math.huge
    for key, player in pairs(players) do
      local idle_at = player.drawn_at + IDLE_CLOSE_SECONDS
      if now >= idle_at then
        close_player(key, player)
      else
        wake_at = math.min(wake_at, idle_at)
        local due = player.due
        if due and due <= now then
          -- Request one redraw per frame. A player that was not drawn after
          -- that request is off screen, and waits for the idle close.
          if player.redraw_requested_for ~= due then
            player.redraw_requested_for = due
            core.redraw = true
          end
        elseif due then
          wake_at = math.min(wake_at, due)
        end
      end
    end
    if next(players) == nil then
      clock_key, clock_wake_at = nil, math.huge
      return
    end
    clock_wake_at = wake_at
    coroutine.yield(math.max(0, wake_at - system.get_time()))
  end
end

local function schedule_clock(at)
  if not clock_key then
    clock_wake_at = at
    clock_key = core.add_thread(run_clock)
  elseif at < clock_wake_at then
    clock_wake_at = at
    core.wake_thread(clock_key)
  end
end

local function open_player(key, opts, now)
  local player = { version = opts.version, drawn_at = now }
  players[key] = player
  if (opts.width or 0) * (opts.height or 0) > MAX_PIXELS then
    core.log_quiet("Image animation shows a still frame: %dx%d exceeds the size limit",
      opts.width, opts.height)
    player.static = true
    return player
  end
  if open_count >= MAX_PLAYERS then
    -- Retry when another player closes, not on every draw of this one.
    player.static = true
    player.retry_when_slot_frees = true
    return player
  end
  local animation, err = opts.open(key)
  if not animation then
    core.log_quiet("Image animation could not open: %s", tostring(err))
    player.static = true
    return player
  end
  open_count = open_count + 1
  player.animation = animation
  player.canvas = animation:get_canvas()
  player.due = now + frame_delay(animation:get_frame_duration())
  return player
end

local function advance(key, player, now)
  local duration, err = player.animation:next_frame()
  if not duration then
    if duration == nil then
      core.log_quiet("Image animation stopped: %s", tostring(err))
    end
    -- A single-frame image looks the same as its still image.
    player.animation:close()
    player.animation, player.canvas, player.due = nil, nil, nil
    player.static = true
    open_count = open_count - 1
    return
  end
  local delay = frame_delay(duration)
  -- Keep the frame rhythm, but do not replay frames missed while hidden.
  local due = player.due + delay
  if due <= now then due = now + delay end
  player.due = due
end

---Return the current frame canvas of an animated image, or nil when the
---caller should draw its still image. Call this from each draw of the image;
---drawing is what keeps the animation playing.
---@param key any Identifies one displayed image, such as an asset entry.
---@param opts { version: any, open: fun(key: any): userdata?, string?, width: integer, height: integer, now: number? }
---`version` changes when the image source changes. `open(key)` returns a
---new canvas animation. `width` and `height` are the image's natural size.
---@return renderer.canvas?
function image_animation.frame(key, opts)
  local now = opts.now or system.get_time()
  local player = players[key]
  if player and player.version ~= opts.version then
    close_player(key, player)
    player = nil
  end
  if player and player.retry_when_slot_frees and open_count < MAX_PLAYERS then
    players[key] = nil
    player = nil
  end
  player = player or open_player(key, opts, now)
  player.drawn_at = now

  if player.due and player.due <= now then advance(key, player, now) end
  if player.due then schedule_clock(player.due) end
  -- The clock also closes idle players, including still ones.
  schedule_clock(now + IDLE_CLOSE_SECONDS)

  return player.canvas
end

---Close every player. Their images show still frames until drawn again.
function image_animation.close_all()
  for key, player in pairs(players) do close_player(key, player) end
end

return image_animation
