local common = require "core.common"
local core = require "core"
local command = require "core.command"
local DocView = require "core.docview"
local Project = require "core.project"
local test = require "core.test"

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  test.not_nil(file, err)
  local content = file:read("*a")
  file:close()
  return content
end

local function remove_doc(doc)
  local root = core.root_panel.root_node
  for _, view in ipairs(core.get_views_referencing_doc(doc)) do
    local node = root:get_node_for_view(view)
    if node then node:remove_view(root, view) end
  end
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

test.describe("Save As command", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_active_view = core.active_view
    context.original_nag_view = core.nag_view
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "doc-save-as-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    test.ok(common.mkdirp(context.temp_root))
    core.projects = { Project(context.temp_root) }
    system.chdir(context.temp_root)
  end)

  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    if context.temp_root then
      for i = #core.docs, 1, -1 do
        local doc = core.docs[i]
        if doc.abs_filename and common.path_belongs_to(doc.abs_filename, context.temp_root) then
          if doc:is_dirty() then doc:clean() end
          remove_doc(doc)
        elseif doc.new_file and not doc.filename then
          remove_doc(doc)
        end
      end
      if context.original_cwd then pcall(system.chdir, context.original_cwd) end
      if system.get_file_info(context.temp_root) then
        local ok, err = common.rm(context.temp_root, true)
        test.ok(ok, err)
      end
    end
    core.projects = context.original_projects
    core.active_view = context.original_active_view
    core.nag_view = context.original_nag_view
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
  end)

  test.test("untitled Save As warns before overwriting an existing project file", function(context)
    local target = join_path(context.temp_root, "existing.txt")
    write_file(target, "old content\n")

    local doc = core.open_doc()
    doc:insert(1, 1, "new content")
    local view = core.root_panel:open_doc(doc)
    core.set_active_view(view)

    core.nag_view = {
      show = function(_, title, message, buttons, callback)
        context.nag_title = title
        context.nag_message = message
        context.nag_buttons = buttons
        context.nag_callback = callback
      end
    }

    test.ok(command.perform("doc:save", view))
    test.equal(core.active_view, core.global_prompt_bar)
    core.global_prompt_bar:set_text("existing.txt")
    core.global_prompt_bar:submit()

    test.equal(context.nag_title, "Overwrite Existing File")
    test.ok(context.nag_message:find("existing.txt", 1, true), context.nag_message)
    test.equal(read_file(target), "old content\n")
    test.equal(doc.filename, nil)

    local old_add_thread = core.add_thread
    local pending_thread
    core.add_thread = function(fn)
      pending_thread = fn
      return -1
    end
    context.nag_callback({ text = "Cancel" })
    core.add_thread = old_add_thread
    test.not_nil(pending_thread)
    pending_thread()
    test.equal(core.active_view, core.global_prompt_bar)
    test.equal(core.global_prompt_bar:get_text(), "existing.txt")

    core.global_prompt_bar:submit()
    context.nag_callback({ text = "Overwrite" })
    test.equal(read_file(target):gsub("\r\n", "\n"), "new content\n")
    test.equal(doc.filename, "existing.txt")
  end)
end)
