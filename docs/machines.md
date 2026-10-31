# Machines: remote Projects, shared Terminals and the Companion app

This document is a plan. Nothing in it is shipped. It records the design that we agreed on, so the work can grow in small steps without a redesign.

## Goal

- Open a Project, the Scratch Project or a Pi session that runs on another PC, and work on it as if it were local.
- See and control the Terminal Sessions of any of your PCs, including Pi, from another PC or from a phone.
- Use a native Android app to browse your PCs' Projects, read their files, edit Markdown, and follow Pi.
- Edit a Markdown vault that is stored on the phone itself.

Not everything ships at once. The rule for each step is: it must not make a later step much harder.

## Out of scope

- **Pixel or frame streaming.** It is unusable at phone size. Hardware video codecs blur coloured text. Renderer command streaming stays a fallback idea only.
- **Credentials on a random PC.** Pi on such a PC needs inference without your real logins. That problem is separate from Anvil. See [Later: Pi on a random PC](#later-pi-on-a-random-pc).
- **An Anvil port to Android.** The phone app is a native Android app. See [Why a native app](#why-a-native-app).

## Proposed terms

These names are not in `CONTEXT.md` yet. Add them when they are accepted. "Remote" already means **Remote POI Source** in `CONTEXT.md`, so the plan does not use "Remote" as a term.

- **Machine:** a computer that runs Anvil and that you paired. Your phone is also a Machine for its local vault.
- **Swarm:** all your paired Machines.
- **Companion:** the native Android app.
- **Controller:** the one device that sets a Terminal Session's size, sends its input and answers its terminal queries.
- **Viewer:** a device that shows a Terminal Session that another device controls.

## Main rule: one Machine API for all clients

Each Machine runs `anvil serve`. It is the same executable in headless mode. It owns the Project's files, processes, indexes and Terminal Sessions on that Machine.

Desktop Anvil, when it opens a Project on another Machine, and the Companion are both clients of that server. They use the same API.

Do not make a separate API for the phone. It would become a second product that drifts from the first. With one API, each new server feature is available to both clients.

### Services

The API is a set of services. Each service matches a part of Anvil, not a screen of a client.

| Service | What it gives |
|---|---|
| Machine | Identity, pairing, and the Projects list (loaded and Dormant), from the Project Sidebar model |
| Files | File list snapshots with generations, read, conditional write, stat, and change hints |
| Search | Text search as a stream of matches from `rg` on the Machine |
| Git | Status, branches, diffs and logs |
| Terminal | The Terminal Session list, attach as Controller or Viewer, snapshot then output, input, resize |
| Agent | Agent Status, Pi conversations, and send, wait and interrupt. These are the `core.control` operations that exist today. |
| Index | Symbols, and Markdown links and backlinks |

A later Live Document service has a reserved place. See [Shared editing](#shared-editing).

### Capabilities

At connect, the server lists the services and the features of each service that it supports. A client uses only what the server lists, and hides the rest. Either side can then grow without the other.

This replaces the idea of "the same build on both ends". The Companion is a different program, so the API must be versioned and documented anyway. Desktop clients follow the same rule.

### Sync rule

All remote state uses the rule that `data/core/project_files.lua` already uses locally:

- A snapshot is the truth. Each snapshot has a generation number.
- Events are hints that mean "look again". A client never patches its state from an event.
- A client sends its generation at reconnect. If the server has a newer one, it sends a new snapshot.

The local code works this way today. `reconcile` checks changed paths on disk, and does a full scan when the set of files changes. A watcher overflow causes a full scan after 0.5 seconds without events. Each scan increments a generation, and subscribers discard older results.

Start with whole snapshots. If a measurement shows that they are too large on a real link, send differences with these rules:

- The server computes a difference by comparing two full snapshots, never from events.
- Each difference names its start and end generation and carries a hash of the result.
- A client applies a difference only if it holds the start generation and the hash matches. Otherwise it asks for a full snapshot.

### Message rules

- Messages carry plain data: paths, text, ranges, states. They are not shaped like Lua tables or other internals.
- One position unit for all text ranges. Anvil counts UTF-8 bytes, and Android counts UTF-16 units. Choose one unit for the protocol, and convert in one place on each client. Test the conversion with Spanish text and emoji.
- One edit format: a range, its new text, and the base version. File writes use it first. Live editing can use it later.
- One codec in C. Both ends encode and decode messages with the same C module, so they cannot disagree on the format.

### Identity and scopes

- Identity is a person plus a device. Pairing gives the device identity. A second person can join later without a protocol change.
- Each paired device gets scopes, for example: read files, write files, type in Terminals, control Pi.
- Revocation works for one device. A lost phone loses access without changes to other devices.

## Transport and pairing

- Machines reach each other through Tailscale or another private network. The server listens on loopback, and Tailscale Serve exposes it.
- Network identity alone is not enough. Any local process can reach loopback, so each request carries a pairing token.
- Pairing uses a short code that the user confirms on both devices. The token is stored per device and can be revoked.
- Reference: t3code uses pairing with scoped sessions, read-only guest links and an optional cloud relay. Its server owns all execution, and each client is a thin view.

Open question: does `anvil serve` run only while Anvil runs, or from login? A server from login keeps Terminals and Pi reachable when no Anvil Window is open.

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
- `rg`, Git, LSP servers and formatters
- Terminal hosts, with their records and saved screens

### One Machine for each Project process

Each hosted Project process uses exactly one Machine. Paths stay native paths on that Machine, so the code needs no URIs. A Project on another Machine is a separate Project in the Sidebar.

### The file seam (`core.fs`)

Anvil's file access is synchronous and path-based. VS Code was asynchronous and URI-based from the start. This is the main difficulty.

- Add a `core.fs` module for Project content. Its local backend calls the current primitives. Its Machine backend sends requests.
- Local state does not use `core.fs`. `USERDIR`, `DATADIR` and `TEMP` stay on the local disk.
- In a Project on another Machine, a raw primitive that touches a path outside those local folders raises an error. This guard fails closed, so a missed call site shows as an error and not as a read of the wrong disk.
- Plugins that call `io.open` directly on Project files hit the guard. They must move to `core.fs`.

Call sites in `data/` today:

| Primitive | Uses | Files |
|---|---|---|
| `system.get_file_info` | 232 | 65 |
| `io.open` | 105 | 57 |
| `os.remove` | 70 | 27 |
| `system.absolute_path` | 51 | 22 |
| `system.list_dir` | 31 | 20 |
| `process.start` | 23 | 14 |
| `system.chdir` | 14 | 6 |
| `os.rename` | 9 | 4 |
| `dirwatch` | 8 | 6 |
| `worker_pool` | 187 | 26 |

Many of these calls touch local state, not Project content. The first task is to classify each call site:

- Project content or local state
- synchronous or asynchronous
- UI thread or worker

The UI thread calls files synchronously in some places, for example in `data/core/buffer/init.lua` and `data/plugins/filetree/init.lua`. These must become asynchronous, or read the local metadata copy.

### Local metadata copy

UI code reads small data often, such as "does this path exist" or "is it a folder". A network round trip in each frame is not acceptable. So each client keeps a local copy of the Machine's file list and the metadata it needs, and refreshes it by the sync rule. UI-thread metadata calls read the copy. Large data, such as file text, is fetched only when needed.

### File Search, Text Search and previews

The picker's screen code does not change. Only its data sources change.

| Action | Network traffic | Delay |
|---|---|---|
| Typing in File Search | None. Fuzzy matching runs on the local copy of the file list. | None |
| Text Search query | The query out, the matches back as a stream | One round trip, plus `rg` time |
| Selecting a row to preview | One file's text, then cached. Nearby rows can be fetched in advance. | One round trip |
| Opening a file | The file's bytes, one time | One round trip |
| Typing in an open file | None. The Buffer is local. | None |
| Saving | The new text, as a conditional write | In the background |

`stat_paths` already takes many paths in one call. On a Machine it becomes one request.

### Writes

A write is conditional. The client sends the version that it last read. The server writes only if the file is still that version. Otherwise it returns the current text, and the client merges through the reload engine.

On a local disk, an external writer can save between Autosave's check and its write. On a Machine, the server does the check and the write as one step, so this race goes away.

### Pi in a Project on another Machine

Pi runs in a Terminal Session on the Machine, so its tools act on that Machine. Pi needs no change.

Pi finds Anvil's control server through discovery files. On a Machine, these files are on the Machine's disk. The server must publish them there and carry the control requests back to the client's Project process.

### Leaks to the wrong PC

These features act on the local PC by nature. Each one needs a decision when its Project is on another Machine:

- the clipboard
- native file dialogs
- drag and drop of files
- Show in File Explorer
- Open with the default app

### Disconnects

- Unsaved text stays in local Buffers and is safe.
- Saves, searches and Terminals stop until the link returns.
- Saves wait and retry. The Pane Status Bar shows the Machine as offline.
- Terminal Sessions keep running on the Machine, and attach again with a snapshot.

### Bootstrap

A Machine needs `anvil serve` and its tools, such as `rg` and Git. A Machine that runs Anvil already has them. Pi and its packages are installed by the user on each of their PCs.

## Terminals on many devices

### One size for each Terminal Session

A Terminal Session has one size in rows and columns. Programs draw for that size. A desktop Pane can be 200 columns wide, and a phone about 45. Two sizes cannot both be correct.

If each device forced its own size, each switch would make the program redraw. A TUI places text at fixed positions, so output that it drew at 45 columns stays narrow in the history. A width change also makes ConPTY and the Terminal View reflow lines differently.

### One device answers queries

Programs ask the terminal questions: the cursor position, the colours, light or dark mode, keyboard modes. The terminal answers by typing into the program's input. If two devices answered, the program would get two answers, and the second one could show as stray text.

### Controller and Viewers

- Each Terminal Session has one **Controller**. It sets the size, sends input and answers queries.
- **Viewers** show the Controller's screen at its size. They scale it to fit, with zoom and panning on the phone. A small bar shows the Controller's device and a Take Control button.
- **Input takes control.** On the desktop, typing in the Terminal takes control at once. On the phone, a tap that opens the keyboard takes control. Take Control does the same.
- When control moves, the host resizes to the new Controller and the program redraws. The old Controller becomes a Viewer.
- When no device is connected, the session keeps its last size.

Viewers are not blurred. A Viewer is most useful to check whether Pi still works or asks a question.

### Changes to the Terminal host

- Today the host accepts one client (`attach_client` in `src/terminal_host.c`). Each client has an 8 MB queue and a 10-second stall timeout. A detached host waits 10 minutes for a client.
- The host must accept several clients: one Controller and any number of Viewers. A slow Viewer must not stall the Controller. Give each client its own queue, and drop a Viewer that stalls. It attaches again with a snapshot.
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

The Companion is a client for your Machines, not only a Markdown editor. Its sections follow the services:

Machines → a Machine → Projects, Terminals and Agents → a Project → Files, Search, Git and Terminals.

Each viewer is a separate module: a code viewer, a Markdown editor, a Terminal view and an agent chat.

### The phone as a Machine

A vault on the phone is a Project on the phone's own Machine. The Companion runs the Files, Search and Index services in its own process, with the same interface. Local and remote vaults then use one code path.

- Files are in a normal folder. Use the "All files access" permission. Google Play restricts it, but an installed APK can use it. Do not use document picker URIs, because they are not paths.
- Android blocks binaries that an app downloads. It allows binaries inside the APK's native library folder. So the APK can include `rg` or Git, if a feature needs them. A vault of a few thousand notes does not need `rg`.
- For offline editing of a PC's notes, keep a Git clone or a synced folder on the phone as a local vault. That is sync, not part of this plan.

### Agents on the phone

The best phone view of Pi is not its TUI. It is a chat view made from Pi's session file, with Agent Status and the Send and Interrupt operations. It fits any screen and has no size problem. The real TUI is still available through the Terminal service.

### What is shared in C

Shared C modules include no Lua headers. A binding in `src/api` exposes each one to Lua, and a JNI binding exposes it to the Companion. See "C and Lua" in `AGENTS.md`.

- The protocol codec
- The Terminal model: libghostty-vt. t3code runs it on Android too.
- Tree-sitter and the highlight queries from `data/treesitter`, so code has the same colours
- `fuzzy.c`, so file search ranks the same
- The Markdown modules: `markdown_parser.c`, `markdown_extensions.c` and `markdown_vault_index.c`. These are already C with no Lua headers.
- The text merge engine, after its port (see below)

The Android UI is native and is not shared.

### Markdown logic to port to C

The editing rules are Lua today, in `data/core/markdown`. Under the C policy, these are port candidates. Each one becomes a module that takes text, a parse tree and the caret, and returns edits or styled ranges. In this order:

1. Links and anchors: `links.lua`, `parser.lua`, `anchors.lua`. They are pure and small, so they prove the pattern.
2. Link rename edits: `rename_links.lua`
3. The table model and formatting: `serialize_model` and `pad_cell` in `tables.lua`
4. Block formatting rules: the prefix rules in `format.lua` for headings, lists, quotes and callouts
5. The Live Preview decisions in `live_render.lua`: which ranges to hide and which to style at the caret

Item 5 is also part of the layout pipeline target in `AGENTS.md`. The desktop draws the styled ranges with its own renderer. The Companion applies them as Android text styles. Wrapping and row heights stay separate on each platform.

## Shared editing

[Shared editing](shared-editing.md) has a separate plan: a reload engine, Disk Conflicts, and later shared notes through a sync tool such as Nextcloud, and then live editing. That plan is not part of this one. These rules keep the two plans compatible:

- The reload engine also merges changes from other clients. If the Companion saves a note on a PC while desktop Anvil has it open, desktop Anvil sees a changed file and merges it. This plan needs no merge of its own.
- Writes are conditional. See [Writes](#writes).
- The protocol fixes one position unit and one edit format.
- Identity is a person plus a device.
- The capability list reserves a Live Document service. For files on one Machine, `anvil serve` can order the edits. The edit server in the shared-editing plan can use the same protocol on another host.
- The line and word comparison is Lua today (`data/core/buffer/text_edits.lua`). The Companion needs the same merge. Port it to C when step 3 of the shared-editing plan starts.

## Pi on your Machines

On your own PCs, install Pi and log in separately on each one. Do not copy `auth.json`: OpenAI login refresh tokens rotate, so two PCs that share one login can lock each other out. A Pi in a Terminal Session then works on its own Machine, with its own login.

### Later: Pi on a random PC

This is deferred. The options, from simple to complex:

1. An OpenRouter key with a credit limit, in a temporary Pi folder (`PI_CODING_AGENT_DIR`). Delete the folder and the key after the visit.
2. A Codex login with device code. `/logout` does not revoke the login at the provider.
3. A token proxy on a VPS. Pi's `models.json` points the provider's `baseUrl` to the proxy, with a placeholder key. The Codex provider decodes its token as a JWT for the account ID, and it can use a WebSocket, so the proxy needs a special adapter.
4. Forwarding through the Machine link to your own PC, like SSH agent forwarding. This needs the link from this plan.

## Risks

- The `core.fs` seam touches about 70 files, and `io.open` mixes Project content with local state.
- Synchronous file calls on the UI thread must change before a Project can run on a Machine.
- The POSIX branches of the native code have no CI job. They may be broken.
- The Companion's text styling must stay correct while Gboard edits text near hidden Markdown syntax.
- Position conversion between UTF-8 and UTF-16 is a source of off-by-one bugs.
- A Terminal host with several clients must not let one slow client stall the others.

## Order of work

Each stage adds services to the same server, so desktop and Companion grow together.

### Desktop

1. **Classify the call sites** of the primitives above.
2. **Add `core.fs`** with a local backend only, plus the fail-closed guard. Users see no change.
3. **Add `anvil serve`** with loopback Machines on one PC. The `lua-ui` suites can then run Projects through the server.
4. **Files and Search services**, the local metadata copy, and the picker data sources.
5. **Terminal service** with Controller and Viewers.
6. **Pairing and transport** between real PCs.
7. **Pi control discovery** through the link.

### Companion

1. **Machines and Projects** with Agent Status, read only.
2. **Terminal view**, first as a Viewer, then as a Controller.
3. **Files and code** with highlighting, and File Search.
4. **Markdown editing**, on the phone and on Machines.
5. **Text Search and Git** views.
6. **Pi chat**: start Pi, send messages, read its session file.

### First tests

- A Compose screen that edits a note with Live Preview for headings, bold text and wikilinks, using `markdown_parser.c` through JNI. Type into it with Gboard, with swipe typing and Spanish accents, while it hides and shows syntax at the caret. If the styles and the caret stay correct, the native approach works.
- Measure the size of a full file list snapshot for a large Project, compressed.

## Open questions

- Does `anvil serve` run only while Anvil runs, or from login?
- Are the names Machine, Swarm, Companion, Controller and Viewer accepted?
- Which position unit does the protocol use?
- What do the clipboard, file dialogs, drag and drop and Show in File Explorer do for a Project on another Machine?
