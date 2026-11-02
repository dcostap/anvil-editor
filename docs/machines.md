# Machines: remote Projects, shared Terminals and the Companion app

This document is a plan. Nothing in it is shipped. It records the agreed design, so the work can grow in small steps without a redesign.

## Goal

- Open a Project, the Scratch Project or a Pi session that runs on another PC, and work on it as if it were local.
- See and control the Terminal Sessions of any of your PCs, including Pi, from another PC or from a phone.
- Use a native Android app to browse your PCs' Projects, read their files, edit Markdown and follow Pi.
- Edit a Markdown vault that is stored on the phone itself.

Not everything ships at once. The rule for each step is: it must not make a later step much harder.

## Out of scope

- **Pixel or frame streaming.** It is unusable at phone size. Hardware video codecs blur coloured text. Renderer command streaming stays a fallback idea only.
- **Credentials on a random PC.** Pi on such a PC needs inference without your real logins. That problem is separate from Anvil. See [Later: Pi on a random PC](#later-pi-on-a-random-pc).
- **An Anvil port to Android.** The phone app is a native Android app. See [Why a native app](#why-a-native-app).
- **Other people.** The first versions have one owner. Access for a second person is a later design.
- **LSP.** Anvil's LSP code will be removed, so this plan does not include it.

## Terms

`CONTEXT.md` defines these terms. "Remote" already means **Remote POI Source** there, so this plan does not use "Remote" as a term.

- **Machine:** a computer that runs Anvil and that you paired. Your phone is also a Machine for its local vault.
- **Swarm:** all your paired Machines.
- **Companion:** the native Android app. Its name on the phone is Anvil.
- **Client:** a desktop Anvil or a Companion that is connected to a Machine.
- **Controller:** the one Client that sets a Terminal Session's size, sends its input and answers its terminal queries.
- **Viewer:** a Client that shows a Terminal Session that another Client controls.

## Main rule: one Machine API for all Clients

Each Machine runs `anvil serve`. It is the same executable, without a UI. Desktop Anvil, when it opens a Project on another Machine, and the Companion both use this one API.

Do not make a separate API for the phone. It would become a second product that drifts from the first. With one API, each new server feature is available to both Clients.

### Services

The API is a set of services. Each service matches a part of Anvil, not a screen of a Client.

| Service | What it gives |
|---|---|
| Machine | Identity, the Machine's OS, pairing, the available tools, and the Machine's Project list (see [State](#state)) |
| Files | File list snapshots, bounded reads, conditional whole-file writes, stat, and change hints |
| Search | Text search as a stream of matches from `rg` on the Machine |
| Git | Structured operations: status, branches, diffs and logs |
| Terminal | The Terminal Session list, attach as Controller or Viewer, snapshot then output, input, resize |
| Agent | Agent Status, Pi conversations, and send, wait and interrupt for a Pi in a Terminal Session |
| Index | Symbols, and Markdown links and backlinks |
| Process | Starts a configured tool, such as a formatter, and carries its standard input and output as a byte stream |

Git stays structured. Do not use the Process service as a generic command runner for Git.

A later Live Document service has a reserved name. See [Shared editing](#shared-editing).

## Ownership

The Machine is not only a file server. Terminal Sessions and Pi live there. Each operation has one clear owner:

- **The Terminal host owns its Terminal Session.** This is true today: each session is an `anvil --terminal-session` process that lives on after the editor closes. The host accepts several Clients (see [Terminals on many devices](#terminals-on-many-devices)).
- **The Machine owns Machine operations.** The Terminal, Agent, Files, Search, Git, Index and Process services work with no Client connected. They need no View.
- **A Client owns editor operations.** Operations such as "open a Pane" or "show this file" need a UI. Each such request names its target Client. With no Client connected, the request fails with a clear error.
- **Anvil on the Machine itself is also a Client.** If you sit at PC A, your local Anvil uses the same Terminal hosts and the same Machine operations as a Client on PC B. PC A has no second owner.

Two desktops can open the same Project on a Machine. Each one has its own Buffers and Views. They meet only through the Machine's files and Terminal Sessions.

### State

Each piece of state also has one owner:

| State | Owner | Notes |
|---|---|---|
| Known Project paths | Machine | Saved on the Machine. Clients read this list. |
| Project configuration: extra Project Paths and the search and index settings | Machine | The indexes and searches run with no UI, so they need this. Today, extra Project Paths are Workspace state (`data/core/project_paths.lua`). |
| Terminal records and saved screens | Machine | As today |
| Loaded state, Windows, Panes and Workspace layout | Client | Each Client saves its own |
| Buffers, unsaved text and recovery records | Client | See [Recovery](#recovery) |

The Project Sidebar model today describes one shell's Windows, Project processes, Pane reports and Dormant records (`src/anvil_shell.c`). The Machine does not send that model. A Client builds its Sidebar from the Machine's Project list plus its own loaded state.

### Pi control

Today, `core.control` mixes the two kinds of operation, and it depends on Views. For example, `terminal` raises "Terminal Session has no View in this Project" (`data/core/control.lua:234`), and `launch` opens through a Terminal View. `control_runtime.lua` publishes the discovery files based on which Project process owns the View.

On a Machine, split `core.control` into two parts:

- **Machine operations:** start a Terminal or Pi, read its state, send, wait and interrupt. `anvil serve` answers these, so they work with no Client.
- **Editor operations:** `open_file`, `pane` and `workspace_state`. A request that names a Client goes to that Client. Other requests go to the Client that the user used last, as an external launch opens in the Anvil Window that the user activated last. With no Client, they fail with a clear message.

`anvil serve` publishes Pi's discovery files on the Machine, so their owner does not depend on a View.

`agent_read` gives status and bounded task results today. It does not give the conversation history. A chat view reads Pi's session file through the Files service.

### Server lifetime

- Anvil starts `anvil serve` when it starts. One server runs for each user folder. If a server already runs, Anvil uses it.
- The local shell connects to the server like any other Client.
- A server that Anvil started ends when Anvil ends. Terminal Sessions keep running, as they do today, but other devices cannot reach them until Anvil starts again.
- For a Machine that other devices must always reach, the user runs `anvil serve` alone. That server runs without a UI and does not end with Anvil.
- Without a Project list, the server serves the Projects of its user folder's Sidebar: Scratch and the recent Projects.
- The server listens on loopback only. Other devices reach it only through a forwarder that the user sets up, such as Tailscale Serve, and only after pairing. So it needs no separate setting for connections from other devices.
- The server uses port 7690 when it can, so a forwarder's configuration stays correct across restarts.

## Identity

### Machine-qualified identity

Two Machines can both have `C:\Projects\notes`. Today, the shell, Workspace storage and control routing identify a Project by its path:

- `src/anvil_shell.c` finds a Project's identity by opening a local folder.
- `src/shell_state.c` saves Project paths.
- `data/core/control_server.lua` routes Projects by path.

Every boundary between processes must use a Machine ID plus a path. This includes the Sidebar model, Shell App State, Workspace storage keys, the Scratch Project, Pane requests and control routing. Inside one Project process, paths stay native paths, so the code needs no URIs.

### Path rules

Lua's path functions in `data/core/common.lua` follow the Client's OS. A Windows Client cannot apply Windows rules to Linux paths.

Terminal hosts are Windows-only today, so the first Machines are Windows. The Machine service reports its OS. A desktop Client refuses a Machine with other path rules until a real need appears. The Companion never reads a Machine path as a path on the phone.

## Protocol

### Envelope

- Each message has one small envelope with a protocol version.
- A Client and a server with incompatible versions refuse to connect, with a clear message.
- Optional features are listed at connect. A Client uses only what the server lists, and hides the rest. Either side can grow without the other.
- The protocol defines unknown-field rules, error replies, message size limits and cancellation.
- Terminal snapshots carry the ID and version of their format. A Ghostty update can change the format.
- Cross-version tests use stored message fixtures.

### Rules for each kind of data

The four kinds of data have different rules.

1. **File list.** A snapshot with a generation. A change to the set of files gives a new snapshot. Today, `data/core/project_files.lua` scans again when the set of files changes, and increments the generation after each successful scan.
2. **File content.** Each read returns a content version: a hash of the bytes. A file list generation says nothing about file text. A text change does not change the file list.
3. **Change hints.** A hint says "this path changed, look again". A Client drops its cached text or metadata for that path and reads again when it needs it. It never patches state from a hint.
4. **Streams.** Each service has its own simple recovery rule. There is no common replay system.
   - **Terminal:** a snapshot with an exact boundary in the output. See [Handoff](#handoff).
   - **Search:** a request. After a disconnect, the Client cancels it and runs it again.
   - **Process:** after a disconnect, the server ends the process. Its owner starts and sets it up again.
   - **Live Document:** deferred.

Each server start gets a new **epoch**. A generation alone is not enough, because it starts at zero again after a restart.

### Reconnect

A Client that was disconnected missed the change hints. A file can change without a change to the file list or the epoch, for example when Pi edits it. So at each reconnect, the Client does these steps:

1. It drops its cached file text and metadata.
2. It gets a new file list snapshot.
3. It checks the content version of each open file. A clean Buffer whose file changed reloads. A dirty Buffer merges (see [Merges](#merges)).
4. It asks for the result of each open save (see [Save IDs](#save-ids)).

The Client keeps dirty Buffers, merge bases, open saves and recovery records. A new epoch never discards them. This needs no log of old hints.

Start with whole file list snapshots. Send differences only if a measurement shows that snapshots are too large on a real link.

### Positions

Text ranges in the protocol count UTF-8 bytes, as Anvil does. Android counts UTF-16 units, so the Companion converts in one place, at its JNI boundary. Test the conversion with Spanish text and emoji.

File writes replace whole files, so they need no ranges. Ranges appear first in search matches and index results.

### Metadata states

A Client's copy of the file list is not a full stat cache. The scan applies ignore rules, and Project Paths outside the root, generated files and files opened directly can be missing from it. For each path, the copy knows one of four states:

- **present**
- **absent**
- **unknown:** not in the copy
- **stale:** a hint arrived after the copy was made

"Not in the copy" never means "does not exist". The server confirms each create, overwrite, rename and delete.

## Writes

### Conditional whole-file writes

- A write sends the whole file's bytes and the content version that the Client read last.
- The server writes only if the file still has that version. Otherwise it returns the current bytes and version, and the Client merges (see [Merges](#merges)).
- The server puts the writes of its own Clients in order. It cannot stop Pi, Git, formatters or other editors on the Machine from writing between its check and its write. That window stays, as it does on a local disk.
- Encodings and line endings follow the Buffer's normal load and save rules. The version identifies bytes on disk, not Buffer text.

### Save IDs

A server can complete a save and lose its reply. A Client can also keep typing while a save is open. So each save carries:

- a save ID
- the base content version
- the Buffer revision that it sent

The reply gives the new content version. An acknowledgement marks only the sent revision as saved, not the current Buffer.

After a reconnect, a Client with an open save asks for the result of its save ID. If the server does not know it, the Client compares the file's current version with the version of its sent bytes. It never sends an old open save over newer saved work.

### Merges

Today only clean Buffers reload as edits. The dirty-Buffer merge is step 3 of [Shared editing](shared-editing.md#order-of-work).

- Read-only access ships first.
- Writes then ship with today's conflict prompt for dirty Buffers.
- Smooth editing by several Clients needs the dirty merge. It becomes a required step when the Companion edits files that desktop Anvil also has open.

### Recovery

A disconnect can last hours. A crash, or Android when it stops a background app, then loses the edits that only memory holds. Both Clients keep a recovery record for each Buffer with unsaved text. The desktop keeps it under `USERDIR`. The Companion keeps it in its app storage.

A record holds:

- the Buffer text
- the merge base and its content version
- the encoding and line endings
- each open save ID, with the revision and bytes that it sent

The Client writes the record when the text changes, and deletes it when the Machine confirms the save. At the next start, it restores the Buffer and follows the [Reconnect](#reconnect) steps.

Remote writes do not ship without recovery. Local Projects keep today's choice: no safety copy (see [Shared editing](shared-editing.md#risks-to-keep-in-mind)).

## Authority and pairing

### Two levels

The first version has one owner and two levels for each paired device:

- **View:** read the Projects list, files, Git state, Agent Status and Terminal screens.
- **Full control:** everything else. This includes file writes, Terminal input, Pi control and the Process service.

The levels are not finer, because finer scopes do not hold. Terminal input runs any command. Pi can read, write and run anything. A file write can change scripts and configuration. Full control therefore gives the full power of the user account on that Machine.

Full control covers all Projects on the Machine. Limits for each Project are a later design.

### Pairing

- The Machine shows a short pairing code. The code works one time, for a few minutes, with a limited number of attempts.
- The paired device stores its token in the OS's protected storage: Android Keystore on the phone, DPAPI on Windows.
- Revocation removes the token and closes the device's open connections and streams at once.
- Machines reach each other through Tailscale or another private network. The server listens on loopback, and Tailscale Serve exposes it. The network is not the authority: each request carries the device token, because any local process can reach loopback.
- Each identity has a person field and a device field. Only the owner exists at first.

Reference: t3code uses pairing with scoped sessions, read-only guest links and an optional cloud relay. Its server owns all execution, and each client is a thin view.

## Desktop: Projects on another Machine

This follows the model of VS Code Remote. The UI stays local. The Project's files and processes are on the Machine.

### What stays local

- Windows, the Sidebar, Panes and Views
- Buffers, undo, selections and unsaved text
- Themes, keymaps, config and plugins
- Tree-sitter parses of open Buffers, and Live Preview

### What runs on the Machine

- Buffer reads and writes
- The file list, the folder watcher and the native indexes: `project_file_manifest.c`, `git_status_index.c`, `markdown_vault_index.c` and the tree-sitter symbol index
- `rg`, Git and formatters
- Terminal hosts, with their records and saved screens

### One Machine for each Project process

Each hosted Project process uses exactly one Machine. A Project on another Machine is a separate Project in the Sidebar, with a Machine-qualified identity.

### The file seam (`core.fs`)

Anvil's file access is synchronous and path-based. VS Code was asynchronous and URI-based from the start. This is the main difficulty.

- `core.fs` holds the Project content functions for a Machine. Each Project content call site moves to it when its service exists.
- **The Machine guard** (`core.machine_guard`) protects a Project process on a Machine. The raw file functions refuse a relative path and a path inside the Project's roots. All other absolute paths are local state, such as `USERDIR`, `DATADIR`, `TEMP` and system fonts.
- This rule is safe because a Machine serves only paths inside its Projects (`outside_project`). A Client has no correct reason to name another Machine path.
- Local state needs no change. A Machine path with the same spelling as a local folder is inside the Project's roots, so the guard refuses it. An example is the Machine's Scratch Project under a `USERDIR` path.
- The guard wraps `io`, `os`, `dofile`, `loadfile`, the path functions of `system`, `process.start` (its working folder and arguments), `encoding.detect`, image loading and saving, font loading and the Terminal's working folder.
- Worker jobs, Lua or native, are refused when their payload names a Project path. Workers get their paths from the payload, so this covers the native indexes and `src/worker_pool.c`.
- This guard stops mistakes. It is not a security boundary. A worker that finds a Project path in some other way, such as from a file that it reads, is not stopped.

#### Audit result

Every call site of the raw file functions in `data/` was read. Most touch local state: storage, logs, settings, plugins, themes, fonts, Terminal records, the updater, IPC, performance tools and the test framework. These Project content sites remain, by feature and by the step that moves them:

| Feature | Call sites | Step |
|---|---|---|
| Opening a Project | `core/init.lua` (folder checks, `system.chdir` to the Project), `core/project.lua`, `core/project_paths.lua`, `plugins/project_paths`, the `.anvil_project.lua` module (`loadfile`, `autosave_fast`, `autosaveonfocuslost`) | 5 |
| File list and watcher | `core/project_files.lua` with its worker and the native `project_file_manifest` job, `core/dirwatch.lua`, `plugins/autoreload.lua`, `plugins/folder_counts.lua` | 5 |
| File Tree | `plugins/filetree/init.lua`: listing and stats; create, rename, copy, delete and Recycle Bin | 5, writes in 6 |
| Fuzzy Searcher | `plugins/fuzzy_searcher/init.lua` and `search.lua`: folder listing, previews, `rg`, new files | 5, writes in 6 |
| Open, new, rename and delete file | `core/init.lua` (`open_file`), `commands/core.lua`, `commands/files.lua`, `commands/text.lua`, `rootpanel.lua` drops, `widget/filepicker.lua`, `common.is_binary` | 5, writes in 6 |
| Previews and locations | `poi_preview.lua`, `editor_file_pois.lua`, `text_poi_locations.lua`, `file_context.lua`, `bookmarks.lua` with its worker, `plugins/tabular_data_preview`, `plugins/intellij_actions.lua` | 5 |
| Images | `imageview.lua`, `image_animation.lua`, `image_overlay.lua`, `markdown/images.lua` | 5 |
| Markdown | `markdown/vault_index.lua` with its native jobs, `markdown/rename_links.lua`; writes in `markdown/attachments.lua` and `markdown/live_render.lua` | 9, writes in 6 |
| Symbol index | `treesitter/symbol_index.lua` with the native `treesitter_project_*` jobs | 9 |
| Git | `plugins/git`, `plugins/git_view.lua`, `plugins/file_git_status.lua` with the native `filetree_git_status_index` job, `plugins/gitdiff_highlight`, `workers/changes_baseline.lua` | 9 |
| Terminal | `plugins/terminal.lua` (working folder), `core/control.lua` (`cwd` of a launch) | 7 |
| Formatters | `plugins/document_format.lua` | 10 |

The Buffer load and save flow is clean: the Buffer tests on a Machine run with the guard on. In a Project process on a Machine, the Markdown vault index does not track Buffers until the Index service exists.

### Local metadata copy

UI code reads small data often, such as "does this path exist" or "is it a folder". A network round trip in each frame is not acceptable. So each Client keeps a local copy of the Machine's file list and the metadata it needs, with the [metadata states](#metadata-states). UI-thread metadata calls read the copy. File text is fetched only when needed.

### File Search, Text Search and previews

The picker's screen code does not change. Only its data sources change.

| Action | Network traffic | Delay |
|---|---|---|
| Typing in File Search | None. Fuzzy matching runs on the local copy of the file list. | None |
| Text Search query | The query out, the matches back as a stream | One round trip, plus `rg` time |
| Selecting a row to preview | A bounded part of the file, then cached. Nearby rows can be fetched in advance. | One round trip |
| Opening a file | The file's bytes, one time | One round trip |
| Typing in an open file | None | None |
| Saving | The whole file, as a conditional write | In the background |

`stat_paths` already takes many paths in one call. On a Machine it becomes one request.

Previews read at most a fixed number of bytes and can be cancelled. The server applies Anvil's binary rule (`common.is_binary`) before it sends text.

### Formatters

A formatter gets the text of one Buffer revision. Its result applies only if the Buffer still has that revision.

### Indexes and unsaved Buffers

Symbol search today merges disk results with the text of open Buffers, and hides old disk entries for files with local changes (`data/core/treesitter/symbol_index.lua`). With a Machine, the index runs on the Machine. The Client still adds its open Buffers on top and hides old results for files that it changed.

### Pi in a Project on another Machine

Pi runs in a Terminal Session on the Machine, so its tools act on that Machine. Pi needs no change. Its control requests go to `anvil serve` (see [Pi control](#pi-control)).

### Leaks to the wrong PC

These features act on the local PC by nature. For a Project on another Machine:

- **The clipboard works as usual.** Buffers are local, so copy and paste move local text. A Terminal program's clipboard write goes to the Controller's clipboard.
- **These do nothing and show a short message:** native file dialogs, drag and drop of files from the local PC, and Show in File Explorer. Menus hide Open with the default app. Anvil's own pickers, such as File Search, still work, because they read the Machine's file list.

### Disconnects

- A disconnect does not discard the live Buffer. Its recovery record keeps it through a crash (see [Recovery](#recovery)).
- Saves, searches and Terminals stop until the link returns. Reconnects follow the [Reconnect](#reconnect) steps.
- The Pane Status Bar shows the Machine as offline.
- Closing a Project that has unconfirmed saves asks first. Its edits did not reach the Machine.
- Terminal Sessions keep running on the Machine, and attach again with a snapshot.

### Bootstrap

A Machine needs `anvil serve` and its tools. Anvil bundles `rg` on Windows (`data/core/project_files.lua`). Git is not bundled: the Git plugin uses `git` from `PATH` or a configured path (`data/plugins/git/backend.lua`). Formatters are also external. The Machine service lists which tools are available, and a Client hides the features that need a missing tool.

The user installs Pi and its packages on each of their PCs.

## Terminals on many devices

### One size for each Terminal Session

A Terminal Session has one size in rows and columns. Programs draw for that size. A desktop Pane can be 200 columns wide, and a phone about 45. Two sizes cannot both be correct.

If each device forced its own size, each switch would make the program redraw. A TUI places text at fixed positions, so output that it drew at 45 columns stays narrow in the history. A width change also makes ConPTY and the Terminal View reflow lines differently.

### One Client answers queries

Programs ask the terminal questions: the cursor position, the colours, light or dark mode, keyboard modes. The terminal answers through the program's input. Today, answers and typed input use the same route (`src/api/terminal_native.c`). If two Clients answered, the program would get two answers, and the second one could show as stray text.

### Controller and Viewers

- Each Terminal Session has at most one **Controller**. It sets the size, sends input and answers queries.
- **Viewers** show the Controller's screen at its size. They scale it to fit, with zoom and panning on the phone. A small bar shows the Controller's device and a Take Control button.
- Viewers do not answer queries and have no other side effects, such as clipboard writes.
- **Input takes control.** On the desktop, typing in the Terminal takes control. On the phone, a tap that opens the keyboard takes control. Take Control does the same.
- When no Client is connected, the session keeps its last size. Queries then get no answer, as they do today when no editor is attached (`host_reader` in `src/terminal_host.c`). ConPTY itself answers cursor-position requests.
- Viewers are not blurred. A Viewer is most useful to check whether Pi still works or asks a question.

### Handoff

The host gives control. Each grant has a new control generation. The host rejects input, resize and answers with an old generation, so late messages from the old Controller cannot reach the program.

A handoff has a fixed order:

1. A Client asks for control. The request names the control generation that the Client saw last. If the action that took control was a keystroke, the request carries it.
2. If that generation is not the current one, the host refuses. So two requests cannot both win. The Client can try again.
3. The host makes a new generation and resizes to the new Controller's size.
4. The host sends a role record to each Client at that place in the output. It names the generation, the Controller's device and the size. Each Client resizes its screen there, as the host's model did. ConPTY then repaints the new grid. So a handoff or a resize sends no snapshot.
5. The keystroke that took control follows the request on the same connection. So it reaches the program only when the request wins.

A query that comes before the handoff goes to the old Controller. If the old Controller does not answer before its generation ends, the query stays unanswered. This is the same as today, when no editor is attached.

If the Controller disconnects, the session has no Controller until a Client asks. A Controller that reconnects with an old generation is a Viewer.

A Client on the host's own PC takes control when it attaches, if the Controller is also on that PC. One PC has one user, and a Pane move attaches before the old View's detach arrives. A remote Controller keeps control until someone types.

The host orders an attach snapshot and the output after it with its model lock. Role records use the same lock.

### Closing

A Pane Close on one device does not take the shell from another device. While another Client is attached, a close or an end only detaches the closing Client, and Pane Close asks no question. The last close ends the shell, as on one PC. Role records count the attached Clients, so each Client knows if others show the session.

### Changes to the Terminal host

- The host accepts up to 8 Clients: one Controller and the Viewers. Each Client has its own pipe and an 8 MiB queue. The Controller's queue has a 10-second stall timeout.
- A detached host that is not busy and has no new output for 10 minutes ends. A busy host, such as a working Pi, keeps running.
- A Viewer whose queue is full is dropped and attaches again with a snapshot. A slow Viewer never stalls the Controller.
- The host already keeps the Ghostty screen model, so Viewers only display it.
- Ghostty snapshots contain no images. A Viewer that joins sees no inline images until the program sends them again. Reconnects have the same limit today.
- Terminal hosts are Windows-only today, because they use ConPTY. Other host systems need a PTY backend.

## The Companion app

### Why a native app

An Anvil port would reuse the parts that matter least on a phone. A native app gets the hard parts from the platform:

| Part | Anvil port | Native app |
|---|---|---|
| Phone keyboard: swipe typing, autocorrect, accents | Hard. SDL handles it poorly. | Free with Android text fields |
| Selection handles, fling scrolling, long press | Must be built | Free |
| Lifecycle and background saves | Must be built | Normal Android patterns |
| Rendering | CPU software renderer | The platform's GPU text rendering |
| Live Preview logic | Reused | Written again, except the shared C modules |

### What the Companion does

The Companion is a Client for your Machines, not only a Markdown editor. Its sections follow the services:

Machines → a Machine → Projects, Terminals and Agents → a Project → Files, Search, Git and Terminals.

Each viewer is a separate module: a code viewer, a Markdown editor, a Terminal view and an agent chat.

### Repository

The Companion lives in `android/` in this repo. A protocol change then touches the codec, the server and the Companion in one commit, and the Companion uses the same dependency pins and patches as the desktop.

- `android/` is a Gradle project. Its CMake build, through the NDK, compiles the shared C files from `src/` and `subprojects/`. It copies no files.
- The Meson subprojects download at configure time. A script runs `meson subprojects download` before the Android build. Check that this also applies the wrap patches, such as `tree-sitter-markdown-scanner-state-bounds.patch`.
- Meson does not read `android/`. The release workflow runs only for version tags, so Android changes start no desktop build.
- Android build outputs go in `.gitignore`.
- Stored protocol fixtures are shared by the desktop tests and the Companion tests.
- Add an Android section to `AGENTS.md` when `android/` exists.

### The phone as a Machine

A vault on the phone is a Project on the phone's own Machine. The Companion runs the Files, Search and Index services in its own process, with the same interface. Local and remote vaults then use one code path.

- Files are in a normal folder. Use the "All files access" permission. Google Play restricts it, but an installed APK can use it. Do not use document picker URIs, because they are not paths.
- Android blocks binaries that an app downloads. It allows binaries inside the APK's native library folder. So the APK can include `rg` or Git if a feature needs them. A vault of a few thousand notes does not need `rg`.
- For offline editing of a PC's notes, keep a Git clone or a synced folder on the phone as a local vault. That is sync, not part of this plan.

### Unsaved text on the phone

Android can stop a background app at any time. The Companion keeps a [recovery](#recovery) record for each unsaved Buffer, as the desktop does. Without it, the Companion does not edit files.

### Agents on the phone

The best phone view of Pi is not its TUI. It is a chat view made from Pi's session file, with Agent Status and the Send and Interrupt operations. It fits any screen and has no size problem. The real TUI is still available through the Terminal service.

### What is shared in C

Shared C modules include no Lua headers. A binding in `src/api` exposes each one to Lua, and a JNI binding exposes it to the Companion. See "C and Lua" in `AGENTS.md`.

- The protocol codec, so both ends agree on the format
- The Terminal model: libghostty-vt. t3code runs it on Android too. This does not prove that Anvil's own bindings and snapshots build for Android.
- Tree-sitter and the highlight queries from `data/treesitter`, so code has the same colours
- `fuzzy.c`, so file search ranks the same
- The Markdown modules `markdown_parser.c` and `markdown_extensions.c`
- The text merge engine, after its port (see [Merges](#merges))

"No Lua headers" does not mean "ready for Android". `markdown_parser.c` uses the language registry, which lists all grammars, and SDL's timer and atomics. `markdown_vault_index.c` also uses the file manifest, snapshots, `fuzzy.c` and SDL, and it reads files. Split its file loading from its index work before the Companion uses it.

The Android UI is native and is not shared.

### Markdown logic to port to C

The editing rules are Lua today, in `data/core/markdown`. Under the C policy, these are port candidates. Each one becomes a module that takes text, a parse tree and the caret, and returns edits or styled ranges. Port one only when the Companion needs it. The list is not an order:

1. Links and anchors: `links.lua`, `parser.lua`, `anchors.lua`. They are pure and small.
2. Link rename edits: `rename_links.lua`
3. The table model and formatting: `serialize_model` and `pad_cell` in `tables.lua`
4. Block formatting rules: the prefix rules in `format.lua` for headings, lists, quotes and callouts
5. The Live Preview decisions in `live_render.lua`: which ranges to hide and which to style at the caret

The first Companion test needs only the presentation rules for headings, bold text and wikilinks. It can write them in a quick form. That code is thrown away after the test.

Item 5 is also part of the layout pipeline target in `AGENTS.md`. The desktop draws the styled ranges with its own renderer. The Companion applies them as Android text styles. Wrapping and row heights stay separate on each platform.

## Shared editing

[Shared editing](shared-editing.md) has a separate plan: a reload engine, Disk Conflicts, and later shared notes through a sync tool such as Nextcloud, and then live editing. That plan is not part of this one. The two plans meet here:

- The reload engine also merges changes from other Clients. If the Companion saves a note on a PC while desktop Anvil has it open, desktop Anvil sees a changed file and reloads it.
- Several Clients that edit one file need the dirty merge (step 3 of that plan) and its C merge module. See [Merges](#merges). Companion editing therefore makes step 3 required.
- Live Document is only a reserved service name. Ordered messages and a range format do not keep concurrent edits by themselves. Two inserts at one place need transform rules. Before that service starts, it needs:
  - transform rules for concurrent edits
  - an ID for each edit
  - caret mapping
  - undo that skips other people's edits

  The transform rules are shared C. The Buffer side stays in Lua until it has a clean seam. Normal file saves never use this machinery.

## Pi on your Machines

On your own PCs, install Pi and log in separately on each one. Do not copy `auth.json`: OpenAI login refresh tokens rotate, so two PCs that share one login can lock each other out. A Pi in a Terminal Session then works on its own Machine, with its own login.

### Later: Pi on a random PC

This is deferred. The options, from simple to complex:

1. An OpenRouter key with a credit limit, in a temporary Pi folder (`PI_CODING_AGENT_DIR`). Delete the folder and the key after the visit.
2. A Codex login with device code. `/logout` does not revoke the login at the provider.
3. A token proxy on a VPS. Pi's `models.json` points the provider's `baseUrl` to the proxy, with a placeholder key. The Codex provider decodes its token as a JWT for the account ID, and it can use a WebSocket, so the proxy needs a special adapter.
4. Forwarding through the Machine link to your own PC, like SSH agent forwarding. This needs the link from this plan.

## Risks

- About 50 Lua files read Project content. The guard finds a missed site only when it runs, so each service needs tests with the guard on.
- Synchronous file calls on the UI thread must change before a Project can run on a Machine.
- Machine-qualified identity touches the shell, Shell App State, Workspace storage and control routing.
- The POSIX branches of the native code have no CI job. They may be broken.
- The Companion's text styling must stay correct while Gboard edits text near hidden Markdown syntax.
- Position conversion between UTF-8 and UTF-16 is a source of off-by-one bugs.
- A Terminal host with several Clients must not let one slow Client stall the others.

## Order of work

Start with one thin vertical slice. It tests the hardest assumptions before the large audit.

### Step 0: decisions

These decisions come before code. This doc answers identity, ownership and the authority levels. The answers below are also decided.

- **Server language.** The transport and the message codec are C, because the Companion uses them too. The server runs Anvil's Lua without a window, in the same executable. So it reuses `project_files.lua`, the worker pool, `rg` and the Git plugin. New server logic that needs no Lua objects goes in C, as "C and Lua" in `AGENTS.md` says.
- **Message format.** Each frame has a small binary header: type, request ID and length. Its body is JSON. File contents and Terminal output travel as raw bytes after the JSON. The `hello` exchange carries the protocol version.
- **Machine ID.** A random ID that the server makes at its first start and saves in `USERDIR`. A path or a PC name can change, so the ID uses neither. One server runs for each executable and user folder, as the shell does (see "Launch mode" in `AGENTS.md`). So a second Anvil install with its own user folder is a second Machine.
- **Repository.** One repo. See [Repository](#repository).

### Desktop

1. **Loopback slice.** `anvil serve` on the same PC, with one Project and one authenticated read. Done: see "Machine server" in `AGENTS.md`.
2. **One file, end to end.** Done: see "Machine server" in `AGENTS.md`. The Buffer load and save flow uses a minimal `core.fs`. The test server maps its paths into a private folder (`--test-root`), and the tests fail if code reads the Client's copy. They cover an open, edit and conditional save, a conflict, a save with an unknown result, a disconnect with a change on the Machine and a reconnect, and a crash with a restart from the recovery record. The record keeps the base version, not the base text: the dirty merge adds the text.
3. **Pairing and transport** between real PCs, before any service that runs commands. Pairing codes, device tokens, View and Full control, revocation and a fixed port exist: see "Machine server" in `AGENTS.md`. **Done.** On 2026-10-31, a second Windows PC paired through Tailscale Serve with the standalone `anvil.exe`. The Machine listed it, then revoked it. The test showed that an expired code gave the same error as a wrong code, so an expired code now gets its own error.
4. **The full call-site audit**, then the Machine guard. Users see no change. Done: see [The file seam](#the-file-seam-corefs). Each Project content site moves to `core.fs` with its service, not before, because most must also become asynchronous.
5. **Files and Search services**, the Machine's Project list and Project configuration, the local metadata copy, and the picker data sources. Read-only Projects on another Machine ship here. Done: see "Machine server" in `AGENTS.md`. Anvil starts its own Machine server, or uses the one that runs for its user folder. `machine:open_project` opens a Project of a paired Machine as a separate Sidebar Project with a Machine key. File Search, Text Search, previews, the File Tree, images and Buffer saves work. The Project module (`.anvil_project.lua`), Git, the symbol index and the vault index wait for step 9. Size filters and the preview size limit do not work yet, because the metadata copy has only the path type.
6. **Writes** with recovery and today's conflict prompt. Done: see "Machine server" in `AGENTS.md`. `core.file_ops` makes, moves, copies and deletes files and folders on the Machine, also to its Recycle Bin. The File Tree, File Search's create row, Rename, Delete, New Directory and Markdown attachments use it. A Buffer that the user discards deletes its recovery record. A wikilink to a missing note does not create the note on a Machine, because it needs the vault index (step 9).
7. **Terminal service** with Controller and Viewers. In progress: a Terminal host accepts several Clients with one Controller, and the Machine server carries a session's records to a remote Client. A remote session attaches again with a snapshot after a disconnect, and a View device cannot type. A Project on a Machine starts its Terminals on the Machine, and the Sidebar lists them while the Project is loaded. A Pane Close ends the shell only when no other device shows it. The desktop Viewer bar, with the Controller's device and Take Control, does not exist yet. See "Machine server" in `AGENTS.md`.
8. **Agent service** and the split of `core.control`.
9. **Git and Index services**, when the first Client feature needs them.
10. **Process service** for formatters.

### Companion

The first test runs in parallel with the desktop work.

1. **First test:** in `android/`, a minimal NDK library with `markdown_parser.c` and its dependencies, and a Compose screen that edits a note with Live Preview for headings, bold text and wikilinks. Type into it with Gboard, with swipe typing and Spanish accents, while it hides and shows syntax at the caret. If the styles and the caret stay correct, the native approach works. Done: see "Companion (Android)" in `AGENTS.md`. On a phone with Gboard, typing, swipe typing and Spanish accents kept the styles and the caret correct. Gboard sent no composing region. The older Compose text field let the keyboard cover the tapped line, so the editor uses `TextFieldState`. Compose's word selection takes the punctuation before a word when a long-press moves. Live Preview does not cause it, and the real editor must handle it.
2. **Machines and Projects** with Agent Status, read only.
3. **Terminal view**, first as a Viewer, then as a Controller.
4. **Files and code** with highlighting, and File Search.
5. **Markdown editing**, on the phone and on Machines, with recovery. Editing on Machines needs step 3 of [Shared editing](shared-editing.md#order-of-work).
6. **Text Search and Git** views.
7. **Pi chat:** start Pi, send messages, read its session file.

Also measure the compressed size of a full file list snapshot for a large Project.
