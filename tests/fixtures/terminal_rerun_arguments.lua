local file = assert(io.open(arg[1], "wb"))
for index = 2, #arg do file:write(#arg[index], ":", arg[index], "\n") end
file:close()
