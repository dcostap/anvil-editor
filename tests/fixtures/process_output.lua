io.stdout:setvbuf("no")
io.stderr:setvbuf("no")
for _ = 1, 48 do
  io.stdout:write(string.rep("out!", 1024))
  io.stderr:write(string.rep("err!", 1024))
end
local marker = assert(io.open(assert(os.getenv("ANVIL_PROCESS_OUTPUT_MARKER")), "wb"))
marker:write("complete")
marker:close()
