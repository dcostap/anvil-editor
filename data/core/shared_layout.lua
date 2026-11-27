-- Only named editors in the Project and existing Terminal Sessions cross the Machine boundary.
local common = require "core.common"
local core = require "core"
local Editor = require "core.editor"
local panes = require "core.panes"
local fs = require "core.fs"
local M = {}
local function fingerprint(state) return common.serialize(state, {sort = true}) end

local function contents(v, root)
  local item
  if v.terminal_view and v.session_id then item = {terminal=v.session_id}
  elseif v:is(Editor) and v.buffer.abs_filename and common.path_belongs_to(v.buffer.abs_filename, root) then
    item = {file=common.relative_path(root,v.buffer.abs_filename)}
  end
  return item
end

local function describe(pane, root, assign)
  local v = pane.current_view
  local item = contents(v,root)
  if item then
    if assign and not pane.shared_id and not pane.legacy_layout then pane.shared_id = require("net").random_token():sub(1,32) end
    item.pane = pane.shared_id
    if assign and item.pane and v.terminal_view then v:bind_shared_pane(item.pane) end
    return item
  end
end

local function capture(root, assign)
  local result, index, identified = {groups={}, active=0}, 0, true
  local function tree(node)
    if node.pane then
      local leaf = describe(node.pane, root, assign)
      if leaf then
        if not leaf.pane then identified = false end
        index = index+1
        if node.pane == panes.active() then result.active = index end
      end
      return leaf
    end
    local a, b = tree(node.a), tree(node.b)
    if not a or not b then return a or b end
    return {axis=node.axis, ratio=node.ratio, a=a, b=b}
  end
  for _, g in ipairs(panes.groups) do
    if not g.snoozed then result.groups[#result.groups+1] = tree(g.root) end
  end
  return result, identified
end

function M.capture(root) return (capture(root,true)) end

local function key(item)
  return item.file and "file:" .. common.path_compare_key(item.file) or "terminal:" .. item.terminal
end

function M.apply(root, state)
  -- Changing the active Pane does not replace groups or change any View's local navigation state.
  local current, identified = capture(root,false)
  if identified and fingerprint(current.groups) == fingerprint(state.groups) then
    if state.active ~= 0 and current.active ~= state.active then
      local index = 0
      for _, p in ipairs(panes.ordered()) do
        if not p.group.snoozed and describe(p, root) then
          index = index + 1
          if index == state.active then panes.focus(p); break end
        end
      end
    end
    return true
  end
  local available, used, leaves, obsolete = {}, {}, {}, {}
  local by_id = {}
  for _, p in ipairs(panes.ordered()) do
    local item = describe(p,root)
    if p.shared_id then by_id[p.shared_id] = p end
    if item and not p.group.snoozed then
      local k = key(item)
      available[k] = available[k] or {}
      table.insert(available[k],p)
    end
  end
  local terminal = require "plugins.terminal"
  local function collect(n)
    if n.axis then
      local ok,why = collect(n.a)
      if not ok then return false,why end
      return collect(n.b)
    end
    if n.file and (type(n.file) ~= "string" or n.file:find("[%c:]") or common.is_absolute_path(n.file)
        or not common.path_belongs_to(common.normalize_path(root .. PATHSEP .. n.file),root)) then return false,"invalid file" end
    local q = available[key(n)]
    local p = by_id[n.pane]
    if not p and q then
      for _, candidate in ipairs(q) do
        if not used[candidate] and (not n.pane or not candidate.shared_id) then
          p = candidate; break
        end
      end
    end
    local view
    if p then
      if used[p] then return false,"duplicate Pane" end
      used[p] = true
      local current_item = describe(p,root)
      if current_item and key(current_item) == key(n) then view = p.current_view
      else
        if not current_item or panes.constraint(p) then return false,"local View owns the Pane" end
        for _,v in ipairs(panes.views(p)) do
          local item = contents(v,root)
          if item and key(item) == key(n) then view = v; break end
        end
        if p.current_view.can_open_view and not p.current_view:can_open_view(view or {}) then
          return false,"local View owns the Pane"
        end
      end
    end
    if not view and n.terminal and not terminal.session_available(n.terminal,root) then return false,"Terminal unavailable" end
    leaves[#leaves+1] = {item=n, pane=p, view=view}
    return true
  end
  for _, tree in ipairs(state.groups) do
    local ok,why = collect(tree)
    if not ok then return false,why end
  end
  for _, q in pairs(available) do
    for _, p in ipairs(q) do
      if not used[p] then
        for _, v in ipairs(panes.views(p)) do
          if v.buffer and v.buffer.is_dirty and v.buffer:is_dirty() then return false,"unsaved edits" end
          if not v:is(Editor) and not v.terminal_view and v.can_close then return false,"local View in Pane history" end
        end
        obsolete[#obsolete+1] = p
      end
    end
  end
  -- Keep surviving Views intact. Removing a mirrored Terminal releases this View, not another user's shell.
  for _,leaf in ipairs(leaves) do
    if leaf.pane and leaf.pane.group.snoozed and not require("core.snoozed_panes").allow_shared_wake(leaf.pane,root) then
      return false,"waiting for Sidebar Snooze removal"
    end
  end
  for _, leaf in ipairs(leaves) do
    local item, view = leaf.item, leaf.view
    if not view then
      view = item.terminal and terminal.TerminalView {session_id=item.terminal,shared_id=item.pane}
        or Editor(core.open_buffer(root .. PATHSEP .. item.file))
    end
    if not leaf.pane then leaf.pane = assert(panes.create {focus=false,factory=function() return view end})
    elseif leaf.pane.current_view ~= view then
      assert(panes.present(view,{pane=leaf.pane,focus=false,reuse=true,keep_history=true}) == leaf.pane)
    end
    leaf.pane.legacy_layout = not item.pane
    leaf.pane.shared_id = item.pane
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
          if incoming and incoming.layout and (not revision or incoming.revision > revision) then
            local ok,why = M.apply(root,incoming.layout)
            if ok then revision,baseline,blocked=incoming.revision,fingerprint(M.capture(root)),nil
            elseif why ~= blocked then
              blocked=why
              if why == "unsaved edits" then core.log("Layout sync paused. Save your edits before applying a remote close.") end
            end
          elseif owner or revision then
            local state = M.capture(root)
            local now = fingerprint(state)
            if (owner and observed == 0 and not revision or baseline and baseline ~= now) and client.level == "full" then
              local e,r=request("layout.set",{base=revision or 0,layout=state})
              if not e then revision,baseline=r.revision,now
              elseif e.code ~= "conflict" and blocked ~= e.code then
                blocked=e.code
                core.log_quiet("Layout update refused: %s", tostring(e.message or e.code))
              end
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
