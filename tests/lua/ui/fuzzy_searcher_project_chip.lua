local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"
local fuzzy_searcher = require "plugins.fuzzy_searcher"

-- Headless tests have no window, so drawing goes to stubbed primitives. `texts` collects each drawn text and its x.
local function draw_without_window(draw, texts)
  local renderer = require "renderer"
  local saved = {}
  for name, fn in pairs(renderer) do
    if type(fn) == "function" and (name:match("^draw_") or name:match("^push_")
      or name:match("^pop_") or name == "set_clip_rect") then
      saved[name] = fn
      renderer[name] = function() end
    end
  end
  renderer.draw_text = function(font, text, x)
    texts[#texts + 1] = { text = text, x = x }
    return x + font:get_width(text)
  end
  local ok, err = pcall(draw)
  for name, fn in pairs(saved) do renderer[name] = fn end
  return ok, err
end

local function drawn_texts(picker)
  picker.position.x, picker.position.y = 0, 0
  picker:set_size(1400, 600)
  picker.open_transition_complete = true
  picker:update()
  local texts = {}
  local ok, err = draw_without_window(function() picker:draw() end, texts)
  test.ok(ok, err)
  return texts
end

local function find(texts, wanted)
  for _, item in ipairs(texts) do
    if item.text == wanted then return item end
  end
end

test.describe("Fuzzy Searcher Project chip", function()
  test.before_each(function(context)
    context.projects = core.projects
    context.sidebar = core.project_sidebar
    context.cwd = system.getcwd()
    context.root = USERDIR .. PATHSEP .. "fuzzy-chip-" .. system.get_process_id()
      .. "-" .. math.floor(system.get_time() * 1000000)
    context.project = context.root .. PATHSEP .. "alpha"
    test.ok(common.mkdirp(context.project))
    core.projects = { Project(context.project) }
    core.project_sidebar = nil
    system.chdir(context.project)
    project_paths.configure_workspace {}
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    core.project_sidebar = context.sidebar
    project_paths.configure_workspace {}
    core.projects = context.projects
    system.chdir(context.cwd)
    test.ok(test.remove_tree(context.root))
  end)

  test.it("shows the Project that it searches at the left of the query", function()
    fuzzy_searcher.open("#needle")
    local picker = test.not_nil(core.fuzzy_searcher_active_view)
    local name = test.not_nil(find(drawn_texts(picker), "alpha"), "the picker did not show the Project's name")
    test.ok(name.x < picker.input.position.x, "the Project's name is not at the left of the query")
  end)
end)
