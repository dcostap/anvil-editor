local core = require "core"
local test = require "core.test"

-- End the isolated startup Terminal without a shutdown dialog.
require("core.storage").save("plugins.terminal", "quit_choice", "end")

-- Seam: asynchronous snapshots at the native Window event boundary.
test.describe("Project Sidebar snapshots", function()
  local saved, offsets
  test.before_each(function()
    saved = {hosted = system.is_hosted_surface, query = system.request_project_sidebar,
      model = core.project_sidebar, request = core.project_sidebar_request}
    offsets = {}
    system.is_hosted_surface = function() return true end
    system.request_project_sidebar = function(offset) offsets[#offsets + 1] = offset; return true end
    core.project_sidebar, core.project_sidebar_request = nil, nil
  end)
  test.after_each(function()
    system.is_hosted_surface, system.request_project_sidebar = saved.hosted, saved.query
    core.project_sidebar, core.project_sidebar_request = saved.model, saved.request
  end)
  test.it("publishes complete pages with their Project and Terminal state", function()
    test.ok(core.request_project_sidebar())
    core.on_event("projectsidebar", [[return {revision=4,offset=0,next=1,total=2,items={
      {kind="project",row_id=7,path="C:/λ/quoted\"",state="dormant",selected=false,close_choice=false,deferred_dialog=true}
    }}]])
    test.equal(core.project_sidebar, nil, "A partial page reached the caller")
    test.equal(offsets[#offsets], 1)
    core.on_event("projectsidebar", [[return {revision=4,offset=1,next=2,total=2,status_limited=true,items={
      {kind="terminal",row_id=7,id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",state="running",busy=1,attached=false,cwd="C:/λ",title="cmd"}
    }}]])
    test.equal(#core.project_sidebar, 1)
    local project = core.project_sidebar[1]
    test.equal(project.path, 'C:/λ/quoted"')
    test.equal(project.state, "dormant")
    test.ok(project.deferred_dialog)
    test.equal(#project.terminals, 1)
    test.equal(project.terminals[1].busy, 1)
    test.not_ok(project.terminals[1].attached)
    test.ok(core.project_sidebar.status_limited)
  end)
  test.it("reads each loaded Project's Pane report and ignores a broken one", function()
    test.ok(core.request_project_sidebar())
    core.on_event("projectsidebar", [[return {revision=1,offset=0,next=2,total=2,items={
      {kind="project",row_id=1,path="C:/A",state="ready",panes="{active=1,visible=1,{id=\034pane-1\034,number=1,group=1,name=\034a.lua\034}}"},
      {kind="project",row_id=2,path="C:/B",state="ready",panes="{broken"}
    }}]])
    local a, b = core.project_sidebar[1], core.project_sidebar[2]
    test.equal(a.panes.active, 1)
    test.equal(a.panes[1].name, "a.lua")
    test.equal(#b.panes, 0)
  end)
  test.it("does not combine pages from different model revisions", function()
    test.ok(core.request_project_sidebar())
    core.on_event("projectsidebar", [[return {revision=1,offset=0,next=1,total=2,items={
      {kind="project",row_id=1,path="C:/old",state="ready"}
    }}]])
    core.on_event("projectsidebar", [[return {revision=2,offset=1,next=2,total=2,items={
      {kind="project",row_id=2,path="C:/new",state="ready"}
    }}]])
    test.equal(core.project_sidebar, nil)
    test.equal(offsets[#offsets], 0)
    core.on_event("projectsidebar", [[return {revision=2,offset=0,next=1,total=1,items={
      {kind="project",row_id=2,path="C:/new",state="ready"}
    }}]])
    test.equal(#core.project_sidebar, 1)
    test.equal(core.project_sidebar[1].path, "C:/new")
  end)
  test.it("focuses a new Pending Pane without a keyboard focus change", function()
    local numbered = require "core.numbered_panes"
    local function reply(state, revision)
      core.on_event("projectsidebar", string.format([[return {revision=%d,offset=0,next=2,total=2,items={
        {kind="project",row_id=1,path="C:/pending-sidebar-test",state="ready",
          panes="{{id='result',terminal={session='pending-sidebar-test',state='running'}}}"},
        {kind="terminal",row_id=1,id="pending-sidebar-test",state="running",agent_state=%q,agent_since=%d}
      }}]], revision, state, os.time() + 1))
    end
    test.ok(core.request_project_sidebar())
    reply("working", 1)
    test.is_nil(numbered.target(core.project_sidebar, 1, {}))

    core.on_event("projectsidebarchanged")
    reply("done", 2)
    test.equal((numbered.target(core.project_sidebar, 1, {}) or {}).id, "result",
      "A new result did not become a Pending Pane")

    local saved_request, request = system.pane_request
    system.pane_request = function(route, path, text)
      request = {route = route, path = path, action = assert(loadstring("return " .. text))()}
      return true
    end
    local ok, err = pcall(function()
      test.ok(require("core.command").perform("pane:focus_number_1"))
      test.same(request, {route = "select", path = "C:/pending-sidebar-test",
        action = {action = "focus", pane = "result"}})
    end)
    system.pane_request = saved_request
    test.ok(ok, err)
  end)
  test.it("publishes changed recent Projects but not an unchanged source", function()
    local recents, publish = core.recent_projects, system.publish_project_sidebar
    local sources = {}
    system.publish_project_sidebar = function(_, text) sources[#sources + 1] = assert(loadstring("return " .. text))(); return true end
    local ok, err = pcall(function()
      core.set_recent_projects({"C:/Newest", "C:/Older"})
      test.equal(sources[#sources][1], "C:/Newest")
      local count = #sources
      core.publish_project_sidebar()
      test.equal(#sources, count)
      core.set_recent_projects({"C:/Newest", "C:/Changed"})
      test.equal(sources[#sources][2], "C:/Changed")
    end)
    core.recent_projects, system.publish_project_sidebar = recents, publish
    if not ok then error(err) end
  end)
end)
