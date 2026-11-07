# Keyboard input trace

Anvil records keyboard diagnostics in the normal session logs:

`C:\Projects\c_projects\anvil-portable\user\logs\anvil-*.log`

The trace runs by default. Search for `Input trace:`.

## Stages

- `native ... win32`: The editor window received a Windows keyboard or focus message.
- `native ... sdl stage=queued`: SDL delivered a key to Anvil's event queue.
- `native ... sdl stage=polled`: Lua's event poll removed the key from the queue.
- `native ... sdl stage=flushed`: A focus reset discarded the queued key.
- `native ... sdl stage=dropped-full`: The event queue could not accept the key.
- `lua received`: The Lua event handler received the key.
- `lua route`: The handler chose the modal owner, keymap, View, or IME rejection.
- `keymap` and `picker`: The command result shows whether its predicate accepted the action.
- `picker activate`: The selected result identifies the requested file and line.

Native records include a sequence number, capture time, and thread ID.
SDL records include the event time, window ID, key code, scancode, modifiers, and repeat flag.
Lua records include the active View, modal owner, held modifiers, and IME state.
Windows records include focus handles and current Ctrl, Shift, Alt, and R key states.

Native callbacks store records in a bounded memory buffer. Lua writes them during event processing.
`trace-overflow` reports lost trace records. Do not treat those gaps as missing input.
Log line order can differ from capture order. Use native capture times and sequence numbers.

Text-input and IME records include byte counts, not text. Their queue stages show receipt, polling, and discarded events.
`hosted input rejected reason=configuration` records an input packet whose configuration differs from the Project's current configuration. It includes both versions, the event type, and the byte count. Mouse motion rejections are not logged.

## Shell input state

The shell's normal native log records `Shell input state` on focus changes, Sidebar focus changes, and clicks. It also records the first key and first text event after a focus change, click, or text-input state change. Other keys and text events only increase counters. There is no polling timer for these records.

Each snapshot names the Window, selected Project, connection, Project state, Sidebar focus, and Sidebar popup state. It gives Windows foreground and keyboard focus, SDL focus, the Project's requested text-input state, and SDL's actual state. Modifier fields show the Windows thread state, SDL state, and the event's state.

The counters are cumulative for each Window. `native_keys` counts `WM_KEYDOWN` and `WM_SYSKEYDOWN`; `native_chars` counts `WM_CHAR` and `WM_SYSCHAR`. Native callbacks only increase these counters. `sdl_keys` counts SDL key-down events; `sdl_texts` counts SDL text-input events. Compare successive snapshots, not the absolute counts. One native character message does not necessarily equal one SDL text event. Alt Navigation can also replace an SDL key with several forwarded events.

`Shell focus send` records an attempted focus notification to a Project or Sidebar. Receipt still needs the Project's focus event. `Shell text input` records a changed state or failed start/stop, with its reason, requested state, actual state, and result. A rejected configuration has a separate record. Input with no ready or connected destination gets a `drop-` reason.

Project diagnostics label their hidden native window as `window_role=hosted-hidden`. Its native focus flags do not describe the visible shell Window. Use the shell snapshots for that Window. Focus comparisons exclude unrelated Windows error state.

## Limits

Detailed `native ... win32` records cover direct editor windows. Shell Windows use the snapshots and counters above.
Shell snapshots do not trace every key through every stage. They can show where input counts stop, but not identify each missing key.
The trace does not install a global keyboard hook. It cannot identify another program that blocks a key.
It records key codes, but not text-input or IME text payloads. Key codes can still reveal typed text.
Check logs for sensitive data before sharing them.
