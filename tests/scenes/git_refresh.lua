-- Edit a clean tracked file on disk, then restore it, with a File Tree open.
-- An action is complete when Git status shows the change, or shows the file clean again.
-- The edits come from outside the editor, as a build or another tool makes them.
local support = require "scenes.support"

local scene = {}

local function read(path)
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end

local function status(path)
  local info = require("plugins.file_git_status"):lookup(path, false)
  return info and info.kind or "clean"
end

function scene.setup(context)
  context.originals = {}
  for index, target in ipairs(context.settings.targets) do
    context.originals[index] = read(context.path(target))
  end
  return support.open_file_tree(context.root)
end

function scene.ready(context)
  return support.git_settled(context.root, true)
end

function scene.action_name(_, index)
  return index % 2 == 1 and "edit" or "restore"
end

function scene.dispatch(context, index)
  local targets = context.settings.targets
  local slot = (math.floor((index - 1) / 2)) % #targets + 1
  local path = context.path(targets[slot])
  context.target = path
  if index % 2 == 1 then
    context.expected = "modified"
    write(path, context.originals[slot] .. "-- scene edit " .. index .. "\n")
  else
    context.expected = "clean"
    write(path, context.originals[slot])
  end
end

function scene.action_ready(context)
  if status(context.target) ~= context.expected then return false end
  return true, support.basename(context.target) .. " " .. context.expected
end

function scene.state(context)
  return { last_status = context.target and status(context.target) or "" }
end

return scene
