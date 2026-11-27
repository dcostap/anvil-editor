-- Only named editors in the Project and existing Terminal Sessions cross the Machine boundary.
local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local panes = require "core.panes"
local fs = require "core.fs"
local M = {}
local function fingerprint(state) return common.serialize(state, {sort = true}) end

local function describe(pane, root)
  local v = pane.current_view
  if pane.group.snoozed then return end
  local item
  if v.terminal_view and v.session_id then item = {terminal=v.session_id}
  elseif v:is(Editor) and v.buffer.abs_filename and common.path_belongs_to(v.buffer.abs_filename, root) then
    item = {file=common.relative_path(root,v.buffer.abs_filename)}
  end
  if item then
    pane.shared_id = pane.shared_id or require("net").random_token():sub(1,32)
    item.pane = pane.shared_id
    if v.terminal_view then v:bind_shared_pane(item.pane) end
    return item
  end
end

function M.capture(root)
  local result, index = {groups={}, active=0}, 0
  local function tree(node)
    if node.pane then
      local leaf = describe(node.pane, root)
      if leaf then
        index = index+1
        if node.pane == panes.active() then result.active = index end
      end
      return leaf
    end
    local a, b = tree(node.a), tree(node.b)
    if not a or not b then return a or b end
    return {axis=node.axis, ratio=node.ratio, a=a, b=b}
  end
  for _, g in ipairs(panes.groups) do result.groups[#result.groups+1] = tree(g.root) end
  return result
end

local function key(item)
  return item.file and "file:" .. common.path_compare_key(item.file) or "terminal:" .. item.terminal
end

function M.apply(root, state)
  -- Changing the active Pane does not replace groups or change any View's local navigation state.
  local current = M.capture(root)
  if fingerprint(current.groups) == fingerprint(state.groups) then
    if state.active ~= 0 and current.active ~= state.active then
      local index = 0
      for _, p in ipairs(panes.ordered()) do
        if describe(p, root) then
          index = index + 1
          if index == state.active then panes.focus(p); break end
        end
      end
    end
    return true
  end
  local available, used, leaves, obsolete = {}, {}, {}, {}
  for _, p in ipairs(panes.ordered()) do
    local item = describe(p,root)
    if item then
      local k = key(item)
      available[k] = available[k] or {}
      table.insert(available[k],p)
    end
  end
  local terminal = require "plugins.terminal"
  local function collect(n)
    if n.axis then return collect(n.a) and collect(n.b) end
    if n.file and (type(n.file) ~= "string" or n.file:find("[%c:]") or common.is_absolute_path(n.file)
        or not common.path_belongs_to(common.normalize_path(root .. PATHSEP .. n.file),root)) then return false end
    local q = available[key(n)]
    local p
    if q then
      for i, candidate in ipairs(q) do
        if not n.pane or n.pane == candidate.shared_id then p = table.remove(q,i); break end
      end
    end
    if not p and n.terminal and not terminal.session_available(n.terminal,root) then return false end
    leaves[#leaves+1] = {item=n, pane=p}
    return true
  end
  for _, tree in ipairs(state.groups) do if not collect(tree) then return false,"Terminal unavailable" end end
  for _, q in pairs(available) do
    for _, p in ipairs(q) do
      for _, v in ipairs(panes.views(p)) do
        if v.buffer and v.buffer.is_dirty and v.buffer:is_dirty() then return false,"unsaved edits" end
        if not v:is(Editor) and not v.terminal_view and v.can_close then return false,"local View in Pane history" end
      end
      obsolete[#obsolete+1] = p
    end
  end
  -- Keep surviving Views intact. Removing a mirrored Terminal releases this View, not another user's shell.
  for _, leaf in ipairs(leaves) do
    if not leaf.pane then
      local item = leaf.item
      leaf.pane = assert(panes.create {focus=false, factory=function()
        if item.terminal then return terminal.TerminalView {session_id=item.terminal} end
        return Editor(core.open_buffer(root .. PATHSEP .. item.file))
      end})
    end
    leaf.pane.shared_id = leaf.item.pane or leaf.pane.shared_id
    used[leaf.pane] = true
  end
  for _, p in ipairs(obsolete) do
    for _, v in ipairs(panes.views(p)) do
      if v.terminal_view then
        v:detach_session()
      end
    end
    panes.close(p,{force=true})
  end
  local index = 0
  local function tree(n)
    if n.axis then return {kind="split",axis=n.axis,ratio=n.ratio,a=tree(n.a),b=tree(n.b)} end
    index=index+1
    return {kind="pane",pane_id=leaves[index].pane.id}
  end
  local trees = {}
  for i,n in ipairs(state.groups) do trees[i]=tree(n) end
  panes.arrange_shared(trees,leaves[state.active] and leaves[state.active].pane,used)
  return true
end

function M.start(root)
  local client = fs.machine
  local owner = not client
  if owner then
    local path = USERDIR .. "/machine/server.json"
    client = require("core.machine_client").new(path)
  end
  local function request(name,params)
    local done, err, result
    params.project=root
    if #require("core.json").encode(params) > 60000 then
      return {code="too_large", message="Layout exceeds the Machine request limit"}
    end
    client:request(name,params,nil,function(e,r) done,err,result=true,e,r end)
    while not done do coroutine.yield(.01) end
    return err,result
  end
  core.add_thread(function()
    local revision, connections, baseline, blocked, pending, incoming, observed
    while core.workspace_restored and core.root_project() and core.root_project().path == root and (owner or client == fs.machine) do
      if client.state == "ready" then
        local supported = false
        for _, method in ipairs(client.features or {}) do if method == "layout.get" then supported=true; break end end
        if not supported then break end
        if connections ~= client.connections then
          revision,baseline,pending,incoming,observed=nil,nil,nil,nil,nil
          connections=client.connections
        end
        if not pending then
          local generation = connections
          pending=true
          client:request("layout.get", {project=root,known=observed,wait=observed ~= nil}, nil, function(err,r)
            if generation ~= connections then return end
            pending=false
            if err then
              if err.code == "outside_project" then observed=false end
            else observed,incoming=r.revision,r end
          end)
        end
        if observed == false then break end
        if observed ~= nil then
          local state = M.capture(root)
          local now = fingerprint(state)
          if incoming and incoming.layout and (not revision or incoming.revision > revision) then
            local ok,why = true,nil
            if fingerprint(incoming.layout) ~= now then ok,why = M.apply(root,incoming.layout) end
            if ok then revision,baseline,blocked=incoming.revision,fingerprint(M.capture(root)),nil
            elseif why ~= blocked then
              blocked=why
              if why == "unsaved edits" then core.log("Layout sync paused. Save your edits before applying a remote close.") end
            end
          elseif (owner and observed == 0 and not revision or baseline and baseline ~= now) and client.level == "full" then
            local e,r=request("layout.set",{base=revision or 0,layout=state})
            if not e then revision,baseline=r.revision,now
            elseif e.code ~= "conflict" and blocked ~= e.code then
              blocked=e.code
              core.log_quiet("Layout update refused: %s", tostring(e.message or e.code))
            end
          end
        end
      end
      coroutine.yield(.25)
    end
    if owner then client:close() end
  end)
end
return M
