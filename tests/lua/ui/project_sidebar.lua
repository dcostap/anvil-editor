local core = require "core"
local test = require "core.test"

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
end)
