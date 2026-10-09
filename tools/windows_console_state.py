"""Read console lock and display power state without changing either state."""
from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
import sys
import threading
import time
import uuid
from typing import Any

# A failed unregister must not release a callback Windows can still invoke.
_retained_subscriptions = []


def read_console_state() -> dict[str, Any]:
    state: dict[str, Any] = {"locked": None, "display_state": "unavailable"}
    if sys.platform != "win32":
        return {**state, "error": "Windows console state is unavailable", "sampled_at": time.time()}

    kernel = c.WinDLL("kernel32", use_last_error=True)
    wts = c.WinDLL("wtsapi32", use_last_error=True)
    power = c.WinDLL("powrprof", use_last_error=True)
    kernel.WTSGetActiveConsoleSessionId.argtypes = []
    kernel.WTSGetActiveConsoleSessionId.restype = w.DWORD
    session = kernel.WTSGetActiveConsoleSessionId()
    state["console_session_id"] = session

    class SessionHead(c.Structure):
        _fields_ = [("session_id", w.DWORD), ("session_state", c.c_int), ("flags", w.LONG)]

    class SessionData(c.Union):
        # WTSINFOEX_LEVEL1 has LARGE_INTEGER members and eight-byte alignment.
        _fields_ = [("head", SessionHead), ("alignment", c.c_int64)]

    class SessionInfo(c.Structure):
        _fields_ = [("level", w.DWORD), ("data", SessionData)]

    wts.WTSQuerySessionInformationW.argtypes = [
        w.HANDLE, w.DWORD, c.c_int, c.POINTER(c.c_void_p), c.POINTER(w.DWORD)]
    wts.WTSQuerySessionInformationW.restype = w.BOOL
    wts.WTSFreeMemory.argtypes = [c.c_void_p]
    wts.WTSFreeMemory.restype = None
    buffer = c.c_void_p()
    size = w.DWORD()
    if session != 0xffffffff and wts.WTSQuerySessionInformationW(None, session, 25, c.byref(buffer), c.byref(size)):
        try:
            if size.value >= SessionInfo.data.offset + c.sizeof(SessionHead):
                info = c.cast(buffer, c.POINTER(SessionInfo)).contents
                if info.level == 1 and info.data.head.session_id == session:
                    flags = info.data.head.flags
                    state["session_flags"] = flags
                    state["locked"] = {0: True, 1: False}.get(flags)
        finally:
            wts.WTSFreeMemory(buffer)
    else:
        state["lock_error"] = c.get_last_error()

    class GUID(c.Structure):
        _fields_ = [("bytes", c.c_ubyte * 16)]

    guid_bytes = uuid.UUID("6fe69556-704a-47a0-8f24-c28d936fda47").bytes_le
    guid = GUID((c.c_ubyte * 16).from_buffer_copy(guid_bytes))
    callback_type = c.WINFUNCTYPE(w.ULONG, c.c_void_p, w.ULONG, c.c_void_p)
    ready = threading.Event()

    @callback_type
    def callback(context, event_type, setting):
        if setting and event_type == 0x8013 and c.string_at(setting, 16) == guid_bytes:
            length = c.c_uint32.from_address(setting + 16).value
            if length == 4:
                value = c.c_uint32.from_address(setting + 20).value
                state["display_state"] = {0: "off", 1: "on", 2: "dimmed"}.get(value, "unavailable")
                ready.set()
        return 0

    class Subscription(c.Structure):
        _fields_ = [("callback", callback_type), ("context", c.c_void_p)]

    subscription = Subscription(callback, None)
    registration = w.HANDLE()
    power.PowerSettingRegisterNotification.argtypes = [
        c.POINTER(GUID), w.DWORD, c.c_void_p, c.POINTER(w.HANDLE)]
    power.PowerSettingRegisterNotification.restype = w.DWORD
    power.PowerSettingUnregisterNotification.argtypes = [w.HANDLE]
    power.PowerSettingUnregisterNotification.restype = w.DWORD
    # DEVICE_NOTIFY_CALLBACK supplies the current value immediately after registration.
    error = power.PowerSettingRegisterNotification(c.byref(guid), 2, c.byref(subscription), c.byref(registration))
    if error:
        state["display_error"] = error
    else:
        try:
            if not ready.wait(1):
                state["display_error"] = "Initial display notification timed out"
        finally:
            error = power.PowerSettingUnregisterNotification(registration)
            if error:
                _retained_subscriptions.append((subscription, power, registration))
                state["display_error"] = error
                state["display_state"] = "unavailable"
    state["display_source"] = "GUID_CONSOLE_DISPLAY_STATE"
    state["sampled_at"] = time.time()
    return dict(state)
