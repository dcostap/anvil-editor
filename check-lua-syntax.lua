-- Syntax-check Lua files without executing them.
-- Usage: luajit check-lua-syntax.lua path/to/file.lua [...]

if not arg or #arg == 0 then
  io.stderr:write("usage: luajit check-lua-syntax.lua <file.lua> [...]\n")
  os.exit(2)
end

local ok = true

for i = 1, #arg do
  local file = arg[i]
  local chunk, err = loadfile(file)
  if not chunk then
    io.stderr:write(string.format("%s: %s\n", file, err))
    ok = false
  end
end

if not ok then os.exit(1) end
