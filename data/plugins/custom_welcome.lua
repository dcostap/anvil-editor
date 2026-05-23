-- mod-version:3
-- Minimal local replacement for Anvil's welcome screen.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local EmptyView = require "core.emptyview"

local quote_file = USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "custom_welcome" .. PATHSEP .. "quotes.txt"

local fallback_quotes = {
  { "Programs must be written for people to read, and only incidentally for machines to execute.", "— Harold Abelson" },
  { "Simplicity is prerequisite for reliability.", "— Edsger W. Dijkstra" },
  { "First, solve the problem. Then, write the code.", "— John Johnson" },
  { "Deleted code is debugged code.", "— the old gods of maintenance" },
  { "The best abstraction is the one you can still explain after midnight.", "— anonymous build server" },
  { "A clean diff is a small act of mercy.", "— future you" },
  { "Make it work, make it right, make it disappear into obviousness.", "— refactorer's prayer" },
  { "The compiler is not angry; it is merely exact.", "— terminal proverb" },
  { "In the beginning was the bug report, and the bug report was vague.", "— apocrypha.log" },
  { "Ship the thing. Polish the scar tissue later.", "— release branch koan" },
  { "Every elegant system is a truce between ambition and entropy.", "— pretentious enough" },
  { "Code is a garden. Also, sometimes, a swamp with invoices.", "— practical mysticism" },
}

local loaded_quotes

local function byline_for(author)
  author = (author or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = author:lower()
  if author == "" or lower == "unknown" or lower == "unknown author" then
    return ""
  end
  return author:match("^—") and author or ("— " .. author)
end

local function load_quotes()
  if loaded_quotes then return loaded_quotes end

  loaded_quotes = {}
  local fp = io.open(quote_file, "r")
  if fp then
    for line in fp:lines() do
      line = line:gsub("\r$", "")
      local is_comment = line:match("^%s*#") and not line:find("\t", 1, true)
      if line:match("%S") and not is_comment then
        local text, author = line:match("^(.-)\t(.*)$")
        if not text then
          text, author = line, ""
        end
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
          loaded_quotes[#loaded_quotes + 1] = { text, byline_for(author) }
        end
      end
    end
    fp:close()
  end

  if #loaded_quotes == 0 then
    loaded_quotes = fallback_quotes
  end

  return loaded_quotes
end

local function pick_quote()
  local quotes = load_quotes()
  local t = system.get_time and system.get_time() or os.clock()
  local seed = (os.time() or 0) + math.floor(t * 1000000)
  return quotes[(seed % #quotes) + 1]
end

local function wrap_text(font, text, max_width)
  local lines = {}
  local current = ""

  for word in text:gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)
    if current ~= "" and font:get_width(candidate) > max_width then
      lines[#lines + 1] = current
      current = word
    else
      current = candidate
    end
  end

  if current ~= "" then
    lines[#lines + 1] = current
  end

  return lines
end

local function prepare(view)
  view.name = "Welcome"
  view.type_name = "core.emptyview"
  view.background_color = style.background
  view.border.width = 0
  view.scrollable = false
  view.render_background = false
  view.quote = pick_quote()

  if view.destroy_childs then
    view:destroy_childs()
  end

  if view.scroll then
    view.scroll.x, view.scroll.y = 0, 0
    view.scroll.to.x, view.scroll.to.y = 0, 0
  end

  view.updated = true
end

function EmptyView:new()
  EmptyView.super.new(self, nil, false)
  prepare(self)
  self:show()
  self:update()
end

function EmptyView:get_scrollable_size()
  return self.size.y
end

function EmptyView:get_h_scrollable_size()
  return self.size.x
end

function EmptyView:update()
  if not EmptyView.super.update(self) then return end
  self.background_color = style.background
  self.updated = true
end

function EmptyView:draw()
  if not self:is_visible() or self.size.x <= 0 or self.size.y <= 0 then return end

  -- Draw a genuinely blank pane, bypassing the wallpaper patch on View:draw_background.
  renderer.draw_rect(self.position.x, self.position.y, self.size.x, self.size.y, style.background)

  local quote = self.quote or pick_quote()
  local text, byline = quote[1], quote[2]
  local font = style.font
  local max_width = math.min(self.size.x - style.padding.x * 8, 720 * SCALE)
  max_width = math.max(max_width, 160 * SCALE)

  local lines = wrap_text(font, text, max_width)
  local byline_lines = byline ~= "" and wrap_text(font, byline, max_width) or {}
  local line_h = font:get_height()
  local gap = #byline_lines > 0 and math.floor(style.padding.y * 1.5) or 0
  local total_h = (#lines * line_h) + gap + (#byline_lines * line_h)
  local y = common.round(self.position.y + (self.size.y - total_h) / 2)

  for _, line in ipairs(lines) do
    common.draw_text(font, style.dim, line, "center", self.position.x, y, self.size.x, line_h)
    y = y + line_h
  end

  y = y + gap
  for _, line in ipairs(byline_lines) do
    common.draw_text(font, common.lighten_color(style.dim, 18), line, "center", self.position.x, y, self.size.x, line_h)
    y = y + line_h
  end
end

local function patch_existing_node(node)
  if not node then return end
  if node.type == "leaf" then
    for _, view in ipairs(node.views or {}) do
      if view.is and view:is(EmptyView) then
        prepare(view)
      end
    end
  else
    patch_existing_node(node.a)
    patch_existing_node(node.b)
  end
end

local function patch_existing()
  if core.root_view and core.root_view.root_node then
    patch_existing_node(core.root_view.root_node)
    core.redraw = true
  end
end

patch_existing()
core.add_thread(function()
  coroutine.yield(0)
  patch_existing()
end)
