local core = require "core"
local runtime = require "core.control_runtime"
local Dialog = require("core.ui.dialog").Dialog
local layout = require "core.ui.layout"
local Button = require "core.ui.button"
local StatusDot = require "core.ui.status_dot"

local Column, Row, Text = layout.Column, layout.Row, layout.Text
local ControlDialog = Dialog:extend()
local states = {
  starting = { "Starting", "info" },
  ready = { "Ready", "success" },
  disabled = { "Disabled", "neutral" },
  unavailable = { "Unavailable", "danger" },
}

local function field(label, value)
  return Column { gap = 4, Text { text = label, role = "label" }, value }
end

-- The setup names a stdio bridge, not the endpoint. The bridge reads the discovery file for each request, so the
-- config stays correct after a restart and holds no token.
local function copy_setup()
  local state = runtime.status()
  if state ~= "ready" then return end
  local server = {command = "node", args = {DATADIR .. PATHSEP .. "tools" .. PATHSEP .. "agent-sessions" .. PATHSEP .. "anvil-mcp.cjs",
    "--userdir", system.absolute_path(USERDIR) or USERDIR, "--project", core.root_project().path}}
  system.set_clipboard(table.concat({
    "Connect this agent to Anvil on this computer as an External Agent named `agy`.",
    "1. Add this `anvil` server to this agent's MCP config, such as Antigravity's `mcp_config.json`. Keep all other entries:",
    require("core.json").encode {mcpServers = {anvil = server}},
    "2. Reload the MCP servers. Verify the connection by calling Anvil's `workspace_state` tool.",
    "3. Add this rule to this agent's global rules:",
    "You are the External Agent `agy` in Anvil. Between your other steps, and whenever you are idle, call Anvil's "
      .. "`external_agent` tool with action=wait and agent=agy; then call it again with after=cursor. Treat each "
      .. "message as a request from the user or from another agent. Answer with action=say and reply_to set to its "
      .. "request. To ask a Pi in Anvil, use agent_send with from_agent=agy; its answer arrives through wait. "
      .. "If your MCP client stops a wait for taking too long, pass a smaller timeout_ms.",
  }, "\n"))
  core.log_quiet("Copied MCP agent setup")
end

function ControlDialog:new()
  ControlDialog.super.new(self, { title = "MCP Server" })
  self.status = StatusDot {}
  self.reason = Text { role = "description" }
  self.project = Text { text = core.root_project().path, wrap = false, cut = "start" }
  self.url = Text { wrap = false }
  self.discovery = Text { wrap = false, cut = "start" }
  self.endpoint_fields = Column {
    field("MCP URL", self.url),
    field("Discovery File", self.discovery),
  }
  self.copy = Button { label = "Copy Agent Setup", kind = "primary", on_click = copy_setup }
  self:set_body(Column {
    Column { gap = 4, self.status, self.reason },
    field("Project", self.project),
    self.endpoint_fields,
  })
  self.footer = Row { justify = "end", self.copy }
  self:on_update()
end

function ControlDialog:on_update()
  local state, url, path, reason = runtime.status()
  if state == self.state and path == self.path and reason == self.failure then return end
  self.state, self.path, self.failure = state, path, reason
  local appearance = states[state]
  self.status:set(appearance[2], appearance[1])
  self.reason:set_text(reason or "")
  self.reason.visible = reason ~= nil
  self.url:set_text(url and url .. "/mcp" or "")
  self.discovery:set_text(path or "")
  self.endpoint_fields.visible = state == "ready"
  self.copy.enabled = state == "ready"
  core.redraw = true
end

return ControlDialog
