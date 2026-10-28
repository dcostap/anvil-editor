# Debug a Windows release

The standalone GitHub release writes logs. You do not need a source build to collect evidence.

Older releases can have fewer diagnostics than the current source.

## Collect evidence

1. Record the Anvil release version, Windows version, and keyboard layout.
2. Record whether the PC uses Remote Desktop or a virtual machine.
3. Reproduce one issue at a time. Note the time and the focused View.
4. Copy the recent session logs and native logs from all Anvil processes.

Anvil normally writes logs to `%USERPROFILE%\.config\anvil\logs`.

If a `user` folder exists beside `anvil.exe`, Anvil uses `<exe folder>\user\logs` instead.

Without that adjacent folder, `ANVIL_USERDIR` takes priority over `XDG_CONFIG_HOME\anvil`, which takes priority over the normal location.

Native logs have names such as `anvil-<date>-<time>-p<pid>-native.log`. The shell, Projects, and Sidebar use separate processes. Collect their logs together.

Check logs before sharing them. They can contain paths, command names, and keyboard events. Key codes can reveal typed text.

## Diagnose D3D11

Search the native logs for these terms:

```text
D3D11
hr=0x
software
```

The current code logs the selected adapter, failure reasons, and Windows error codes for some failures.

Distinguish these paths:

- **WARP:** D3D11 runs on the CPU.
- **Software renderer:** Anvil falls back from D3D11.

Use the exact log message to identify the path. Do not assume that the GPU lacks support.

Run this command in PowerShell to collect GPU and driver details:

```powershell
Get-CimInstance Win32_VideoController |
  Select-Object Name, DriverVersion, DriverDate, Status |
  Format-List
```

Save the evidence before changing drivers or renderer settings.

For a temporary workaround, close Anvil normally. Then start it from PowerShell with the software renderer:

```powershell
$env:ANVIL_RENDERER = 'software'
& 'C:\path\to\anvil.exe'
```

This setting applies to applications started from that PowerShell process. It does not change Windows settings. Close Anvil before testing another renderer. A launch can otherwise reach an existing instance.

## Diagnose shortcuts

Compare the same shortcut on both PCs, in the same View, with the same keyboard layout.

Fully exit AutoHotkey on the working PC and repeat the test. A local script can make a shortcut work there. On the other PC, a remapper or another application can change or block input.

The current bundled defaults bind `Ctrl+Shift+A` to the Command Palette. That default does not require AutoHotkey. User bindings can differ.

If the Command Palette is accessible, run this command:

```text
core:keyboard_input_checker_gui
```

The Keyboard Input Checker shows received keys, modifiers, and text without running editor commands. Compare its results on both PCs.

Search the logs for `Input trace:`. Use the following evidence to choose the next check:

| Evidence | Next check |
| --- | --- |
| Wrong key or modifiers | Keyboard layout, remapping, or input translation |
| Correct combination reaches Lua | Bindings, focus, modal input, or command availability |
| No matching input records | Possible interception or focus problem; absence alone does not prove either |

Anvil does not install a global keyboard hook. Its logs cannot identify another application that blocks a key. Trace buffers can also overflow.

See [Keyboard input trace](INPUT_TRACE.md) for stages and limits.

## Use a coding agent on the affected PC

Give the agent the collected logs and source matching the installed release tag. Log inspection does not need build tools. Native breakpoints need a separate build with debug information.

Start with this instruction:

> Diagnose these issues without changing settings or files. Identify the D3D11 failure and error code. Trace the failed shortcut through the input logs. Separate confirmed facts from hypotheses. Ask before changing drivers, configuration, or application files.

Include the reproduction steps, times, GPU details, release version, keyboard layout, and relevant AutoHotkey bindings.
