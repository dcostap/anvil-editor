# UI and rendering

## Display scale and Zoom

On Windows, shell and direct mode read the monitor's content scale through `src/display_scale.h`. Do not multiply it by SDL's window pixel-density ratio. A minimized Window can give a temporary ratio of 1/16 during lock or wake.

Invalid native scale reports keep the previous scale, or use 1 at startup.

`plugins.scale` keeps the chosen interface and text Zoom ratios separate from the applied size limits. Display changes apply those ratios again; they do not derive Zoom from limited font sizes. Display events do not save Zoom.

Explicit scale configuration takes priority over display changes.

A hosted process draws at the size that the shell configured, not at its hidden window's size. Windows can change that size at a display scale change, such as the end of an RDP session, and the shell refuses frames of another size. Run the `fault-window-size` shell probe after changes.

The Sidebar process makes its fonts from the style fonts, which `require "core"` makes at the startup SCALE of 1. It divides by that SCALE, not by its Window's scale. Run `ui/sidebar_app.lua` after changes.

Run `anvil:display-scale`, `ui/scale_fonts.lua` and the `zoom-global` shell probe after changes.

## Renderer selection

The dev portable app defaults to the D3D11 command renderer on Windows. Do not use the old two-flag test setup (`ANVIL_D3D11` plus `ANVIL_D3D11_COMMANDS`) for normal launches.

Use one runtime switch only when needed:

```text
ANVIL_RENDERER=software
```

Unset `ANVIL_RENDERER`, or set it to `d3d11`, to use the default D3D11 path. D3D stats are still opt-in with `ANVIL_D3D11_STATS=1` and `ANVIL_D3D11_STATS_FILE=...`.

## Tabs inside a View

`core.tab` draws the Title Bar's Tabs: `tab.draw_tile`, `tab.bar_fonts` and `tab.bar_width`. A View that shows its own Tabs, such as the SQL Result Tabs (`plugins.sql_server.result_tabs`), uses them with the Title Bar's styles, so both look the same. A View can take a Pane that the Title Bar drags over it.

`view:pane_drop_target(source, x, y)` returns a target with a `rect`, and the Title Bar then calls `view:accept_pane_drop(source, target)` on the drop. Run `ui/titlebar.lua` and `ui/sql_server.lua` after changes. Check the `sql-results` and `sql-results-drag` render scenarios after visual changes.

## Popups

A popup is a card that floats over its host: the Root Panel, or a Sidebar's surface. `core.popup` places popups in their host and hit-tests them. The Context Menu, the autocomplete description and the treelist tooltip use it.

In a hosted Project, the Root Panel starts at `content_x`. The shell shows the Sidebar over each Project pixel left of it, so a popup must not leave the Root Panel. Do not clamp popups to the window size.

Autocomplete follows the Context Menu's pointer rules: hover selects a row, and a release on a row chooses it after a press on the popup. The popup also closes when the Project loses the keyboard. Unlike the menu, it does not hold input: a press outside closes it and also reaches the View under it, and the wheel scrolls a long list.

A press on the popup does not move the caret. Run `ui/autocomplete_pointer.lua`, `ui/autocomplete_layout.lua`, `ui/context_menu.lua` and the `popup-sidebar` shell probe after changes.

## Dialogs and Project Paths

Read [Building Dialogs](../dialogs.md) before changing Dialogs or `core.ui` controls. Use `data/core/ui`, not `data/widget`, for new management UIs.

Each Dialog uses this model: Project Paths, Databases, File Types, Updates and Machines. The Project Paths Dialog (`plugins.project_paths`) is the first Dialog. `project_paths:manage` opens it.

`project_paths:add` and `filetree:add_to_project_paths` add a folder. Each Project Path, including the Root Project, has a Read-only switch. The most specific path controls editing, independently of its role.

The Workspace saves the flags. Changes apply to open Buffers too. `Buffer:is_read_only()` combines source protection with the Project Path flag; edit checks use this method.

Buffer saves refuse protected target paths, and Autosave keeps unsaved edits visible. This is editor text protection, not file permissions or a File Tree restriction. Run `ui/project_paths_dialog.lua` after changes.

Run `ui/dialog.lua`, `ui/graphics.lua`, `ui/project_paths_dialog.lua` and `ui/filetree_project_paths.lua` after changes. Check the `project-paths-dialog` render scenario after visual changes.

## File Types

The File Types Dialog (`plugins.file_types`, `file_types:manage`) lists the file types in `config.plugins.file_types.types`. It is on Windows only. A check registers the type's extensions for this `anvil.exe` at once.

A clear removes them. A type that another `anvil.exe` opens shows "Another Anvil". A check takes it over.

All keys are under `HKEY_CURRENT_USER`: one `Anvil.<ext>` ProgID for each extension, its `OpenWithProgids` value, and Anvil's `Capabilities` and `RegisteredApplications` entry. The entry exists while Anvil opens at least one extension. Windows does not let an app make itself the default. "Set as Default" opens Anvil's page in Windows Settings, where the user does that.

The registry stores the executable's path. After a move, the user checks the types again. `system.get_registry_values`, `set_registry_value`, `delete_registry_value` and `delete_registry_key` read and write `HKEY_CURRENT_USER` only.

Tests set `plugins.file_types.root` to a private key, so they never change the user's file types. Run `ui/file_types_dialog.lua` after changes. Check the `file-types-dialog` render scenario after visual changes.

It uses fixed rows and does not read the registry.

## Wallpapers

A native worker decodes the wallpaper (`image_decode` job, `src/image_decode.c`). The UI thread never decodes it. A Window shows its plain background until the image arrives.

The `imagedecoded` event wakes the event loop. The decoder uses libjpeg-turbo with its SIMD code, which needs NASM. It decodes at 1/2, 1/4 or 1/8 scale when the result still covers 80% of the drawn size.

A larger Window decodes again, and the smaller image shows until then. Wallpapers are baseline JPEGs. A progressive JPEG decodes about three times slower, and PNG does not decode.

Convert a new image with `jpegtran -copy none -optimize`, which does not change its pixels. Meson's NASM check finds MSVC's `cl.exe` when Visual Studio is on `PATH`, then fails on Git's `link.exe`. The BAT files use a clean MSYS2 `PATH`.

An agent shell must remove Visual Studio from `PATH` before it builds. Run `ui/wallpaper.lua`, `anvil:image-decode` and the `shell-empty` shell probe after changes.
