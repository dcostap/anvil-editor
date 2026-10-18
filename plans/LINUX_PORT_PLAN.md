# Linux Port Plan

## Status

Reference plan. Not scheduled. Read this when it is time to make Anvil work fully on Linux.

The multiprocess shell is non-negotiable. Anvil works like Chrome tabs: one shell owns the
windows, and each Project and Terminal Session runs in its own process. Linux must keep that
model. See `plans/MULTIPROCESS_SHELL_PLAN.md` for the design itself.

## Summary

The architecture ports to Linux. The current code does not.

The shell composites offscreen surfaces that other processes send to it. It does not embed
foreign native windows. Chrome uses the same model on Linux, so the design is proven.
The cost is the Win32 code under the shell: pipes, named shared memory, D3D11 shared
textures, process adoption, the custom window frame, and ConPTY.

Expect weeks of work for full parity, not days. No single piece is hard. The work is the
number of pieces, plus Wayland and compositor differences.

## Current state (2026-10)

What already carries over:

- The base is lite-xl on SDL3, which is cross-platform.
- `meson.build` still has Linux branches, such as the `.desktop` and appdata install and X11 detection.
- `src/meson.build` places Windows-only sources behind `host_machine.system() == 'windows'`.
- Portable C code mostly has `#ifdef _WIN32 … #else` POSIX paths: `project_file_manifest.c`,
  `markdown_vault_index.c`, `treesitter/project_index.c`, `api/process.c`, and `worker_pool.c`.
- The software renderer (`renderer.c`, `rencache.c`) needs no Windows API.
- Lua code checks `PLATFORM` in about 70 places. The terminal plugin loads `terminal_native`
  through `pcall`, so a missing module fails cleanly.
- The dependencies build on Linux: SDL3, FreeType, HarfBuzz, LuaJIT, PCRE2, Tree-sitter, and ghostty-vt.
- The SDL3 patches touch only Win32 code.

What is Windows-only:

| Area | Files | Notes |
|---|---|---|
| Shell and compositing | `anvil_shell.c` (~6.5k lines), `hosted_surface.c`, `shell_*.c`, `surface_protocol.c` | HWNDs, named pipes, named mappings, D3D11 shared textures |
| Window frame | `win32_frame.c` | Custom title bar and hit testing |
| Single instance | `win32_single_instance.c` | |
| Sidebar state watch | `sidebar_registry_watch.c` | Registry notifications |
| Terminal Sessions | `api/terminal_native.c` (~3.7k lines), `terminal_host.c`, `conpty.c`, `ipc_pipe.c` | ConPTY, Win32 threads and locks |
| GPU renderer | `d3d11_backend.c`, `d3d11_shader_compiler.c` | Software renderer is the Linux path |
| Standalone release | `embedded_runtime.c` | `%LOCALAPPDATA%` extraction |
| Shell integration | `data/tools/shell-integration/anvil.ps1` | PowerShell only |

Risk: no CI job compiles the POSIX branches. They may already be broken. The only workflow is
`.github/workflows/release.yml`, which builds Windows.

## What already matches the goal

Terminal Sessions are already independent of the editor. Each one runs in an
`anvil --terminal-session` process. That process owns the PTY and the ghostty terminal model.
Editors attach as clients. A detached session waits up to 10 minutes (`ORPHAN_GRACE_MS` in
`terminal_host.c`) for an editor to reattach, and replays a snapshot when one does.
Linux needs a new transport and PTY for this. It does not need a new design.

## Lessons from Chrome

Chrome runs separate tab processes on every desktop OS:

```text
browser process   windows, tabs, browser UI, input routing, process ownership
renderer process  page content; no native window
GPU process       the only process that uses the GPU; composites and presents
utility process   network, audio, and similar services
```

How Chrome stays portable:

1. Renderers own no windows. They send compositor frames to Viz, which composites browser UI
   and tabs into each native window.
2. One IPC system (Mojo) runs over named pipes on Windows, Unix sockets on Linux, and Mach
   ports on macOS. Message definitions are identical on every OS.
3. Mojo messages carry OS handles, such as shared memory regions and file descriptors.
   Nothing is shared by global name.
4. Shared memory is one cross-platform type with one implementation per OS.
5. Windowing goes through one interface. On Linux, Ozone selects a Wayland or X11 backend.
   Browser UI code never calls Win32 or Wayland directly.
6. ANGLE maps GPU calls to D3D11, Metal, or Vulkan. Renderers send draw commands, not GPU
   calls. A GPU process failure falls back to software.
7. The browser process detects dead and hung renderers and shows a status for each.

How Anvil maps to Chrome:

| Chrome | Anvil |
|---|---|
| Browser process + Viz | Shell |
| Renderer process | Project process |
| Utility process | Terminal Session process |
| Mojo message definitions | `surface_protocol.h` length-prefixed binary records, already mostly OS-neutral |
| Handles inside messages | Surfaces published **by name**, which is Windows-specific |
| Mojo channel | `ipc_pipe.c` named pipes |
| Ozone | SDL3, plus `win32_frame.c` |

The process model matches. The difference is the bottom layer. Chrome isolates OS code in a few
small modules. Anvil's shell calls Win32 throughout.

### Adopt

1. **Pass handles, not names.** A shared surface is a handle sent inside a protocol message:
   a duplicated `HANDLE` on Windows, and an fd sent with `SCM_RIGHTS` on Linux. This is the most
   important change. Lookup by global name is the main part that does not port to POSIX.
2. **One thin platform layer.** Put the channel, shared memory, process launch, process exit
   watch, and adoption into small modules with one Windows and one POSIX implementation. Shell
   logic, the protocol, and Lua never call the OS directly.
3. **The software surface path always works.** D3D11 shared textures are an optional fast
   path. Linux starts with software surfaces only.
4. **Later, consider draw commands instead of pixels.** `display_packet.c` already describes
   frames as text, rect, and rect-grid commands. If Project processes send commands, only the
   shell needs a GPU. This is optional and not needed for the port.

### Do not adopt

- Mojo itself. It is too large. The current binary records fit Anvil.
- A separate GPU process. Chrome uses one for sandboxing and GPU driver crashes. The shell can own the GPU.
- Sandboxing, site isolation, and the Linux zygote. These are browser security features.

## Windowing: Wayland and X11

Use SDL3 only. Do not write direct Wayland or X11 code. SDL3 selects the backend at runtime.

Wayland is the primary target. GNOME and KDE use it by default, as do Fedora, Ubuntu, and most
current distributions. X11 apps run through XWayland, but they often scale badly with mixed DPI
or fractional scaling. Keep `SDL_VIDEO_DRIVER=x11` as an escape hatch.

Wayland is less of a problem for this design than it seems:

- Wayland restricts embedding one process's window in another. The shell embeds no windows.
  It composites pixels from shared memory into its own windows.
- Wayland often expects client-side decorations, and GNOME requires them. Anvil already draws its
  own title bar. SDL hit testing maps it to native move and resize.
- SDL3 handles fractional scaling, IME through text-input-v3, and the clipboard.

Known Wayland limits:

- **Window position.** Apps cannot set or read absolute window positions. Restore size and
  maximized state only. Position restore is best effort on Linux.
- **Raising another Anvil Window.** Selecting a Project in another window must raise that window.
  This needs an xdg-activation token. One shell process owns all windows and the request follows
  user input, so it should usually work. A compositor can still refuse and show attention
  instead.
- **Compositor differences.** GNOME, KDE, and wlroots compositors such as Sway and Hyprland
  behave slightly differently. Expect a small number of compositor-specific bugs.

## Platform mapping

| Windows today | Linux replacement |
|---|---|
| Named pipes (`ipc_pipe.c`) | Unix domain sockets under `$XDG_RUNTIME_DIR` |
| Named file mappings for software frames | `memfd_create` + `mmap`, fd passed over the socket |
| D3D11 keyed-mutex shared textures | None at first; optional dmabuf later |
| Process adoption and exit watch | `pidfd_open` and `poll`; fall back to `waitpid` for direct children |
| `GetNamedPipeClientProcessId` check | `SO_PEERCRED` |
| Single instance (`win32_single_instance.c`) | A lock on a socket in `$XDG_RUNTIME_DIR` |
| Registry watch (`sidebar_registry_watch.c`) | inotify on a state file |
| Custom frame (`win32_frame.c`) | `SDL_SetWindowHitTest` |
| ConPTY | `forkpty` |
| Win32 threads, `CRITICAL_SECTION`, `CONDITION_VARIABLE` | pthreads |
| PowerShell OSC 133 integration (`anvil.ps1`) | bash and zsh integration scripts with the same nonce rules |
| Busy detection through child processes | Foreground process group of the PTY (`tcgetpgrp`) plus OSC 133 |
| `%LOCALAPPDATA%` runtime extraction | AppImage, or a tarball with `data/` beside the binary |

## Port order

Each phase should end with a usable build.

### Phase 0: Prepare on Windows (can happen at any time)

Do this while working on the shell, before any Linux work:

- Send surfaces as handles inside protocol messages instead of publishing them by name.
- Put the channel, shared memory, and process lifetime calls behind one small interface.
- Do not add new Win32 calls to shell logic outside that interface.
- Optional: add a CI job that builds `--direct` on Linux. This keeps the POSIX branches compiling.

### Phase 1: Direct-mode editor on Linux

- Configure and build with Meson on Linux. Fix compile errors in the `#else` branches,
  especially `api/system.c` and `api/process.c`.
- Run `--direct` mode with the software renderer.
- Get `tests/run-lua-tests.sh`, `anvil:lua-runtime`, and `anvil:lua-ui` passing.
- Fix Windows assumptions in Lua as they appear, such as path separators, `cmd`/PowerShell,
  and `%LOCALAPPDATA%`.

Estimate: about 1 week, mostly fixing build and runtime breakage.

### Phase 2: Terminal Sessions

- Split `terminal_host.c` into a portable core and a platform layer for PTY, IPC, and threads.
- Keep the record protocol, ghostty model, snapshot replay, and orphan grace unchanged.
- Add the `forkpty` backend and Unix socket transport.
- Add bash and zsh shell integration with the per-session nonce.
- Port `api/terminal_native.c` client code to the same transport.

Estimate: 1 to 2 weeks.

### Phase 3: Shell with software surfaces

- Port the shell, the Sidebar process, and Project process hosting to the platform layer from
  Phase 0.
- Composite software frames from `memfd` buffers into SDL textures.
- Port process adoption, so a restarted shell adopts running Projects and Terminal Sessions.
- Port single-instance handling and Sidebar state change notification.

This is the largest phase. Its size depends on how much of Phase 0 is already done.

### Phase 4: Window behavior

- Custom title bar through SDL hit testing on Wayland and X11.
- Raise and attention requests through SDL, which uses xdg-activation on Wayland.
- Best-effort window position restore.
- Test GNOME, KDE, and one wlroots compositor.

### Phase 5: Packaging

- AppImage or tarball release.
- Install the `.desktop` file, appdata, and icons. The Meson Linux branch already does part of this.
- Add a Linux job to the release workflow.

### Phase 6: GPU surfaces (optional)

Do this only if software compositing is too slow:

- Share GPU frames with dmabuf, or
- Send display packet commands and draw them in the shell.

## Verification

- The Lua runtime and UI suites pass on Linux.
- Native tests for the shell protocol, hosted routing, and process exit pass on Linux.
- A crashed Project process shows its status, and the shell restarts it without affecting other Projects.
- A killed shell leaves Projects and Terminal Sessions running. A restarted shell adopts them.
- A Terminal Session survives editor exit and reattaches with its screen intact.
- Mouse mode and OSC 133 busy status work in a TUI such as Pi.
- Typing latency is close to `--direct` mode. Measure with a port of
  `tools/run_surface_latency_probe.py`.
- Test fractional scaling on Wayland and mixed-DPI monitors.
