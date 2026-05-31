local common = require "core.common"
local core = require "core"
local command = require "core.command"
local test = require "core.test"

require "plugins.untitled_tabs"

local function line_without_newline(line)
  line = line or ""
  return line:sub(-1) == "\n" and line:sub(1, -2) or line
end

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

local function find_filetree_line(view, wanted)
  for i, line in ipairs(view.doc.lines) do
    if line_without_newline(line) == wanted then return i end
  end
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

local function setup_tree(context)
  local temp_root = core.root_project().path
    .. PATHSEP .. "filetree-new-file-tests-"
    .. system.get_process_id() .. "-"
    .. math.floor(system.get_time() * 1000000)
  test.ok(common.mkdirp(temp_root))
  context.temp_root = temp_root

  local paths = {
    folder = temp_root .. PATHSEP .. "test",
    file = temp_root .. PATHSEP .. "sibling.txt",
  }
  test.ok(common.mkdirp(paths.folder))
  write_file(paths.file, "sibling")

  local filetree = require "plugins.filetree"
  context.filetree = filetree
  context.previous_dir = filetree.current_dir
  filetree.current_dir = temp_root
  filetree:refresh(false, false)
  return filetree, paths
end

local function expected_prompt_text_for(path)
  local rel = common.relative_path(core.root_project().path, path)
  return common.home_encode(rel) .. PATHSEP
end

test.describe("File Tree New File integration", function()
  test.after_each(function(context)
    if core.active_view == core.global_prompt_bar then
      core.global_prompt_bar:exit(false)
    end
    if context.filetree then
      context.filetree.current_dir = context.previous_dir or context.filetree.current_dir
      context.filetree:refresh(false, false)
    end
    if context.temp_root then
      for i = #core.docs, 1, -1 do
        local doc = core.docs[i]
        if doc.abs_filename and common.path_belongs_to(doc.abs_filename, context.temp_root) then
          if doc:is_dirty() then doc:clean() end
          remove_doc(doc)
        end
      end
      if system.get_file_info(context.temp_root) then
        local ok, err = common.rm(context.temp_root, true)
        test.ok(ok, err)
      end
    end
  end)

  test.it("prefills the New File prompt from the selected File Tree folder", function(context)
    local filetree, paths = setup_tree(context)
    local folder_line = find_filetree_line(filetree, "test/")
    test.not_nil(folder_line, "expected folder row in File Tree")

    filetree.doc:set_selection(folder_line, 1)
    core.set_active_view(filetree)
    test.ok(command.perform("user:new-file-with-path"))

    test.equal(core.global_prompt_bar:get_text(), expected_prompt_text_for(paths.folder))
  end)

  test.it("falls back to the nearest existing parent for a draft File Tree folder", function(context)
    local filetree = setup_tree(context)

    filetree.doc:insert(1, 1, "draft/\n")
    filetree.doc:set_selection(1, 1)
    core.set_active_view(filetree)
    test.ok(command.perform("user:new-file-with-path"))

    test.equal(core.global_prompt_bar:get_text(), expected_prompt_text_for(context.temp_root))
  end)

  test.it("refreshes and reveals a file created from the File Tree New File prompt", function(context)
    local filetree, paths = setup_tree(context)
    local folder_line = find_filetree_line(filetree, "test/")
    test.not_nil(folder_line, "expected folder row in File Tree")

    filetree.doc:set_selection(folder_line, 1)
    core.set_active_view(filetree)
    test.ok(command.perform("user:new-file-with-path"))

    local prompt_text = core.global_prompt_bar:get_text()
    test.equal(prompt_text, expected_prompt_text_for(paths.folder))
    core.global_prompt_bar:set_text(prompt_text .. "created.txt")
    core.global_prompt_bar:submit()

    local created = paths.folder .. PATHSEP .. "created.txt"
    local info = system.get_file_info(created)
    test.not_nil(info, "expected New File prompt to create the file on disk")
    test.equal(info.type, "file")
    test.not_nil(find_filetree_line(filetree, "\tcreated.txt"), "expected File Tree to refresh and reveal the new file")
  end)
end)
