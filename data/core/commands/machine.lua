local core = require "core"
local command = require "core.command"
local MachineClient = require "core.machine_client"

local function parse_address(text)
  local host, port = text:match("^%s*([^%s:]+):(%d+)%s*$")
  return host, tonumber(port)
end

command.add(nil, {
  -- On the Machine, `anvil machine code full` prints the pairing code and the port.
  ["machine:pair"] = function()
    core.global_prompt_bar:enter("Machine address (host:port)", {
      validate = function(text) return parse_address(text) ~= nil end,
      submit = function(address)
        local host, port = parse_address(address)
        core.global_prompt_bar:enter("Pairing code", {
          submit = function(code)
            local name = os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "Anvil"
            MachineClient.pair(host, port, code:match("^%s*(.-)%s*$"), name, function(err)
              if err then return core.error("Pairing with %s failed: %s", address, err.message or err.code) end
              core.log("Paired with the Machine at %s", address)
            end)
          end,
        })
      end,
    })
  end,
})
