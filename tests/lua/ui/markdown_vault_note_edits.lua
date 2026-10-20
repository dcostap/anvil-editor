local core = require "core"
local common = require "core.common"
local Editor = require "core.editor"
local Project = require "core.project"
local markdown = require "core.markdown"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function write_file(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function wait_until(predicate, message)
  local deadline = system.get_time() + 5
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if predicate() then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  error(message, 2)
end

local function link_resolution(view, line)
  local render_line = view:get_line_render(line)
  if not render_line then return nil end
  for _, fragment in ipairs(view:iter_line_render_fragments(render_line)) do
    if fragment.link then return fragment.link_resolution end
  end
end

test.describe("Markdown notes open beside an edited note", function()
  test.before_each(function(c)
    c.projects, c.active_view = core.projects, core.active_view
    c.root = USERDIR .. PATHSEP .. "vault-note-edits-" .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(c.root))
    write_file(c.root .. PATHSEP .. "Tasks.md", "# Tasks\n\n- [ ] Call about [[Plans]] soon\n")
    write_file(c.root .. PATHSEP .. "Plans.md", "# Plans\n\n- [ ] Draft the [[Budget]] outline\n")
    write_file(c.root .. PATHSEP .. "Budget.md", "# Budget\n")
    write_file(c.root .. PATHSEP .. "Review.md", "# Review\n\nSee [[tasks#Done]] first\n")
    core.projects = { Project(c.root) }
    c.index = markdown.vault_index.get_index(c.root):rebuild("vault-note-edits-test")
    c.views, c.buffers = {}, {}
    local function open(name)
      local buffer = core.open_buffer(c.root .. PATHSEP .. name)
      local view = Editor(buffer)
      view.size.x, view.size.y = 800, 600
      markdown.live_render.refresh_view(view)
      c.buffers[#c.buffers + 1], c.views[#c.views + 1] = buffer, view
      return view
    end
    c.plans, c.review, c.tasks = open("Plans.md"), open("Review.md"), open("Tasks.md")
    wait_until(function()
      local plans, review = link_resolution(c.plans, 3), link_resolution(c.review, 3)
      return plans and plans.status == "resolved" and review and review.status ~= "pending"
    end, "the open notes did not resolve their links")
  end)

  test.after_each(function(c)
    for _, view in ipairs(c.views) do view:on_close() end
    for _, buffer in ipairs(c.buffers) do core.buffer_registry:remove(buffer, true) end
    core.active_view, core.projects = c.active_view, c.projects
    common.rm(c.root, true)
  end)

  -- Edit the task note and wait until the vault index holds the edit.
  local function edit_tasks(c, line, col, text)
    local path = c.tasks.buffer.abs_filename
    local before = c.index:note(path).fact_signature
    c.tasks.buffer:insert(line, col, text)
    wait_until(function() return c.index:note(path).fact_signature ~= before end,
      "the vault index did not publish the edited note")
  end

  test.it("keeps an unrelated note's rendered lines while another note is edited", function(c)
    local plan = c.plans:get_line_render(3)
    test.not_nil(plan)
    -- Typing before the link moves it in the edited note. No other note depends on that.
    edit_tasks(c, 3, 16, "x")
    test.ok(rawequal(c.plans:peek_line_render(3), plan),
      "an edit in another note rebuilt a line that does not link to it")
  end)

  test.it("resolves a link to the edited note once the note gains its target heading", function(c)
    test.ok(link_resolution(c.review, 3).subtarget_missing, "the heading should start out missing")
    edit_tasks(c, 4, 1, "\n## Done\n")
    local resolution = link_resolution(c.review, 3)
    test.equal(resolution.status, "resolved")
    test.not_ok(resolution.subtarget_missing, "the link did not find the new heading")
  end)
end)
