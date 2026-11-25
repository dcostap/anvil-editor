# Machine server and Companion implementation

See [Machines](../machines.md) for the design and remaining work. These notes describe the implemented behavior and focused checks.

## Machine server

`anvil serve [<project>...]` is the Machine server from [Machines](../machines.md). It runs Anvil's Lua (`core.serve`) without a window. It does not forward its launch to a running editor.

The shell starts `anvil serve --owner <shell pid>` at startup. That server ends within 1 second after its shell ends. One server runs for each user folder: a server keeps `USERDIR/machine/server.lock` open (`machine.claim`).

A second `anvil serve` fails. A server with `--owner` waits until the other server ends, then takes over. A dev update needs this, because the old server ends after the new shell starts.

Without Projects, the server serves the Sidebar's Projects: `USERDIR/scratch` and the `recents` of `USERDIR/appstate.lua`. It reads the file again when its time or size changes. `projects.list` gives `{path, scratch}` for each Project.

The server listens on port 7690 when it can, and takes another port when that port is in use. `--port 0` takes any free port. Tests use it.

On Windows, `net.create_server` binds without `SO_REUSEADDR`. With it, a second server got the same port, and the two servers shared the clients. Do not use `SO_EXCLUSIVEADDRUSE` either: it refuses the port while old connections are in TIME_WAIT, so a restarted server would lose 7690.

Run `runtime/net_server.lua` after changes. The server has a small headless runtime: `package.loaded.core` is the server's `core`, with `add_thread`, `try` and quiet logs. Each step runs the due threads and drains the worker pools.

So shared modules, such as `core.project_files`, run in the server unchanged. Each service is a module that returns its methods, such as `core.serve_files`. The JSON part of a frame is limited to 1 MiB, so large answers put JSON or NUL-separated text in the bytes.

`files.list {root}` gives the Project's scan from `core.project_files`: files, then folders, relative to the root and separated by NUL bytes. `files` counts the files. Ignore rules apply as in a local Project.

The first list of a root starts its folder watcher. `files.changes {root, since}` waits until a change after the sequence `since`, then gives the changed relative paths. `reset = true` means: list again.

The server keeps the last 64 change batches. `files.stat {paths}` gives `{type, size, modified}` or false for each path. `files.list_dir {path}` gives the entries of one folder.

Both send JSON in the bytes. `search.start {args, cwd}` runs the server's own ripgrep, not `args[1]`. `core.serve_search` accepts only the options on its list, and each path must be in `cwd`, which must be in a Project.

Add an option there only when it cannot run programs or write files. The server sets `--max-columns` to at most 64 KiB, also when the Client gives none or 0. ripgrep then omits a longer line, so one line cannot fill the server's memory. A path argument is absolute or relative to `cwd`.

The server refuses `\x` and `C:x`, because Windows reads them from another folder. The folders `USERDIR/machine` and `USERDIR/machines` hold credentials. The token in `server.json` gives Full control.

A Project can hold the user folder, so each path check refuses these folders (`private`), and each search excludes them with a ripgrep `--glob`. The glob names a path from `cwd`, so it holds only for paths in `cwd`. Each `[ ] { } * ?` in the path goes in a character class, because a backslash does not escape on Windows.

Each request runs protected: an error replies `internal_error` and does not stop the server. Above 64 MiB of unsent replies, the server reads no more requests from that Client. It closes the Client after 30 seconds without progress.

After the stall, the requests that it already received run before it reads again. `core.json` encodes text after `json.number_flag` as a raw number only when the text is a complete JSON number. `+1`, `01` and `1.` stay text.

Machine replies carry untrusted names and paths. `json.decode` stops at the first error. The server decodes a request before its login, so incomplete JSON must not stop the server.

`search.read {id}` waits for output and gives up to 1 MiB of records in the bytes. `done = true` gives ripgrep's exit `code`. A search ends after `search.cancel`, when its Client disconnects, or after 30 seconds without a read.

The server keeps at most 16 searches. A new search ends the oldest. A read that waits for an ended search gets `not_found`.

Run `runtime/machine_serve.lua` and the `launch-machine-server` shell probe after changes. It listens on loopback only. At start it writes `USERDIR/machine/server.json` with its port, token, process ID, Machine ID and epoch.

The folder is private. The Machine ID is in `USERDIR/machine/id` and stays across restarts. Each start gets a new epoch and a new token.

### Protocol and pairing

`src/machine_frame.c` is the frame codec. It has no Lua or SDL headers, because the Companion uses it too. `src/api/machine.c` exposes it to Lua as `machine`.

A frame has a 13-byte header: the type (1 request, 2 reply), then the request ID, the JSON length and the byte length, each 4 bytes big-endian. The JSON body follows, then the raw bytes. The first request must be `hello` with `protocol` and credentials.

The server checks the version first. A wrong version or wrong credentials get an error reply, then the server closes the connection. There are three kinds of credentials.

The local owner sends `token` from the discovery file. A paired device sends `device` and its own `token`. A new device sends `pair`, a pairing code, and `name`.

The `hello` reply gives the `level`: `view` or `full`. A View device only reads. `files.write`, `pairing.start`, `devices.list` and `devices.revoke` need Full control and give `forbidden` otherwise.

`pairing.start {level}` makes a 6-digit code. It works one time, for 5 minutes, and ends after 5 wrong attempts. A new code replaces the old one.

A `pair` without an active code gets `pairing_ended`, so the user knows to make a new code. A wrong code gets `unauthorized`. A pairing `hello` reply also carries `device = {id, token}`.

`USERDIR/machine/devices.json` keeps the paired devices with the SHA-256 of each token, not the token. `devices.revoke {device}` deletes the device and closes its connections at once. `--port <number>` before the Projects makes the server listen on that port.

Tailscale Serve and other forwarders need a port that stays the same. `anvil machine code full|view`, `anvil machine devices`, `anvil machine revoke <device>` and `anvil machine lan on|off` manage the server that runs with the same user folder.

`sharing.set {lan}` (Full control) opens or closes a second listener on `0.0.0.0` with the server's port, and saves the choice in `USERDIR/machine/sharing.json`. `sharing.get` gives `{lan, port, error}`. Windows lets that listener share the port with the loopback listener, and loopback connections go to the loopback listener. Turning sharing off closes the connections from the network. Tests pass `--test-lan-address 127.0.0.2`, so they open no port to the network and Windows shows no firewall prompt.

The server reads the first bytes of each connection. A TLS handshake starts with `0x16`, and a Machine frame starts with its type, 1 or 2. On TLS, `connection:start_tls(identity, bytes)` gives the bytes that the server already read to the handshake. A connection from the network without TLS closes. The certificate is a self-signed P-256 key in `USERDIR/machine/tls-key.der` and `tls-cert.der` (`src/machine_tls.c`). `MachineClient.pair` connects with `net.open_tcp(address, port, true, "")`, saves `socket:get_peer_fingerprint()` as the record's `pin`, and later connections pass that pin. A pin mismatch fails the handshake in C before Lua can send the token. A record without a pin connects without TLS. Run `runtime/machine_serve.lua` and `runtime/machine_client.lua` after changes to TLS.

`core.machine_cli` runs them without a window, like `anvil serve`, and exits. The Machines Dialog (`core.machine_dialog`, `machine:manage`) opens at Connect to a Machine. Without a paired Machine it shows the pairing form. Otherwise it shows the paired list. `machine:pair` always opens the form. Share this PC shows network access, permissions and devices with access. Create Pairing Code grants Full control or View only to the device that uses the code. Copy Code copies the active code without spaces. Revoke removes a paired device.

The Dialog connects as the local owner through `server.json`. A code hides when it expires or a device uses it. The Address row runs the Tailscale CLI through `core.machine_access`, in a worker. The Local network row uses `sharing.get` and `sharing.set`, and shows `COMPUTERNAME:port` while sharing is on.

Share on Tailnet runs `tailscale serve --bg --tcp <port> tcp://localhost:<port>`, and Stop Sharing turns that port off. Copy Address copies the displayed `host:port` while sharing is on. Sharing lets the other device reach this PC. The code grants access to Anvil. Pair Machine takes `host` or `host:port` (default 7690) and the six-digit code.

Browse Projects lists the selected Machine's Projects inside the Dialog. Back returns to the Machine list. Open Project opens the Machine-qualified Project and closes the Dialog. `machine:open_project` uses the same Dialog. Forget deletes the record (`MachineClient.forget`). With Full control, Forget also revokes this PC on the Machine.

Tests replace `machine_access.run`, so they never change the tailnet. Run `ui/machine_dialog.lua` and `runtime/machine_client.lua` after changes. Check the `machines-dialog` and `machines-dialog-others` render scenarios after visual changes.

### File versions and path security

`files.read` takes an absolute `path` in one of the server's Projects. Its reply has `size` and `version` in the JSON and the file's bytes after it. The version is the SHA-256 of the bytes.

`files.write` takes `path`, `base` and the new bytes. It replaces the whole file only while the file has the version `base`. Without `base`, it only creates a file.

Otherwise it sends a `conflict` error with the current `version` and bytes. Request bodies can hold bytes only after `hello`. Both limits are 16 MiB.

A write can carry a `save` ID. `files.save_result {save}` gives the version that the save wrote. The server keeps the last 1024 results in memory, so a restarted server answers `unknown_save`.

An error reply is `{"error": {"code": ..., "message": ...}}`. The server ignores unknown fields. The server polls its sockets.

Path checks use the resolved disk names of Project roots, files and credential folders. A link cannot grant access outside its Project. For a new file, the server checks the nearest existing parent.

`--test-root <folder>` before the Projects maps each Machine path into that folder: `C:\a\b` is `<folder>\C\a\b`. Only tests use it, so one PC can hold a Client copy and a different Machine copy at the same path. `--test-lose-reply <method>` does the first request of that method, then closes the connection without its reply.

Only tests use it.

### Client connections

`core.machine_client` is the Client. A scheduler thread connects through a Machine file and sends `hello`. `request` holds other requests until `hello` succeeds, and it never blocks the UI thread.

The connect and the `hello` reply must finish in 10 seconds. Then the Client fails the connection and tries again, because a forwarder can accept a connection that no server answers. A Machine file is the local discovery file or the record of a paired Machine.

After a disconnect, the Client connects again with a growing delay, up to 5 seconds. It reads the Machine file each time, because a restarted local server has a new port and token. `MachineClient.pair(host, port, code, name, on_done)` sends a pairing code one time and saves the record in `USERDIR/machines/<machine id>.json`.

The folder is private. A wrong code saves nothing and does not try again, because each attempt counts. The record keeps the host, the port, the device ID and the token, protected with `machine.protect`.

On Windows that is DPAPI for the current user. Other platforms keep the token as it is and rely on the private folder. A request that was not sent fails with `offline`.

A request whose reply did not arrive fails with `disconnected`: the Machine can have done it.

### File access and the Machine guard

`core.fs` holds the Project content of a Project process. `fs.use_machine(discovery, roots)` makes the process use a Machine. `roots` lists the Project's paths.

`core.machine_project` uses it when opening a Project on a Machine. It also turns on the Machine guard (`core.machine_guard`). The raw file functions then refuse relative paths and paths inside the roots.

Other absolute paths are local state, because a Machine serves only paths inside its Projects. A root can hold this PC's own folders: `USERDIR`, `DATADIR`, `EXEDIR` and the temp folder. An example is a Project at `C:\` or at the home folder.

The guard does not refuse paths in those folders, so the Client keeps its state and credentials there. `fs.on_machine` still names them Machine files. `fs.machine_file(path)` tells if a Buffer of the path reads and saves through the Machine.

A file in this PC's own folders and outside the guarded Project paths, such as the User Module, stays on this PC. Other paths go to the Machine, which refuses paths outside its Projects. The guard checks worker jobs before submission.

For `storage_save` and `storage_load`, the guard checks `userdir`, the only disk location those workers use. Storage encodes `module` and `key` as filename components. The saved `value` is data, not a file operation. These fields can contain Machine paths, so background Workspace saves can remember remote files. Relative and guarded Project paths remain invalid storage destinations.

For other jobs, the guard refuses payloads that name a Project path. The `bytes` and `text` fields hold file text, so the guard does not check them. Do not send a path that the worker does not read. A new raw function that takes a path needs a wrapper in the guard.

A Project at a drive root, such as `D:\`, owns all paths on that drive.

### File lists, search and File Tree

On a Machine, `core.project_files` fills its normal entry from `files.list`, `files.stat` and a `files.changes` loop. Its subscribers see the same change batches as for a local Project. After an error, the loop scans the Project again.

A scan that fails, for example while the Machine is away, runs again each second, because only a scan gives the loop its sequence. `fs.on_machine(path)` tells if a path names a Machine file. `project_files.info(path)` is `system.get_file_info` for local paths.

For a Machine file it gives only `{type}` from the file list, without a wait. The file list leaves out ignored files, so `info` then reads the folder listings of `core.machine_folders`. `core.text_search.start` starts ripgrep like `core.process_stream.start`.

In a Project on a Machine, it gives a stream with the same methods that reads from `search.read`. Text Search uses it for each ripgrep run. The Machine stream stops asking for output while 2 MiB waits unread.

`read_until` reports the bytes that it takes through the stream's `ack`, as for a local process. The stream then asks again. The server ends a search after 30 seconds without a read.

A stream that fails, such as while the Machine is away, makes Text Search show "Text Search failed", not "No matches". The next query searches again. File Search uses `project_files.info` for its path checks.

On a Machine, it skips the local probe before a preview, and its create row makes the file through `core.file_ops`. `core.open_file` opens a Machine file as text. A line number in a File Search query does not filter a Machine's files, because their lines are not counted here.

With Include Ignored Files, a path query searches the Machine's file list, not this PC's folders or Everything. Other Project rows show no preview when this Project or the row's Project is on a Machine. Their Machine and this process's Machine can differ.

Opening a row goes to its own Project. `core.machine_folders` keeps folder listings from `files.list_dir` for code that lists folders without a wait. `list(path)` gives nil while a listing loads.

Its `watch()` has the methods of `core.dirwatch` and reports a folder when its listing arrives or changes. The File Tree uses it on a Machine, so it shows each folder after its listing arrives. Folder counts use the same listings.

`core.file_ops` creates, moves, copies and deletes files and folders, also to the Recycle Bin. For a Machine path each call is a request (`files.mkdir`, `files.move`, `files.copy`, `files.delete`, or `files.write` to create), and the calling coroutine waits. `file_ops.run(path, fn)` runs `fn` in a thread for a Machine path.

The server uses the same functions on its own disk. These methods need Full control. Their paths must be in a Project.

Editor file references use a local worker to parse text, but the Client resolves their paths against the Machine's file and folder lists. A same-named file on this PC is not a match. Live Terminal file links use the same lookup.

A Project root, or a folder that holds a Project root, cannot move or be deleted. A move or copy fails when its target exists. A Client waits on `files.changes` once for each Project.

A new wait ends the earlier wait with `replaced`. On a Machine the File Tree applies its changes in a thread. It then lists the changed folders again (`machine_folders.reload`), without a wait for the change notices.

While the changes run, the tree takes no edits and no second apply, because the new list replaces its text. A restored File Tree on a Machine waits for the listings of its saved folders, then restores them. No metadata tells that a saved folder is gone, so a gone root shows an empty tree.

The tree takes no edits until the restore ends. Up Directory and other folder changes stay in the Machine's Project. The folder above it is a folder of this PC.

`sync_path` does not resolve a Machine path on this PC. Rename (`editor:rename`) moves a Machine file with `file_ops.move`, then saves the Buffer's unsaved text. Delete and New Directory also use `core.file_ops`.

New Directory starts a relative name at the Project. Save As of a new Buffer checks the target with `file_ops.info`, so it asks before it writes over a Machine file. A File Tree delete that cannot reach the Machine shows an error and keeps the edit.

`file_ops.info` returns nil without an error for a missing local file. `system.get_file_info` marks this case with `not_found` in its third return value, so other path errors still stop Save As. Run `ui/buffer_save_as.lua` and `runtime/system.lua` after changes.

`common.path_suggest` lists Machine folders through `common.machine_listing`, which `fs.use_machine` sets. The listings arrive later, so the first suggestions can be empty.

### Markdown and images

A Markdown attachment on a Machine uploads the file from this PC into the note's attachment folder. The Obsidian attachment setting comes from the Machine. A file URI link to this PC is refused.

The link goes at the selection of the paste. An edit, a close or a new note name during the upload inserts no link, and a warning names the uploaded file. Live Preview binds no vault index on a Machine, and link completion offers no note names.

Both wait for the Index service. The vault index also ignores the load and rename of a Machine Buffer. An Image View of a Machine file reads its bytes through `core.fs` and loads them with `canvas.load_image_data`.

A restored Image View loads the same way, then applies its saved pan. Autoreload does not watch Machine files, and focus does not change the process's folder to a Machine Project. An image in a Machine note loads in a thread (`markdown/images.lua`).

It finds the path with Machine stats, in the same order as locally, then reads the bytes. Its subscribers hear when it is ready. A Machine file has no local file ID, so the Git changes baseline keeps none.

A Machine image has no local file to check, and a Machine note has no vault index. So `markdown/images.lua` subscribes to the Project's file changes. A change loads each failed Machine image again, and each image whose file changed.

A reconnect loads all Machine images again. Their subscribers hear the result. Run `runtime/machine_files.lua`, `ui/machine_file_search.lua` and `ui/machine_filetree.lua` after changes.

### Project identity

A Project on another Machine has a key: `anvil-machine://<Machine ID>/<path on the Machine>` (`core.machine_project`). The Sidebar, Shell App State, recent Projects and Workspaces use the key as the Project's path. Windows file functions reject it.

The shell uses the key as the Project's identity and passes it to the Project process with `--project`. That process connects with `fs.use_machine`: to this PC's own server when the ID is its own, or else to the paired Machine's record in `USERDIR/machines`. Inside the process, paths are native paths.

Project labels use `folder @ host` for a Machine Project and `folder` for a local Project. A Machine badge shows `@` even when the name does not fit. Until the paired address is available, the label uses a short Machine ID. Path Search matches the displayed address but opens the original key. Pairing grants access; it does not add all the Machine's Projects to Path Search. Use Machines → Browse Projects for the first open. After that, the Sidebar and Path Search list the Project on this PC.

Code that names this Project to the Sidebar or to other Projects uses `machine_project.root_key(path)`: Workspaces, Untitled recovery, recent Projects, Numbered Panes, Sidebar Tab drags, Pane transfers and Other Project search. Pane requests accept a key in their Project fields. Path normalization would change a key's separators, so Path Search and other code do not normalize a key.

`core.open_project_in_same_window` and `core.open_project_in_new_window` give a folder of this process's Machine its key (`machine_project.folder_key`). A Pane moves only between Projects of the same Machine, or between Projects of this PC. On a Machine, the target Project must hold each file of the Pane: each Buffer's file, each Image View's image and each File Tree's folder.

`machine:open_project` lists the paired Machines, then the chosen Machine's Projects (`projects.list`). On connection and reconnection, `projects.paths {project}` reads the Project Paths from the Machine's saved Workspace. The Client uses their labels, roles and read-only settings. File Search lists each external root through the Machine, not the Client's disk. External roots do not become Sidebar Projects or Terminal roots.

Change Project Paths on the Machine. Reopen the remote Project to load the new configuration. A Client cannot grant itself access by sending a folder name. The server protects its Workspace storage from remote file operations. Servers without `projects.paths` retain the Client's Workspace behavior.

A Project on a Machine skips its Project module, Git, Git file changes and the symbol index until their services exist. The guard would show an error for each. Run the `launch-machine-project` shell probe after changes.

It opens this PC's own Scratch through its server and opens a file. It checks that the background Workspace save records that file before shutdown, without a guard refusal. The test server's owner is the test process, so a crashed test does not leave a server. [The file seam](../machines.md#the-file-seam-corefs) lists the Project content sites by feature. Run `runtime/machine_guard.lua` and `runtime/machine_buffer.lua` after changes.

The Buffer tests run with the guard on. Test helpers that stand for the Machine keep the raw functions from load time.

### Buffer loads, saves and recovery

On a Machine, `core.open_buffer` loads each file in the background. The Machine sends the bytes, and the `buffer_read` worker decodes them from its payload. A missing file opens as a new file.

`Buffer:save` sends the whole file with the version that the Buffer loaded or saved last. The Buffer stays dirty until the Machine confirms. A save during another save waits, with its file, and sends after the reply.

A waiting plain Save saves the Buffer's file at its turn, which a Save As before it can change. It sends also when the text looks saved, because an encoding or line ending change does not change the text. A closed Buffer sends nothing more.

`MachineClient:request` refuses more than 16 MiB of bytes with `too_large`, because the server closes the connection of a larger request. A larger Buffer shows an error and sends nothing. A Save As over an existing file sends again with that file's version, as a local Save As replaces the file.

A file that changes again stops the Save As with an error, not the conflict choice, because that choice acts on the Buffer's own file. A refused save records the Machine's version in `buffer.machine_conflict` and calls `Buffer:on_machine_conflict`. Autosave shows its normal conflict choice there, without Save Copy.

Overwrite and Save as New File first call `Buffer:accept_machine_version`. Each save has a save ID. When its reply is lost, the Buffer stays dirty.

After the reconnect it asks `files.save_result`. On `unknown_save` the file's version decides: the sent bytes mean saved, the base means not saved, other bytes mean a conflict. The Buffer never sends the old bytes again.

A save that did not happen sends the current text to its file, also for a Save As of a clean Buffer, and the saves that wait behind it run after it. After each reconnect, each open Buffer reads its file again. A clean Buffer whose file changed reloads through edits.

A dirty Buffer keeps its text and gets a conflict. A save that went `offline` runs again, to the file that it named. So an offline Save As writes the new file, not the old one.

A save result that the Client finds after a reconnect also gets this check, because another program can have changed the file after the save. A successful Save As drops the old file's conflict. A reply marks only the sent text as saved.

After an edit or undo during the save, the Buffer is clean only when its text is the sent text, because the history can hold other text at the sent undo position. A reload from the Machine is ignored when the user typed during the read. The next save then meets any change on the Machine as a conflict.

Autosave keeps no local disk state for Machine files. Its disk state is the last conflict. Each dirty Machine Buffer has a recovery record in `core.storage` (`machine_recovery`, one key for each Machine and path).

It holds the text, encoding, line endings, base version and the sent version of the open save. An edit writes it after 0.5 seconds. A save writes it before the request leaves.

A clean Buffer deletes it, except while a save is unresolved: the Machine can have its bytes. For the same reason, the Buffer registry keeps a Buffer with an unresolved save after its last View closes. Records are written on the UI thread, as Untitled recovery is.

When a Machine file loads and has a record, the Buffer takes the record's text as one edit. The Machine's version decides: the same bytes mean clean, the base or the sent version mean dirty, other bytes mean a conflict. A Buffer that the user closes without a save deletes its record, and no due write or later reply writes it again.

A rename moves the record to the new name.

### Remote Terminals

On Windows, the server has a Terminal service (`core.serve_terminal`). `terminal.list {project, known, wait}` gives the running Terminal Sessions of a Project, newest first, with the record fields that the Sidebar shows, and the list's `revision`. A session with a `.closed` marker is not listed.

With `wait` and the current revision as `known`, the reply waits until the Project's list changes. A directory watch on `terminal-sessions` wakes the waits, so a waiting Client costs no traffic. A host that ends without a record write shows only at the next change in that folder, as in the shell's scan. The `terminal.list.wait` feature tells the Client that the server waits.

`terminal.attach {id, cols, rows, cell_width, cell_height}` connects the server to the session's host as one more Client (`terminal_link.connect`). The reply gives the `link`, the `session_id`, the `shell_pid` and the host's size. `terminal.start {project, cwd, shell, scrollback_lines, cols, rows, cell_width, cell_height}` starts a new host in a Project folder and attaches the device as its Controller (`terminal_link.launch`).

Only Full control devices can start a shell. Its reply is the reply of `terminal.attach`. A new shell ends when its link ends before the device reads it, for example after a lost reply.

Nothing else knows its ID. `terminal.read {link}` waits for the host's framed records and gives up to 1 MiB of whole records in the bytes. `terminal.write {link}` sends records to the host.

`terminal.detach {link}` ends the link. The host keeps the session. The link checks each record that a Client writes, in C.

A Full control device can send input, resize, take control, clear, detach, close and end. A View device attaches view-only and can only detach. Its other writes get `forbidden`.

The host shows the paired device's name as the Controller's name. A full write buffer gives `busy`, and the Client sends again. The server closes a Client's links when the Client disconnects.

Each Client has at most 32 links. On a Client, `terminal_native.new {remote = true}` makes a session without a host. `core.machine_terminal.connect(client, session, id, start)` attaches it through `terminal.attach`, then `session:attach_remote(result)` connects it.

With a nil `id`, it starts a shell through `terminal.start`. A first attach that gets `not_found` also starts a shell, with the same `start` options. `attach_remote` gives the session one end of an in-process pipe pair (`terminal_link.c`).

The session's reader and writer use it as a host pipe. Lua carries the other end's records through `terminal.read` and `terminal.write`. After a disconnect, `core.machine_terminal` closes the pipe pair.

The session then waits in the reconnecting state, with no time limit, and attaches again with a new snapshot when the Machine returns. A closed session sends its last record, such as CLOSE or DETACH, through the link after its pipe closes. The Client then sends `terminal.detach`.

A later `not_found` attach means the session ended on the Machine. The attach ROLE comes before the snapshot. The Client applies it with the snapshot, so a key that the user types when the screen shows goes out with its role.

In a Project on a Machine (`fs.machine`), each Terminal View runs its shell on the Machine. The View keeps no session record on this PC and uses no prepared shell. Workspace restore attaches the saved session ID.

When the Machine no longer has it, a new shell starts in the saved folder, as a local restore does. Reopen Closed Pane does the same, because the Machine keeps no closed sessions. A shell that ended while this PC was away closes its View, as after an exit.

A failed start shows its error in the View. These Terminals cannot move to another Project. Programs in them reach the Machine's Anvil, so the View publishes no control endpoint.

The shell's scan reads only this PC's records. So the Project process lists its Machine's sessions (`machine_terminal.sessions`), and its Pane report sends them as `terminals`. Each list waits on the Machine until a change, and the Client sends at most one list each 2 seconds. A server without `terminal.list.wait` answers at once, so it gets a list each 2 seconds. The Sidebar model adds them to the Project's Terminal Sessions, so they show agent status, age groups and attention as local sessions do.

A Dormant Project on a Machine lists none. A visible Terminal Tab takes the place of its session row. A session in Pane history keeps its session row, so selecting another session does not hide it. A Sidebar click restores the existing View or attaches to the listed session.

Run `runtime/machine_terminal.lua`, `ui/machine_terminal.lua` and `ui/project_sidebar.lua` after changes. The runtime test uses a real host and a real server that shares the test's user folder. The UI test gives the server its own user folder.

Run `runtime/machine_serve.lua`, `runtime/machine_client.lua`, `runtime/machine_buffer.lua`, `anvil:machine-frame` and `anvil:launch-mode` after changes. Tests that need a fixed port must try ports until one opens: Windows reserves whole port ranges, and `get_port()` returns the requested port. Pass one file to each `--test-args`: the runner reads only the first path.

## Companion (Android)

`android/` is the Companion's Gradle project (`io.github.dcostap.anvil`). It is a Client of the Machine server. See [Machines](../machines.md).

The app opens to the paired Machines with their connection state. "Pair a Machine" takes the host, the port (default 7690) and a code from `anvil machine code`. It sends `hello` with the code and `Build.MODEL` as the device name. `machines.json` in the app's private storage keeps each Machine's ID, host, port and device ID.

The device token is encrypted with an AES/GCM key in Android Keystore. Pairing the same Machine again replaces its record. A Machine screen lists its Projects and their Terminal Sessions, with the Agent Status as the desktop Sidebar says it, such as "Waiting for you".

It sends `projects.list` and `terminal.list` again every 2 seconds while it shows. Connections run only while the app shows. A lost connection retries with a growing delay, up to 5 seconds.

A Project row opens its folders and Markdown notes (`files.list_dir`). Dot entries do not show. A note opens in a text field with Live Preview.

`markdown_styles.c` parses the note with the desktop's `markdown_parser.c` and `markdown_extensions.c` and returns styled ranges in UTF-16 units. Kotlin applies them as styles only, so the keyboard sees the real text. Syntax markers hide unless the focused field's selection is in their element.

The Companion keeps the note's CRLF and BOM, and refuses text that is not UTF-8. A note saves 1 second after the last edit, with `files.write` and the version that it read as `base`. A conflict asks the user: Keep mine or Use theirs.

A save whose answer was lost compares the file's version with the SHA-256 of the sent text after the reconnect. Each unsaved note has a recovery record in `files/recovery`. A recovered note saves when its Machine connects.

A clean open note checks `files.stat` every 2 seconds and reads the file again when it changed. Without Full access, notes are read only. Wikilinks do not open notes yet.

The frames use the desktop's codec, `src/machine_frame.c`, through the JNI binding `machine_frames.c`. CMake compiles it from `src/` and copies no files. Kotlin owns the socket, the JSON and the screens.

Tools: the Android SDK in `%LOCALAPPDATA%\Android\Sdk`, NDK 30.0.16248370, CMake 4.1.2, platform 37 and JDK 17 or later in `JAVA_HOME`. Set `sdk.dir` in the ignored `android/local.properties`. The Gradle wrapper checks the distribution's SHA-256.

Build with `./gradlew assembleDebug` in `android/`. Test on the emulator, not on the user's phone. Start the AVD `anvil-test-36` with `emulator -avd anvil-test-36 -no-window`.

Install the app and its test APK with `./gradlew installDebug installDebugAndroidTest`. Then run `tests/lua/companion/machines.lua` through `anvil:lua-runtime --test-args`. It starts a real server and a Terminal with a waiting agent, and runs `MachinesTest` and `NotesTest` on the emulator through `adb`.

`MarkdownStylesTest` needs no server: run it with `am instrument`. The emulator reaches the PC's loopback address as `10.0.2.2`. The default suites do not run it.

It skips when no emulator has both APKs. Run it after changes to the app or to `hello`, `projects.list`, `terminal.list` or the `files` methods. The connection logs with the tag `AnvilMachine`.

Read them with `adb logcat -s AnvilMachine`.
