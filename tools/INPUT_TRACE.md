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

## Limits

Windows records cover editor windows with the native frame handler, not the separate experimental shell window.
The trace does not install a global keyboard hook. It cannot identify another program that blocks a key.
It records key codes, but not text-input or IME text payloads. Key codes can still reveal typed text.
Check logs for sensitive data before sharing them.
