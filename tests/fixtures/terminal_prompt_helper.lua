io.stdout:setvbuf("no")
print("PROMPT_HELPER_READY")
local ffi = require "ffi"
ffi.cdef [[void __stdcall Sleep(unsigned long milliseconds);]]
ffi.load("kernel32").Sleep(15000)
