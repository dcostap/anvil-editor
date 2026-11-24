local common = require "core.common"
local M = {}

-- Keep only layout fields. Never accept serialized Views, shell commands or Buffer contents.
local function checked(server, root, value)
  if type(value) ~= "table" or type(value.groups) ~= "table" then return end
  local count = 0
  local function node(n, depth)
    if type(n) ~= "table" or depth > 32 or count >= 128 then return end
    if n.file then
      if type(n.file) ~= "string" or common.is_absolute_path(n.file) then return end
      local path = server.check_path(root .. PATHSEP .. n.file)
      if not path or not common.path_belongs_to(path, root) then return end
      count = count + 1
      return {file = common.relative_path(root, path)}
    elseif n.terminal then
      if type(n.terminal) ~= "string" or #n.terminal ~= 32 or not n.terminal:match("^%x+$") then return end
      if PLATFORM ~= "Windows" or not require("core.serve_terminal").belongs_to(n.terminal, root) then return end
      count = count + 1
      return {terminal = n.terminal}
    elseif (n.axis == "x" or n.axis == "y") and type(n.ratio) == "number" and n.ratio > 0 and n.ratio < 1 then
      local a, b = node(n.a, depth+1), node(n.b, depth+1)
      if a and b then return {axis=n.axis, ratio=n.ratio, a=a, b=b} end
    end
  end
  local groups = {}
  for _, g in ipairs(value.groups) do
    local item = node(g, 0)
    if not item then return end
    groups[#groups+1] = item
  end
  local active = value.active
  if type(active) ~= "number" or active%1 ~= 0 or active < 0 or active > count then return end
  return {groups=groups, active=active}
end

function M.new(server)
  local states, waiting = {}, {}
  server.on_close(function(client) waiting[client] = nil end)
  local function exchange(client, id, p, write)
    local root = server.project_root(p.project)
    if not root then return server.fail(client,id,"outside_project","Unknown layout Project") end
    local state = states[root] or {revision=0}
    if write then
      if p.base ~= state.revision then return server.fail(client,id,"conflict","Layout has changed") end
      if state.revision == 0 and client.device then return server.fail(client,id,"not_ready","Open the Project on its host first") end
      local layout = checked(server,root,p.layout)
      if not layout then return server.fail(client,id,"invalid_layout","Invalid Machine layout") end
      state = {revision=state.revision+1, layout=layout}
      states[root] = state
      for reader, pending in pairs(waiting) do
        if pending.root == root then
          waiting[reader] = nil
          server.reply(reader,pending.id,{result=state})
        end
      end
    elseif p.wait and p.known == state.revision then
      -- One Machine connection can have several Project consumers. Never replace an unanswered call silently.
      if waiting[client] then return server.fail(client,id,"busy","Another layout read is pending") end
      waiting[client] = {id=id,root=root}
      return
    end
    server.reply(client,id,{result=(write or p.known == state.revision) and {revision=state.revision} or state})
  end
  return {["layout.get"]=function(c,id,p) exchange(c,id,p,false) end, ["layout.set"]=function(c,id,p) exchange(c,id,p,true) end}
end
return M
