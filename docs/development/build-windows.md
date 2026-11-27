# Windows builds and dependencies

## Layout

- Source repo: any folder, for example `D:\Projects\c_projects\anvil-editor`
- Dev portable app: `anvil-portable` beside the repo, for example `D:\Projects\c_projects\anvil-portable`
- Build dir: `build-windows-x86_64` in the repo
- Source built-in plugins: `data\plugins`
- Source core Lua: `data\core`

## Build outputs

Compiling produces binaries in:

- `build-windows-x86_64\src\anvil.exe`
- `build-windows-x86_64\src\anvil.com`

These build-directory binaries retain native debug information. The dev portable app strips its executable so it starts quickly.

Dev builds load Lua/data files beside the exe. A runnable dev app is produced by `meson install` into `..\anvil-portable`.

## Standalone Windows release

Run `build.bat` to create and test `dist\anvil.exe`. This is the build for other users. `scripts\msys2-env.cmd` finds MSYS2 at `MSYS2_ROOT` or `C:\msys64`.

It installs MSYS2 with winget when it is missing. It installs missing build packages with pacman. All BAT files use it, so none of them hardcode a folder.

The release exe contains a compressed copy of the runtime data. On first run, it extracts that data to `%LOCALAPPDATA%\Anvil\runtime\<build-id>\data`. Later runs reuse the same complete runtime.

Users only distribute `anvil.exe`. The standalone build runs `tests\gui\smoke\standalone-runtime-test.ps1`.

Keep the dev build external-data workflow. Do not embed source data in the dev portable app's executable. The standalone build uses its own `build-windows-x86_64-standalone` directory.

The standalone build needs MSYS2, MinGW64 GCC, Ninja, CMake, Python, Meson, and Zig. `scripts\ensure-zig.sh` downloads the pinned Zig release into `%LOCALAPPDATA%\anvil-build-tools` when it is missing. The build needs network access for this download and for Meson subprojects on a clean machine.

Zig's own HTTP and Git clients fail on some Windows machines. `subprojects/packagefiles/ghostty/build-vt.sh` then gets each missing Ghostty dependency with curl or git and gives Zig the unpacked folder.

## Embedded runtime packaging

The standalone option is `-Dembedded_runtime=true`. It is off by default. `scripts\build-standalone-windows.sh` enables it, strips the executable, runs the standalone smoke test, and promotes the result only after the test passes.

The Windows runtime excludes source artwork, platform app icons, and icon compiler inputs. Keep these files in the source tree. Runtime UI icons, fonts, licenses, and `rg.exe` stay packaged.

Run `anvil:embedded-runtime` after packaging changes.

Both the embedded runtime and Meson installs include the complete `licenses/` tree. `licenses/third-party.md` lists native dependency notices and the bundled ripgrep notice. Update the copied license texts and component versions when dependencies change. Keep upstream license text unchanged.

### GitHub releases

The only active GitHub workflow is `.github\workflows\release.yml`. It builds one Windows x86_64 standalone executable and uploads `dist\anvil.exe` to a GitHub Release. A tag that starts with `v` starts the workflow:

```sh
git tag -a v1.0.1 -m "Anvil 1.0.1"
git push origin master
git push origin v1.0.1
```

Versions use `MAJOR.MINOR.PATCH`. Set the version in `meson.build` before you tag. The plugin API version (`mod_version` in `meson.build`) is separate.

Plugins declare it in their `mod-version` header. Change it only when the plugin API changes.

The workflow also supports manual dispatch. Pass an existing release tag when you retry a build. Do not commit release executables; `*.exe` is ignored.

The workflow uses the same standalone script as the local build. Keep these paths and the smoke test aligned when changing release packaging. The release asset is unsigned, so Windows SmartScreen can show a warning.

### Release updates

Windows standalone builds check `dcostap/anvil-editor` for a newer stable GitHub release. `updater:check` opens the Updates Dialog. Background checks share a cache across Projects.

It lasts 10 hours, and each Anvil start checks again. A start within 1 hour of a check, such as the restart after an update, reuses that check. A failed check retries after 1 hour.

The Dialog opens by itself once for each release; after that, Check for Updates shows it. `config.plugins.updater.check_automatically` controls them. The Dialog offers Update and Restart.

Development builds and direct mode do not install release updates. The release needs an uploaded `anvil.exe` and its GitHub SHA-256 digest. The updater checks its size and digest before asking Anvil to close.

HTTPS and the GitHub repository are the trust boundary; the digest is not a publisher signature. The bundled `data/tools/updater.ps1` starts through Windows Explorer, outside the caller's process group. It uses `--prepare-update` to save Workspaces and detach Terminal Sessions.

It never force-closes the editor. A refused or timed-out close leaves the executable unchanged. The helper takes a per-executable file lock, downloads beside the executable, and keeps the previous executable in `<executable>.updates`.

Locked previous images belong to running Terminal hosts and stay there. Extracted runtime folders stay because old hosts can still use their files. A replacement or immediate startup failure restores the previous executable and starts it again.

This is not a health check for later crashes. Requests, progress, and logs stay under `USERDIR/updates`. A recovery error appears after restart.

The release workflow checks out the requested tag and rejects an asset whose build version differs from that tag. Run `runtime/update_release.lua`, `ui/updater.lua`, `anvil:release-update` and `anvil:release-update-launch` after changes. Tests use private executables and a fake download, not the installed editor.

Check the `update-dialog` render scenario after visual changes.

## App logo and icons

The source artwork is `resources\icons\logo-source.png`. To replace the app logo:

1. Replace `resources\icons\logo-source.png` with the new PNG.
2. Run this command from the repo root:

   ```sh
   python tools/update_anvil_icon.py
   ```

3. Check the generated icons at small sizes on light and dark backgrounds.
4. Run `update-anvil-dev-build.bat` to rebuild, install, and restart the dev portable app.

The generator needs Python and Pillow. It crops transparent outer padding and adds no inset. It updates the Linux PNG, Windows ICO, macOS ICNS, and native window icon.

Linux packages use the generated PNG. Do not edit generated icons separately. Commit the source PNG and all generated files together.

Normal builds use these files and do not need the generator's tools. Keep the Windows resource dependency on `resources\icons\icon.ico` in `src\meson.build`. This dependency makes ICO changes rebuild the executable's icon resource.

Toolbar and file-type icons are separate from the app logo.

## Dev portable workflow

Use the BAT files in the repo root
- `setup-anvil-dev.bat`
  - first-time setup
  - builds the editor
  - installs the dev portable app to `..\anvil-portable`
  - creates Windows junctions for editable data directories, including `data\core`, `data\plugins`, `data\colors`, and `data\widget`
  - launches the app

- `update-anvil-dev-build.bat`
  - default finalization step only when non-Lua files were edited
  - use after C/C++, build-system, asset, or other non-Lua source/default-data changes so the dev portable app is refreshed consistently
  - skip for edits under junctioned data directories; reload or restart Anvil instead
  - rebuilds and updates the dev portable app
  - builds and strips the app in a staging folder before closing the editor
  - asks the running editor to save its Workspaces and detach Terminal Sessions
  - copies the staged files without writing through the source-data junctions
  - Terminal Session hosts and their shells keep running; the restarted editor reconnects to them
  - restarts through Windows Explorer, outside the updating Terminal's process group
  - uses the desktop environment for the restarted app; closing the updating Terminal cannot kill that app
  - moves the old `anvil.exe` and ConPTY files into `anvil-portable\retired`, because running hosts lock them
  - stops if the editor does not close, for example at an unsaved-file prompt; it never force-stops a process

- `launch-anvil-debug.bat`
  - explicitly launches the unstripped `build-windows-x86_64\src\anvil.exe`
  - uses the data and user folders of the dev portable app
  - use this only when native debugger/symbol information is needed

`scripts/start-dev-anvil.ps1` starts the app after setup and updates. Do not replace it with `Start-Process` or CMD `start`. Those calls keep the caller's Windows job.

A later Terminal Close can then kill the restarted editor. Run `anvil:dev-update-launch` after changes. It uses a windowless test app, not the dev portable app.

The dev portable app's executable:

```text
..\anvil-portable\anvil.exe
```

It is the stripped executable. Do not switch it back to the unstripped build output; use `launch-anvil-debug.bat` for native debugging.

## Worktree cleanup

After your branch is in `master`, remove your worktree, your branch and your scratch folders. Do not wait for the user to ask. Remove only what you made.

Other agents can still use their worktrees.

A worktree's `subprojects` folder can hold directory symlinks into the main repo's `subprojects`. A delete that follows a link deletes the main repo's dependencies. Before `git worktree remove --force`, remove the links:

```sh
python -I -c "import os, sys; d = sys.argv[1]; [os.rmdir(p) for p in (os.path.join(d, n) for n in os.listdir(d)) if os.path.islink(p) or os.path.isjunction(p)]" D:/path/to/worktree/subprojects
```

`cmd rmdir` from Git Bash failed on these links. Then remove the worktree, delete the branch with `git branch -d`, and check that the main repo's `subprojects` is unchanged.

## Vendored/Meson subprojects

Meson refreshes cached Git subprojects before it loads them when their checked-in inputs change. `scripts/sync-git-subprojects.py` tracks wrap files, local patches, and package files. The first configure also refreshes existing Git checkouts.

Missing checkouts use normal Meson downloads. A refresh puts local dependency edits in that checkout's Git stash. It does not apply them again.

Line endings do not count as a change. A worktree can link to the main repo's checkouts and copy its state, and gets the same state. Ignored build caches, such as Zig's, stay in place.

State stays under the ignored `subprojects/.anvil-wrap-state` directory. Custom library targets must depend on their input state and expose the library as a build output. Run `anvil:subproject-sync` after changes to this path.

Its fixtures use local Git repositories and real Meson builds.

SDL3 is brought in through Meson's wrap system, not as a top-level git submodule:

- wrap file: `subprojects/sdl3.wrap`
- local checkout/build input: `subprojects/sdl3`
- Anvil-owned wrap patches/files: `subprojects/packagefiles/sdl3*`

If changing SDL3 behavior for Anvil, do not rely only on committing inside the local `subprojects/sdl3` checkout. Fresh clones rebuild SDL3 from the wrap, so reproducible changes must be represented in the top-level repo, usually with a patch listed in `subprojects/sdl3.wrap` via `diff_files` or files under `subprojects/packagefiles/sdl3`.

Current Anvil SDL3 patch:

- `subprojects/packagefiles/sdl3-titlebar-mousemove-opt-in.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- makes SDL3's Win32 titlebar synthetic `WM_MOUSEMOVE` workaround opt-in with `ANVIL_SDL3_TITLEBAR_MOUSEMOVE_FIX=1`
- default keeps the workaround disabled because it causes a one-frame cursor blink on normal titlebar clicks

When updating SDL3 upstream, verify this patch still applies. If it fails, rebase/regenerate the patch against the new SDL3 revision and keep it tracked in the top-level Anvil repo.

SDL3 text-drop patch:

- `subprojects/packagefiles/sdl3-complete-text-drop.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- keeps each Windows text drop complete, including blank lines and trailing newlines
- leaves file URI lists unchanged

Keep this patch when updating SDL3 unless upstream preserves complete text drops. Title Bar drops open files, images, folders, and text in new Panes. Folders open File Trees, not Projects.

Native window controls are not drop targets. Run `anvil:drop-events` and `ui/external_drop.lua` for focused checks.

SDL3 virtual-file drop patch:

- `subprojects/packagefiles/sdl3-virtual-file-drop.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- reads the `FileGroupDescriptorW` and `FileContents` formats on Windows
- writes each virtual file to `%TEMP%\AnvilDrop-*` and reports a normal file drop
- Outlook attachments and browser download drags use these formats
- virtual files have no file system path, so these drops did nothing before this patch

The materialized copy stays on disk for the session. An edit writes to that copy. Use Save As to keep a separate version.

Keep this patch when updating SDL3 unless upstream materializes virtual files itself.

SDL3 dead-key reset patch:

- `subprojects/packagefiles/sdl3-dead-key-reset.patch`
- listed by `diff_files` in `subprojects/sdl3.wrap`
- SDL builds its keymap when the input language changes, often while Ctrl+Shift is held
- the build presses each dead key, then presses Space to clear it
- SDL pressed Space with the live modifiers. With Ctrl held, Space types nothing
- the next key then got two characters, and SDL cached U+FFFD for it, such as Spanish `+`
- the patch presses Space without modifiers

Run `anvil:keymap-layout` after SDL3 updates. Keep this patch unless upstream clears dead keys the same way.

## Ghostty

Current Anvil Ghostty patch:

`subprojects/ghostty.wrap` pins libghostty-vt 1.0.1 (`vt-1.0.1`), which uses Zig 0.17.0. Library releases use `vt-*` tags, separate from Ghostty app releases.

- `subprojects/packagefiles/ghostty-semantic-prompt-fresh-line-option.patch`
- listed by `diff_files` in `subprojects/ghostty.wrap`
- adds a libghostty-vt option for OSC 133 A during synchronized output
- Anvil disables A's fresh-line action only inside synchronized output
- this prevents Pi's differential renderer and Ghostty from tracking different cursor rows
- normal OSC 133 shell behavior remains active outside synchronized output
- `tests/fixtures/terminal_semantic_prompt_repaint.ps1` covers the original Pi sequence

Pi emits OSC 133 A as a zero-width marker during synchronized TUI repaints. Ghostty treats A as a fresh-line command. If Pi emits A outside the first column, Ghostty moves down one row while Pi does not.

Pi can then erase the displaced message during a later repaint. Pi issue `#2971` reported the same Ghostty-only problem.

When updating Ghostty, verify this patch still applies. Remove it only after Pi and Ghostty agree on OSC 133 A behavior during TUI repaints.

Anvil sets Ghostty's `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK` to false. ConPTY keeps no history, so a resize must not pull history into the live screen. A height change then adds blank rows at the bottom.

A width change keeps the top of the live screen on the same text. Saved history stays available for scrolling. Run `ui/terminal_revival.lua` and `ui/terminal_resize_prompt.lua` after changes.

## Tree-sitter and LuaJIT

Current Anvil Tree-sitter Markdown patches:

- `tree-sitter-markdown-scanner-state-bounds.patch` prevents an empty block stack pop and bounds serialized scanner state.
- `tree-sitter-markdown-code-spans.patch` keeps code literal until a backtick run matches the opening width.

Both patches live in `subprojects/packagefiles`. When updating the wrap, verify both changes or check for equivalent upstream fixes.

The LuaJIT wrap pins a commit, not the `v2.1` branch. A branch refresh can pull an untested compiler change. Upstream commit `b310887` miscompiles some table stores on x64.

The JIT then writes through a tagged value, and the editor crashes. The crash showed as status 139 in `runtime/treesitter_rust.lua` and `runtime/treesitter_parse_followup.lua` under load. Move the pin past `b310887` only after upstream fixes `asm_ahustore` in `src/lj_asm_x86.h`.

Then run those two files in parallel many times. Use the pinned Zig from `scripts/ensure-zig.sh` when a wrap change reconfigures the build. Another Zig on `PATH` fails the Ghostty build.

## Optional reference source caches

Only consult these external reference sources if the user explicitly mentions them or asks for comparisons/inspiration involving them:

- Fred editor dump:
  - `C:\Projects\my_decomps\fred_src_dump`
  - source root: `C:\Projects\my_decomps\fred_src_dump\D_\git_projects\fred`
- IntelliJ IDEA Community cache:
  - `C:\Users\Darius\AppData\Local\pi-web-smart-fetch\github-cache\JetBrains\intellij-community`
