-- Connection choice belongs to the SQL Editor, not to the settings Dialog.
local core = require "core"
local common = require "core.common"
local panes = require "core.panes"
local M = {}

function M.choose(sql, view, done)
  sql.load()
  core.add_thread(function()
    local deadline = system.get_time() + 15
    while not sql.ready() and not sql.load_error and system.get_time() < deadline do coroutine.yield(0.01) end
    if view.closed or not panes.pane_for_view(view) or core.active_view ~= view then return end
    if not sql.ready() then core.error("%s", sql.load_error or "Database settings did not load."); return end
    if #sql.connections == 0 then
      require("plugins.sql_server.dialog").open()
      return
    end
    local entries = {}
    for i, c in ipairs(sql.connections) do
      local label = c.name .. " — " .. c.database .. " @ " .. c.server
      entries[i] = { text = label, id = c.id }
    end
    core.global_prompt_bar:enter("SQL Connection", {
      text = "",
      suggest = function(query)
        return common.fuzzy_match(entries, query)
      end,
      validate = function(_, item) return item ~= nil end,
      submit = function(_, item)
        if view.closed or not panes.pane_for_view(view) then return end
        if sql.bind(view.buffer, item.id) and done then done(sql.find(item.id)) end
      end,
    })
  end)
end

-- Enter or Connect connects. Closing the card connects nothing.
function M.password_prompt(c, done)
  local Dialog = require("core.ui.dialog").Dialog
  local layout = require "core.ui.layout"
  local TextField = require "core.ui.text_field"
  local Button = require "core.ui.button"
  local card = Dialog { title = c.name, width = 420 }
  local password = TextField { secret = true, grow = 1 }
  local function connect()
    local value = password:get_text()
    card:close()
    done(value)
  end
  card:set_body(layout.Column { layout.Field { title = "Password", stacked = true, control = password } })
  card.footer = layout.Row { justify = "end", Button { label = "Connect", kind = "primary", on_click = connect } }
  function card:confirm()
    if self.focused == password then connect(); return true end
    return Dialog.confirm(self)
  end
  function card:on_close() password:set_text("") end
  card:open(password)
  return card
end

function M.with_connection(sql, view, action)
  local buffer, revision = view.buffer, view.buffer.text_revision
  local a, b, c, d = buffer:get_selection()
  local function unchanged()
    local l1, c1, l2, c2 = buffer:get_selection()
    return not view.closed and panes.pane_for_view(view) and core.active_view == view
      and sql.is_sql(view) and buffer.text_revision == revision and a == l1 and b == c1 and c == l2 and d == c2
  end
  local function use(connection)
    if not unchanged() then return false end
    -- The first explicit action keeps the connection, also after the Project adds another.
    if not buffer.sql_connection_id then sql.bind(buffer, connection.id) end
    if connection.state == "Ready" then return action(connection) end
    local function connect(password)
      if not unchanged() then return end
      if connection.state ~= "Connecting" then sql.connect(connection.id, password) end
      local generation = connection.generation
      core.add_thread(function()
        local deadline = system.get_time() + 30
        while connection.state == "Connecting" and unchanged() and system.get_time() < deadline do coroutine.yield(0.01) end
        if not unchanged() or sql.connection_for(buffer) ~= connection or generation ~= connection.generation then return end
        if connection.state == "Ready" then action(connection)
        else core.error("%s", connection.error or "SQL connection is not ready.") end
      end)
    end
    if connection.integrated or connection.state == "Connecting" then connect()
    else M.password_prompt(connection, connect) end
    return true
  end
  local connection = sql.connection_for(buffer)
  if connection then return use(connection) end
  M.choose(sql, view, use)
  return true
end

return M
