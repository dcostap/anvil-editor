# Visual Studio Code Integrated Terminal Source Audit

## Audit basis

This report reviews Visual Studio Code source, not public product documentation.

- Repository: [`microsoft/vscode`](https://github.com/microsoft/vscode)
- Branch at review time: `main`
- Commit: [`3aa54039a0bec1bd4f9b428cdb202b4271bf22ef`](https://github.com/microsoft/vscode/commit/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef)
- Commit date: 2026-08-29
- Commit subject: `Allow ZIP selection for manually installed dictation models (#332998)`
- xterm.js package: `@xterm/xterm` `6.1.0-beta.302`
- Headless xterm package: `@xterm/headless` `6.1.0-beta.301`
- node-pty package: `node-pty` `1.2.0-beta.15`
- Package evidence: [package.json lines 136-158](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/package.json#L136-L158)

I did not run the VS Code tests. This was a read-only source review.

VS Code calls detected targets “links.” Anvil calls link-like text a **Text Point of Interest**.

This report uses “link” only for VS Code source names and protocol terms.

## Executive summary

VS Code uses five main terminal layers.

1. `TerminalService` chooses location, profile, group, persistence, and active state.
2. `TerminalInstance` joins one terminal emulator to one process manager and one UI host.
3. `XtermTerminal` wraps xterm.js. It does not own the process.
4. `TerminalProcessManager` owns launch, input, resize, relaunch, and backend state.
5. A separate PTY host owns node-pty processes, replay data, and reconnect state.

The strongest lessons are not the large service graph.

The strongest lessons are small lifecycle rules:

- Keep emulator state separate from process state.
- Queue input until process readiness.
- Bound output and apply backpressure.
- Acknowledge output only after the emulator parses it.
- Drain final output before the exit event.
- Stop resize work before process teardown.
- Make disconnect, exit, failure, and close different states.
- Treat shell output as untrusted input.
- Put limits around path detection and remote file checks.
- Use a stable text surface for accessibility.
- Add quiet logs at every process boundary.

Anvil should not copy VS Code’s complete design.

Anvil already has a smaller base:

- `data/plugins/terminal.lua` owns a Terminal View.
- `src/api/terminal_native.c` owns Ghostty state and a ConPTY transport.
- Existing Panes, Tabs, Navigation History, and View Suspension own layout.
- Terminal Text Capture already provides a stable Text View.

The smallest robust model keeps this shape.

Anvil should first harden output drain, lifecycle state, resize, input routing, and diagnostics.

Anvil should then add validated file-location Text POIs and accessible capture behavior.

Anvil should defer PTY host isolation until native faults justify it.

Anvil should not add terminal-specific tabs, split groups, extension PTYs, or remote backends.

## Architecture and data flow

### VS Code object graph

```text
TerminalViewPane / TerminalEditor
              |
       TerminalService
        /           \
TerminalGroup    TerminalEditorService
        \           /
          TerminalInstance
          /              \
 XtermTerminal       TerminalProcessManager
      |                       |
 xterm.js             ITerminalBackend
                              |
                    LocalTerminalBackend
                              |
                         LocalPty proxy
                              |
                  separate PTY host process
                              |
                         PtyService
                              |
                PersistentTerminalProcess
                     /                 \
             TerminalProcess       XtermSerializer
                    |                    |
                 node-pty          @xterm/headless
```

### Input path

```text
keyboard or paste
  -> xterm.js input encoder
  -> xterm.onData / onBinary
  -> TerminalProcessManager.write
  -> LocalPty IPC proxy
  -> PtyService.input
  -> PersistentTerminalProcess.input
  -> TerminalProcess.input
  -> node-pty.write
```

`TerminalInstance` intercepts editor commands before xterm receives keys.

The custom key handler also protects chords, focus traversal, and operating-system keys.

Input that arrives before process readiness goes into a small prelaunch queue.

Programmatic text uses a separate path. It normalizes line endings and can use bracketed paste.

Sources: [TerminalInstance input wiring](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L807-L935), [key routing](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L1149-L1210), and [programmatic send](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L1396-L1418).

### Output path

```text
node-pty.onData
  -> TerminalProcess flow counter
  -> PTY host data buffer
  -> IPC event
  -> TerminalProcessManager filters
  -> xterm.write(data, parsedCallback)
  -> parsed callback sends character acknowledgement
  -> node-pty resumes below the low watermark
```

The high watermark is 100,000 unacknowledged characters.

The low watermark is 5,000 characters. The client batches acknowledgements in 5,000-character units.

Sources: [flow constants](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/common/terminal.ts#L876-L898), [node-pty pause and resume](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/terminalProcess.ts#L326-L352), and [parse acknowledgement](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L1700-L1708).

Anvil does not need an IPC acknowledgement protocol for its current in-process design.

Its native read queue must still stay bounded. The producer must wait when that queue is full.

### Resize path

```text
View layout
  -> measured character grid
  -> TerminalResizeDebouncer
  -> xterm.resize
  -> TerminalProcessManager.setDimensions
  -> PTY host
  -> node-pty.resize
```

VS Code rejects zero-sized layouts and unchanged sizes.

It updates rows quickly. It delays expensive horizontal reflow for large buffers.

Hidden terminals resize during an idle callback. Visibility flushes pending resize work.

Source: [TerminalResizeDebouncer](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalResizeDebouncer.ts#L14-L105).

## Source map

All paths below belong to commit `3aa54039a0bec1bd4f9b428cdb202b4271bf22ef`.

| Ref | Upstream source | Main responsibility |
|---|---|---|
| S1 | [`terminalView.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalView.ts#L70-L330) | Panel host, startup, welcome state, action bar |
| S2 | [`terminalTabbedView.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalTabbedView.ts#L43-L354) | Terminal tab list and group container |
| S3 | [`terminalService.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalService.ts#L66-L206) | Global terminal model and lifecycle |
| S4 | [`terminalInstance.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L140-L230) | One UI terminal instance |
| S5 | [`terminalGroup.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalGroup.ts#L243-L430) | One terminal tab with split terminal panes |
| S6 | [`terminalEditorService.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalEditorService.ts#L26-L300) | Terminal editors in editor groups |
| S7 | [`xtermTerminal.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/xterm/xtermTerminal.ts#L124-L390) | xterm.js wrapper and addons |
| S8 | [`terminalProcessManager.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalProcessManager.ts#L74-L230) | Process creation, relaunch, I/O, and backend state |
| S9 | [`localTerminalBackend.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/electron-browser/localTerminalBackend.ts#L58-L242) | Renderer-to-PTY-host proxy and local restore |
| S10 | [`localPty.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/electron-browser/localPty.ts#L10-L96) | Per-process IPC adapter |
| S11 | [`ptyHostService.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/ptyHostService.ts#L31-L217) | PTY host start, proxy, heartbeat, and restart |
| S12 | [`electronPtyHostStarter.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/electron-main/electronPtyHostStarter.ts#L24-L141) | Electron utility process and direct MessagePort |
| S13 | [`ptyService.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/ptyService.ts#L97-L180) | PTY host process registry and RPC surface |
| S14 | [`terminalProcess.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/terminalProcess.ts#L85-L237) | Direct node-pty boundary |
| S15 | [`shellIntegrationAddon.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/common/xterm/shellIntegrationAddon.ts#L37-L320) | OSC protocol and terminal capabilities |
| S16 | [`terminalEnvironment.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/terminalEnvironment.ts#L53-L282) | Shell integration injection |
| S17 | [`terminalLinkManager.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/links/browser/terminalLinkManager.ts#L44-L237) | Link detector order, security, and openers |
| S18 | [`terminalClipboard.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/clipboard/browser/terminalClipboard.ts#L13-L112) | Multiline paste safety |
| S19 | [`terminalFindWidget.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/find/browser/terminalFindWidget.ts#L29-L259) | Find UI and xterm search calls |
| S20 | [`terminal.accessibility.contribution.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/accessibility/browser/terminal.accessibility.contribution.ts#L63-L260) | Accessible buffer and command navigation |
| S21 | [`terminalLogService.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/common/terminalLogService.ts#L14-L67) | Dedicated terminal log |
| S22 | [`terminalExtensions.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalExtensions.ts#L10-L77) | Per-terminal contribution registry |
| S23 | [`terminalContrib/README.md`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/README.md) | Feature boundary rule |

## Behavior matrix

| Area | Current VS Code behavior | Source | Anvil disposition |
|---|---|---|---|
| UI location | A terminal can live in the panel, editor area, auxiliary window, or background. | S1, S3, S6 | Use one ordinary Terminal View in one Pane. |
| Instance model | One `TerminalInstance` joins emulator, process manager, status, title, and contributions. | S4 | Keep one View-to-session owner. Split helper logic by concern. |
| Renderer | xterm.js owns VT parsing, grid state, cursor, selection, and input encoding. | S7 | Keep Ghostty as the emulator. Do not add xterm.js. |
| Addons | Core addons cover marks, decorations, shell integration, clipboard, and progress. | S7 | Add behavior directly only when Anvil needs it. |
| Optional renderer | WebGL loads after DOM open. Context loss falls back to DOM rendering. | [GPU path](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/xterm/xtermTerminal.ts#L893-L1060) | Keep the D3D11/software fallback outside Terminal View. |
| Input routing | Workbench commands get first refusal. xterm encodes remaining keys. | S4 | Keep command routing before Ghostty encoding. Test both paths. |
| Early input | Process manager queues input until process readiness. | [S8 lines 376-390](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalProcessManager.ts#L376-L390) | Define a small queue or reject input while starting. Never lose input silently. |
| Programmatic send | Text normalizes to carriage returns. Optional bracketed paste wraps payloads. | S4 | Keep user paste separate from command execution. |
| Resize | Invalid sizes are ignored. Large horizontal reflow is delayed. | [S4 lines 2012-2103](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L2012-L2103) | Coalesce changed sizes. Send only positive rows and columns. |
| Selection | xterm owns normal, line, word, and rectangular selection. | S7 | Keep Ghostty selection as the source of truth. |
| Clipboard | Copy can use plain text or HTML. Copy-on-select is optional. | [S7 lines 798-856](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/xterm/xtermTerminal.ts#L798-L856) | Keep plain text. HTML copy is not a 90% need. |
| Paste safety | Bracketed paste bypasses warnings. Unsafe multiline paste asks first. | S18 | Keep Anvil’s existing warning. Add trailing-newline protection. |
| Find | Search loads on first use. It supports case, word, regex, count, and highlights. | S19 | Extend current search only after lifecycle work. |
| Text targets | Detectors handle URI, local path, wrapped path, and generic word targets. | S17 | Add only URI and `path:line[:column]` Text POIs first. |
| Target security | A modifier activates targets. Unknown URI schemes require approval. | S17 | Keep Anvil’s modifier activation and fixed safe-scheme set. |
| File target cost | File checks cap link length and checks per line. | [`terminalLocalLinkDetector.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/links/browser/terminalLocalLinkDetector.ts#L20-L101) | Limit scanning to visible rows and nearby scrollback. |
| Shell integration | Injected scripts emit OSC 633 command, prompt, cwd, mark, and environment data. | S15, S16 | Parse standard OSC data. Do not inject shell scripts initially. |
| Shell trust | A nonce labels command and environment reports as trusted. | [S15 lines 501-589](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/common/xterm/shellIntegrationAddon.ts#L501-L589) | Treat all terminal output as untrusted unless Anvil adds a nonce contract. |
| Accessibility | xterm screen-reader mode works with a separate accessible text view. | S20 | Use Terminal Text Capture as the stable accessible surface. |
| Process boundary | `TerminalProcess` validates launch, calls node-pty, and maps events. | S14 | Keep one narrow native session API. |
| Output pressure | The PTY pauses above a high watermark and resumes below a low watermark. | S14 | Keep the current bounded native queues. Add saturation diagnostics. |
| Process exit | VS Code delays exit for trailing data, then flushes emulator writes. | [S14 lines 372-421](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/terminalProcess.ts#L372-L421), [S4 lines 1717-1839](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L1717-L1839) | Preserve Anvil’s native output drain and add focused tests. |
| Close behavior | VS Code can confirm when a terminal has child processes. | [S3 lines 420-443](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalService.ts#L420-L443) | Avoid process-tree polling. Consider one simple live-session confirmation. |
| Host failure | A heartbeat disables input. Recovery restarts the host and relaunches shells. | S11, [S8 lines 533-590](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalProcessManager.ts#L533-L590) | Add isolation only if native faults affect editor stability. |
| Tabs and panes | A terminal tab owns one group. A group can own several split terminals. | S2, S5 | Do not copy. Anvil Pane Groups already own this behavior. |
| Hidden state | A process can continue without a visible terminal host. | S3 | View Suspension already gives Anvil this model. |
| Reload reconnect | A surviving PTY host reattaches the same live process. | [S3 lines 452-557](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalService.ts#L452-L557) | Defer exact process reattach. It requires another process owner. |
| Full restart restore | VS Code starts a new shell and replays serialized normal-buffer state. | [S13 lines 230-312](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/ptyService.ts#L230-L312) | Keep current start-at-cwd restore. Do not call replay “process persistence.” |
| Failure display | Launch errors use clear messages. Exit alerts depend on state and settings. | S4, S14 | Keep error state visible in the Terminal View and log details. |
| Diagnostics | Dedicated terminal and PTY-host logs record RPC, lifecycle, latency, and failures. | S11, S13, S21 | Add quiet, session-tagged logs before more features. |
| Tests | Unit tests cover models. Recording tests cover OSC streams. Smoke tests cover real UI. | See testing section | Copy the layers, not the full harness. |

## Detailed findings

### UI, tabs, panes, and View ownership

VS Code has two terminal hosts.

The panel host contains terminal-owned tabs. Each tab is a `TerminalGroup`.

A group can contain several terminal instances in a terminal-owned split view.

The editor host wraps a terminal instance in a normal editor input.

Moving a terminal detaches its instance from one host and attaches it to another.

This design fits VS Code’s panel and editor split.

It does not fit Anvil’s glossary as well.

Anvil already defines a Terminal View as ordinary Pane content.

Anvil Tabs represent Panes. Pane Groups already own split layout.

A terminal-specific group layer would duplicate existing ownership and focus rules.

**Adopt:** one reusable Terminal View instance can detach and attach to a visual container.

**Avoid:** a second tab model, a second split model, and a global active-terminal model.

### Terminal instance and contribution model

`TerminalInstance` is the central join point. It owns many fields and dependencies.

It also creates one contribution object for each registered terminal feature.

The contribution receives three useful seams:

- the terminal instance;
- the process manager;
- a widget manager.

Contributions receive `xtermReady`, `xtermOpen`, and `layout` hooks.

The separate `terminalContrib` tree cannot be imported by the core terminal tree.

This direction rule limits feature-to-core coupling.

The pattern is useful after several independent terminal features exist.

It is too much for Anvil now.

A smaller rule is enough:

- Keep core session behavior in the Terminal View and native session.
- Keep optional behavior in separate Lua modules only when it has independent state.
- Do not add a registry before two real features need one.

### xterm.js boundary and rendering

`XtermTerminal` states that process interaction is out of scope.

It constructs one xterm.js `Terminal` with rows, columns, font, theme, cursor, scrollback, and input options.

Always-loaded behavior includes mark navigation, command decorations, shell integration, clipboard, and progress.

Optional behavior includes search, Unicode 11, WebGL, serialization, images, and ligatures.

Optional addons load through one cached importer.

WebGL failure sets a global DOM-renderer suggestion. Context loss also removes WebGL.

The wrapper still uses xterm private `_core` members for refresh, cell size, and hover layout.

That private use creates upgrade risk.

The package set also uses beta versions.

Anvil should keep Ghostty behind `terminal_native`.

Anvil should not reproduce xterm’s addon graph around Ghostty.

### Process creation and node-pty boundary

`TerminalProcess` validates the working directory and executable before spawn.

It resolves the executable path before node-pty searches `PATH`.

It then calls `node-pty.spawn(executable, args, options)`.

The options include working directory, environment, rows, columns, and ConPTY settings.

On Windows, VS Code uses ConPTY on supported builds.

The code handles a deferred Windows PID from recent node-pty versions.

It also throttles some ConPTY kill-and-spawn calls.

Shutdown waits for trailing output. It has a 250 millisecond quiet period and a five-second maximum.

Immediate shutdown is not immediate on Windows. This avoids known ConPTY host hangs.

Source: [TerminalProcess spawn and shutdown](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/terminalProcess.ts#L238-L449).

These workarounds show one important rule.

Native terminal teardown needs explicit ordering and platform-specific tests.

Anvil already owns ConPTY directly. It should test that boundary instead of copying node-pty workarounds blindly.

### PTY host and process isolation

Desktop VS Code starts a separate Electron utility process for terminals.

The renderer uses a direct MessagePort for frequent process traffic.

A second route through the main process carries management traffic.

The host sends heartbeats every five seconds.

The controller uses two timeout stages. A process-create request has a five-second timeout.

Unexpected host exit triggers bounded restart attempts.

On host restart, normal terminals show a loss message and launch a replacement shell.

Feature terminals report an exit instead.

Isolation protects the workbench from node-pty and ConPTY faults.

It also adds IPC, reconnect IDs, heartbeats, orphan checks, and cross-process logs.

Anvil should not add this layer without evidence.

Record native hangs, crashes, and blocked updates first.

If isolation becomes necessary, isolate the existing native session API.

Do not redesign the Terminal View at the same time.

### Lifecycle and exit ordering

VS Code uses distinct process states:

- uninitialized;
- launching;
- running;
- killed during launch;
- killed by user;
- killed by process.

`TerminalInstance` also tracks exiting, disposing, disposed, disconnected, and stdin-disabled state.

The exit path follows careful ordering.

1. It rejects duplicate exit work.
2. It waits for pending xterm parses.
3. It records the exit code and message.
4. It fires `onExit` before disposal.
5. It can retain the terminal for “press any key to close.”
6. It disposes contributions before xterm.
7. It disposes resize work before the process manager.
8. It fires `onDisposed` after xterm disposal.

Source: [TerminalInstance disposal](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalInstance.ts#L1301-L1370).

This ordering is a strong Anvil pattern.

Anvil currently uses a `running` Boolean at the Lua layer.

A small explicit state enum would make late input and close behavior easier to test.

### Relaunch behavior

VS Code can reuse a TerminalInstance with a replacement process.

A seamless relaunch filter records old and new output.

It avoids a terminal reset when both recordings match.

It gives up after three seconds. User input also disables the seamless swap.

Source: [SeamlessRelaunchDataFilter](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalProcessManager.ts#L759-L904).

This is polished but optional.

Anvil can clear and restart explicitly. A visible restart boundary is simpler and honest.

### Shell integration

VS Code injects scripts into Bash, Fish, PowerShell, and Zsh launch paths.

The scripts emit OSC 633 sequences.

The parser turns those sequences into capabilities:

- command detection;
- current working directory detection;
- prompt input tracking;
- prompt type detection;
- buffer marks;
- selected environment reporting.

The command model then powers decorations, command navigation, recent commands, quick fixes, and accessibility.

Injection changes shell arguments and startup files.

It has shell-specific rules, temporary files, permissions, and environment fixes.

Unsupported arguments cause injection failure. The shell still starts without integration.

If an injected launch fails, VS Code can relaunch with integration disabled.

This system gives high value after it works.

It also has a large compatibility surface.

Anvil should first use standard emulator data:

- OSC 7 for current directory;
- OSC 8 for explicit hyperlinks;
- OSC title sequences for the View name.

Anvil should not inject startup scripts for its first robust version.

### Links and Anvil Text POIs

VS Code uses detector priority.

It checks multiline paths, local paths, URIs, generic words, and extension providers.

Local path detection uses command-specific working directories when shell integration provides them.

It validates candidates through the file service before activation.

It caps path length and checks per line. This prevents excessive remote requests.

A local file opener preserves line and column suffixes.

A VS Code workspace directory opens in the existing Explorer.

An outside directory opens in a new window.

URI activation requires a modifier. Unknown schemes require approval.

Useful Anvil subset:

1. Keep Ghostty OSC 8 targets.
2. Detect `path:line[:column]` on visible rows.
3. Resolve relative paths against the best known Terminal View directory.
4. Validate the path before showing it as a Text POI.
5. Open files through Anvil’s normal View opener.
6. Use one fixed safe set for external URI schemes.
7. Add strict length and count limits.

Do not add generic word search, multiline heuristics, or extension providers first.

### Selection, clipboard, and paste

xterm.js owns terminal selection. VS Code exposes plain text and optional HTML.

The find widget temporarily disables copy-on-select.

This prevents search highlights from replacing clipboard text.

Paste uses xterm’s paste API, so active bracketed-paste mode controls framing.

The safety check skips warnings for one line or bracketed-paste mode.

It strips one trailing newline in automatic mode.

That rule prevents copied text from executing without review.

For other multiline text, the dialog offers paste, paste as one line, or cancel.

Anvil already warns for multiline paste.

The trailing-newline rule is the best small addition.

### Find

VS Code lazily loads `@xterm/addon-search`.

The widget supports case sensitivity, whole word matching, regular expressions, and result counts.

It highlights matches and marks them in the overview ruler.

The highlight limit is 20,000 matches.

Opening find uses a single-line selection as the initial query.

Closing find clears decorations and returns focus to the terminal.

Anvil already has terminal search through its Global Prompt Bar.

The next useful step is visible result feedback.

Regex and overview-ruler marks can wait.

### Accessibility

VS Code enables xterm screen-reader mode when the workbench requests it.

It also provides a separate accessible terminal buffer.

`BufferContentTracker` joins wrapped rows into logical text lines.

It caps cached text to terminal scrollback size.

It maps terminal buffer rows to accessible editor lines.

Command markers become navigation symbols. Success and failure can produce accessibility signals.

A text-area sync addon mirrors the current prompt text and cursor for screen readers.

Sources: [`BufferContentTracker`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/accessibility/browser/bufferContentTracker.ts#L12-L143) and [`TextAreaSyncAddon`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/accessibility/browser/textAreaSyncAddon.ts#L12-L83).

Anvil has a simpler path.

Terminal Text Capture already converts stable terminal text into a read-only Text View.

Use that View for screen-reader review, search, selection, and navigation.

Do not build a second live accessible editor until tests show that capture is insufficient.

### Persistence and reconnection

VS Code has two different restore behaviors.

#### Window reload

The PTY host survives a renderer reload.

The renderer saves terminal process IDs, active group, split sizes, titles, and icons.

After reload, it attaches new TerminalInstances to orphaned PTY processes.

A detached persistent process uses a 60-second grace period.

The host can reduce this to a six-second short grace period.

Source: [persistent process attach and detach](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/ptyService.ts#L687-L987).

#### Full application restart

VS Code serializes a headless xterm normal buffer and command metadata.

It stores versioned JSON in machine-scoped VS Code workspace storage.

On restart, it resolves a fresh environment and starts a new shell.

It writes the old buffer into that new shell with a visible “History restored” message.

This is display restoration. It is not continuation of the old operating-system process.

The source also states that the dirty prompt cannot be revived.

Source: [shutdown persistence](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/browser/terminalService.ts#L616-L736) and [headless serializer](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/platform/terminal/node/ptyService.ts#L1032-L1142).

Anvil’s current Workspace restore starts a new shell at a saved working directory.

That behavior is small and clear.

Anvil should not replay old terminal output into a new shell by default.

A Terminal Text Capture gives stable history without implying process continuation.

### Diagnostics

VS Code creates a dedicated `terminal.log`.

Trace messages include a short VS Code workspace identifier.

The PTY host has a separate `ptyhost` logger.

PTY RPC tracing records requests, responses, and events.

Environment objects are sanitized before logging.

The backend measures latency across each process boundary.

Startup and reconnect use performance marks.

Useful developer actions can restart the PTY host and record terminal events.

Source: [developer contribution](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/developer/browser/terminal.developer.contribution.ts#L34-L232).

Anvil should add quiet logs for:

- session creation and final state;
- shell path and working directory;
- size changes;
- native queue saturation;
- rejected input or paste;
- ConPTY read and write errors;
- process exit code;
- output bytes drained before exit;
- clipboard and notification protocol decisions;
- restart attempts and outcomes.

Logs must not include full environment values, terminal output, or user commands by default.

## Testing assessment

### Useful upstream test patterns

VS Code has several useful test layers.

- `terminalInstance.test.ts` tests trust, key routing, exit text, disposal order, and title behavior.
- `terminalProcessManager.test.ts` tests persistence choices, listener leaks, and host restart text.
- `xtermTerminal.test.ts` tests buffer extraction, themes, markers, and renderer changes.
- Shell integration tests replay recorded PowerShell and Zsh output into xterm.
- Link tests use worked Windows, POSIX, Git, WSL, and compiler-output examples.
- Clipboard tests cover multiline warnings, bracketed paste, and file clipboard fallback.
- Accessibility tests cover wrap joining, viewport refresh, and scrollback limits.
- Smoke tests cover editors, tabs, profiles, persistence, shell integration, and input.

Important source paths:

- [`terminalInstance.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/test/browser/terminalInstance.test.ts)
- [`terminalProcessManager.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/test/browser/terminalProcessManager.test.ts)
- [`shellIntegrationAddon.integrationTest.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminal/test/browser/xterm/shellIntegrationAddon.integrationTest.ts)
- [`terminalLocalLinkDetector.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/links/test/browser/terminalLocalLinkDetector.test.ts)
- [`terminalClipboard.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/clipboard/test/browser/terminalClipboard.test.ts)
- [`bufferContentTracker.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/src/vs/workbench/contrib/terminalContrib/accessibility/test/browser/bufferContentTracker.test.ts)
- [`test/smoke/src/areas/terminal`](https://github.com/microsoft/vscode/tree/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/test/smoke/src/areas/terminal)

### Upstream test gaps

The PTY-host controller has only a narrow listener-disposal unit test.

The native node-pty path depends heavily on smoke and integration coverage.

Terminal smoke suites retry three times.

Most terminal smoke suites skip Linux because the PTY host can crash there.

The source calls that crash an unknown issue.

Sticky-scroll smoke tests are disabled. Split-working-directory smoke tests skip Windows and Linux.

Source: [`terminal.test.ts`](https://github.com/microsoft/vscode/blob/3aa54039a0bec1bd4f9b428cdb202b4271bf22ef/test/smoke/src/areas/terminal/terminal.test.ts#L14-L51).

This matters for Anvil.

Do not treat VS Code’s size as proof of complete native reliability.

### Current Anvil coverage and remaining tests

Anvil already covers much of the useful VS Code behavior.

`tests/lua/runtime/terminal_native.lua` covers ConPTY output, exit codes, large output, TUIs, close, WSL, and OpenSSH.

Its large-output test verifies the output tail after more than four MiB of data.

`tests/lua/ui/terminal.lua` covers View Suspension, hidden groups, input routing, resize, exit, selection, search, mouse, and capture.

`tests/lua/benchmarks/terminal.lua` measures sustained update and snapshot cost.

Add only the remaining durable cases.

1. UI test: each explicit lifecycle state accepts or rejects input correctly.
2. UI test: repeated equal layouts do not call native resize.
3. UI test: an invalid layout does not send zero dimensions.
4. UI test: multiline paste asks first outside bracketed-paste mode.
5. UI test: one trailing newline does not execute clipboard text automatically.
6. UI test: View Suspension routes no focus input to its Terminal View.
7. UI test: wrapped Terminal Text Capture stays stable for screen-reader review.
8. UI test: a valid `path:line` Text POI opens the expected file location.
9. Native test: input-queue saturation reports one useful diagnostic and recovers.

Do not duplicate the existing multi-megabyte drain or process-tree close tests.

Do not test exact shortcuts, colors, pixel values, or shell timing.

## Useful patterns for Anvil

### Adopt now

1. **One owner per session.** One Terminal View owns one native terminal session.
2. **Explicit lifecycle state.** Use starting, running, exited, failed, and closed states.
3. **Bounded output.** Keep producer backpressure and report queue saturation.
4. **Final-output barrier.** Drain parsed output before publishing final exit.
5. **Teardown order.** Stop resize and input before closing the transport.
6. **Pre-ready input rule.** Queue a bounded amount or reject it visibly.
7. **Changed-size rule.** Send only positive dimensions that changed.
8. **Input precedence.** Anvil commands run before terminal key encoding.
9. **Paste trust rule.** Do not execute a clipboard trailing newline without review.
10. **Safe Text POIs.** Validate targets and restrict URI schemes.
11. **Stable accessibility surface.** Use Terminal Text Capture.
12. **Quiet diagnostics.** Tag each lifecycle event with one session identifier.

### Adopt when needed

- Command-specific working directories from trusted shell data.
- Find result counts and case control.
- A simple close confirmation for live sessions.
- Process isolation after measured native instability.
- Command markers after a concrete navigation use appears.

## Heavy machinery Anvil should not copy

### Terminal-owned tabs and split groups

This duplicates Pane, Tab, Pane Group, and Navigation History behavior.

### Global terminal service and active-terminal arbitration

Anvil can find the focused Terminal View through normal View focus.

### Panel-versus-editor terminal locations

A Terminal View is already ordinary Pane content.

### Extension-owned pseudoterminals

Anvil has no current external API boundary that requires them.

### Remote authority and backend registries

These solve local-versus-remote VS Code process placement.

They do not solve a current Anvil constraint.

### Complete shell integration injection

It changes shell startup and requires shell-specific maintenance.

### Headless buffer replay across application restarts

It starts a new shell while showing old output. This can confuse process identity.

### Generic word links and full-scrollback scans

They add false positives and file-system work.

### WebGL, image, ligature, and progress addon management

Anvil’s renderer and Ghostty already own the relevant presentation layers.

### Local type-ahead prediction

VS Code’s type-ahead addon is large and protocol-sensitive.

Do not add it without measured remote latency.

### Telemetry machinery

Quiet local diagnostics give enough value for this personal fork.

## Gaps and risks

### Upstream risks

1. `TerminalInstance`, `TerminalService`, and `PtyService` are large coordination classes.
2. xterm integration uses private `_core` fields.
3. VS Code consumes beta xterm and node-pty packages.
4. PTY host failure loses live shell processes and relaunches replacements.
5. Full restart “revival” restores display state, not process state.
6. Shell integration mutates startup arguments and temporary shell files.
7. File link detection can issue file checks during hover and link collection.
8. Native smoke coverage has platform skips and retries.
9. Persistence has several IDs, grace timers, orphan checks, and storage copies.
10. Event ordering depends on many disposables and delayed callbacks.

### Anvil-specific risks

1. ConPTY and Ghostty run inside the editor process.
2. A native hang can block or destabilize the whole editor.
3. Lua currently has a small `running` state model.
4. Final output depends on native queue, pipe-drain, and transport teardown ordering.
5. View restore starts a new shell, not the prior process.
6. Terminal path Text POIs do not yet have VS Code’s validated path model.
7. Terminal Text Capture must remain stable across wrapped rows and scrollback eviction.
8. Terminal logs need enough state to diagnose rare native failures.

## Prioritized recommendations

### P0: lifecycle and data integrity

1. Define one terminal lifecycle state model.
2. Preserve and test the native output drain before reporting exit.
3. Preserve bounded input and output queues with producer backpressure.
4. Log queue saturation and rejected writes.
5. Verify that no resize work can run after native close.
6. Preserve changed-size filtering. Coalesce resize bursts only if measurement shows a cost.
7. Keep key routing deterministic between Anvil and Ghostty.
8. Add only the remaining focused native and UI tests listed above.

These changes protect commands, output, and editor stability.

### P1: safe daily behavior

1. Keep the multiline paste warning.
2. Strip one unsafe trailing newline before paste.
3. Keep the current exit code and failure state visible in the Terminal View.
4. Keep the current exited output until the user closes or restarts it.
5. Add visible find result feedback.
6. Make Terminal Text Capture the review and accessibility path.
7. Keep OSC 8 URI targets. Add `path:line[:column]` Text POIs with strict limits.
8. Use quiet session-tagged logs for every native boundary.

### P2: evidence-driven resilience

1. Measure native stalls and crashes in real use.
2. Add a separate terminal host only after repeat evidence.
3. Keep the existing native session API if isolation becomes necessary.
4. Add simple live-session close confirmation only if accidental close is common.
5. Parse more standard OSC data only when a user-facing feature needs it.

### Do not schedule now

- terminal-specific tabs or split groups;
- exact process persistence across application exit;
- shell startup script injection;
- remote terminal backends;
- extension pseudoterminals;
- image rendering controls;
- local type-ahead prediction;
- terminal suggestions or quick fixes;
- full command decoration and sticky-scroll systems.

## Recommended 90% model

The following model fits Anvil’s current design.

```text
Terminal View
  - owns focus, commands, selection, search, and visible state
  - owns one Native Terminal Session
  - exposes Terminal Text Capture

Native Terminal Session
  - owns Ghostty terminal state
  - owns ConPTY process and job
  - owns bounded input and output queues
  - emits data, bell, clipboard, notification, exit, and error events

Existing Anvil systems
  - Panes and Tabs own placement
  - Navigation History owns View Suspension
  - Workspace restore starts a new shell at the saved directory
  - Text View owns stable capture review
  - logging owns diagnostics
```

This model has no terminal service, terminal group, PTY backend registry, or addon registry.

It still supports the durable daily behavior:

- interactive terminal applications;
- correct VT rendering;
- keyboard and mouse input;
- resize and scrollback;
- selection and clipboard;
- safe paste;
- search;
- explicit hyperlinks;
- stable text capture;
- visible exit and restart;
- View Suspension;
- clear diagnostics.

That is the smallest model that gives a robust Anvil Terminal View without copying VS Code’s product scale.
