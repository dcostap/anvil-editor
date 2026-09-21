-- mod-version:3
-- Highlights changed lines against Git or a retained Buffer Baseline.
-- Also supports MiniMap, if user has it installed and activated.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local TextView = require "core.textview"
local Buffer = require "core.buffer"
local command = require "core.command"
local style = require "core.style"
local file_context = require "core.file_context"
local ranges = require "plugins.gitdiff_highlight.ranges"
local git_backend = require "plugins.git.backend"
local git_status = require "plugins.file_git_status"

local unpack = table.unpack or unpack
local function pack_results(...)
	return { n = select("#", ...), ... }
end

local plugin_config = config.plugins.gitdiff_highlight

local gitdiff_highlight = {}

local function color_for_diff(diff)
	if diff == "addition" then
		return style.git_change_addition
	elseif diff == "modification" then
		return style.git_change_modification
	else
		return style.git_change_deletion
	end
end

local function overview_color_for_diff(diff)
	local color = color_for_diff(diff)
	if type(color) ~= "table" then return color end
	local faded = { unpack(color) }
	faded[4] = (faded[4] or 255) * 0.8
	return faded
end

local states = setmetatable({}, { __mode = "k" })
local git_missing_warned = false
local BASELINE_DIR = USERDIR .. PATHSEP .. "buffer-baselines"
local AUTOMATIC_PASTE_MIN_CHARACTERS = 100

local bit_ok, bit = pcall(require, "bit")
local function u32(n)
	n = tonumber(n) or 0
	if n < 0 then n = n + 4294967296 end
	return n % 4294967296
end

local function hash_text(text)
	local h1, h2 = 2166136261, 5381
	for i = 1, #text do
		local byte = text:byte(i)
		if bit_ok and bit then
			h1 = bit.tobit(bit.bxor(h1, byte) * 16777619)
			h2 = bit.tobit(h2 * 33 + byte)
		else
			h1 = (h1 * 16777619 + byte) % 4294967296
			h2 = (h2 * 33 + byte) % 4294967296
		end
	end
	return string.format("%08x%08x", u32(h1), u32(h2))
end

local function baseline_identity(buffer)
	if buffer.abs_filename then
		local path = common.normalize_path(buffer.abs_filename)
		if PLATFORM == "Windows" then path = path:lower() end
		return "file:" .. path
	end
	if buffer.intellij_untitled_id then
		local project = common.normalize_path(buffer.intellij_untitled_project_path or "default")
		if PLATFORM == "Windows" then project = project:lower() end
		return "untitled:" .. project .. ":" .. tostring(buffer.intellij_untitled_id)
	end
end

local function baseline_path(identity)
	return identity and (BASELINE_DIR .. PATHSEP .. hash_text(identity) .. ".lua")
end

local function read_persisted_baseline(buffer)
	local identity = baseline_identity(buffer)
	local path = baseline_path(identity)
	if not path or not system.get_file_info(path) then return end
	local fn, err = loadfile(path)
	if not fn then
		core.log_quiet("File changes: could not load Buffer Baseline %s: %s", path, tostring(err))
		return
	end
	local ok, data = pcall(fn)
	if not ok or type(data) ~= "table" or data.identity ~= identity or type(data.text) ~= "string" then
		core.log_quiet("File changes: ignored invalid Buffer Baseline %s", path)
		return
	end
	return data.text, data.origin == "manual" and "manual" or "automatic"
end

local function write_persisted_baseline(buffer, text, origin)
	local identity = baseline_identity(buffer)
	local path = baseline_path(identity)
	if not path then return false end
	local info = system.get_file_info(BASELINE_DIR)
	if not (info and info.type == "dir") then
		local ok, err = common.mkdirp(BASELINE_DIR)
		if not ok then
			core.log_quiet("File changes: could not create Buffer Baseline directory: %s", tostring(err))
			return false
		end
	end
	local body = "return " .. common.serialize({
		version = 1, identity = identity, origin = origin, text = text,
	}, { pretty = true, sort = true })
	local ok, err = pcall(Buffer.write_text_safely, path, body)
	if not ok then
		core.log_quiet("File changes: could not save Buffer Baseline %s: %s", path, tostring(err))
		return false
	end
	return true
end

local function remove_persisted_identity(identity)
	local path = baseline_path(identity)
	if path and system.get_file_info(path) then os.remove(path) end
end

local function new_state()
	return {
		is_in_repo = false,
		operational = false,
		closed = false,
		loading = false,
		too_large = false,
		base_from_head_path = false,
		generation = 0,
		base_generation = 0,
		local_generation = 0,
		ranges = {},
		line_index = {},
	}
end

local function get_state(buffer)
	return states[buffer] or { is_in_repo = false, operational = false, ranges = {}, line_index = {} }
end

local function ensure_state(buffer)
	local state = states[buffer]
	if not state then
		state = new_state()
		states[buffer] = state
	end
	return state
end

local function buffer_gitdiff_disabled(buffer)
	return buffer and buffer.disable_gitdiff_highlight
end

local schedule_local_diff
local schedule_base_reload

local function activate_buffer_baseline(buffer, text, origin, persist)
	if type(text) ~= "string" or #text > plugin_config.max_file_size then return false end
	local state = ensure_state(buffer)
	state.buffer_baseline_text = text
	state.buffer_baseline_origin = origin or "automatic"
	state.awaiting_initial_baseline = false
	state.baseline_kind = "buffer"
	state.base_text = text
	state.base_lines = ranges.split_buffer_lines(text)
	state.operational = true
	state.loading = false
	state.too_large = false
	state.error = nil
	if persist ~= false then write_persisted_baseline(buffer, text, state.buffer_baseline_origin) end
	if schedule_local_diff then schedule_local_diff(buffer, "buffer-baseline") end
	core.redraw = true
	return true
end

local function load_buffer_baseline(buffer)
	local state = ensure_state(buffer)
	if state.buffer_baseline_text then return true end
	local text, origin = read_persisted_baseline(buffer)
	if text then return activate_buffer_baseline(buffer, text, origin, false) end
	return false
end

local function use_buffer_fallback(buffer, error_message)
	local state = ensure_state(buffer)
	state.is_in_repo = false
	state.repo_root = nil
	state.rel_path = nil
	state.head_identity = nil
	state.base_from_head_path = false
	state.loading = false
	state.background_reload = false
	if load_buffer_baseline(buffer) then return state end
	if state.initial_text and not buffer.new_file and not buffer.binary then
		if activate_buffer_baseline(buffer, state.initial_text, "automatic", true) then return state end
	end
	state.operational = false
	state.error = error_message
	state.base_text = nil
	state.base_lines = nil
	state.baseline_kind = nil
	state.ranges = {}
	state.line_index = {}
	return state
end

local function clear_state(buffer, error_message)
	local state = ensure_state(buffer)
	state.is_in_repo = false
	state.operational = false
	state.loading = false
	state.too_large = false
	state.error = error_message
	state.base_text = nil
	state.base_lines = nil
	state.base_from_head_path = false
	state.repo_root = nil
	state.rel_path = nil
	state.head_identity = nil
	state.background_reload = false
	state.ranges = {}
	state.line_index = {}
	if plugin_config.debug_log and error_message then
		core.log_quiet("[gitdiff_highlight] baseline unavailable %s: %s", buffer.abs_filename or "?", tostring(error_message))
	end
	return state
end

local function git_executable()
	if not git_backend.is_enabled() then return nil end
	return git_backend.git_path()
end

local function warn_git_missing(errmsg)
	if git_missing_warned then return end
	git_missing_warned = true
	core.warn(
		"Git executable not found or could not be started: %s. Install Git or set config.plugins.git.git_path.",
		errmsg or git_executable()
	)
end

local function dirname(path)
	return path and (path:match("^(.*[\\/])") or ".") or "."
end

local function trim_eol(text)
	return (text or ""):gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
end

local function normalize_git_path(path)
	return (path or ""):gsub("\\", "/")
end

local function split_nul(text)
	local fields = {}
	local start = 1
	while true do
		local finish = text:find("\0", start, true)
		if not finish then
			if start <= #text then fields[#fields + 1] = text:sub(start) end
			break
		end
		fields[#fields + 1] = text:sub(start, finish - 1)
		start = finish + 1
	end
	return fields
end

local function error_text(err)
	return tostring(err or ""):lower()
end

local function is_unborn_head_error(err)
	local text = error_text(err)
	return text:find("does not have any commits", 1, true) ~= nil
		or text:find("needed a single revision", 1, true) ~= nil
end

local function is_missing_head_path_error(err)
	local text = error_text(err)
	return text:find("exists on disk, but not in 'head'", 1, true) ~= nil
		or text:find("does not exist in 'head'", 1, true) ~= nil
		or (text:find("path '", 1, true) and text:find("not in 'head'", 1, true)) ~= nil
end

local function path_starts_with_ci(path, prefix)
	return path:sub(1, #prefix):lower() == prefix:lower()
end

local function repo_relative_path(root, full_path)
	root = normalize_git_path(root):gsub("/+$", "")
	full_path = normalize_git_path(full_path)
	local prefix = root .. "/"
	if path_starts_with_ci(full_path, prefix) then
		return full_path:sub(#prefix + 1)
	end
end

local function table_count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function temp_dir()
	return os.getenv("TEMP") or os.getenv("TMP") or "."
end

local function timestamp_name()
	local t = os.date("*t")
	return string.format(
		"anvil_file_changes_debug_%04d%02d%02d_%02d%02d%02d.txt",
		t.year, t.month, t.day, t.hour, t.min, t.sec
	)
end

local function write_debug_dump(buffer)
	local state = get_state(buffer)
	local path = temp_dir() .. PATHSEP .. timestamp_name()
	local fp, err = io.open(path, "wb")
	if not fp then
		core.error("File changes debug dump failed: %s", err or "could not open file")
		return
	end

	local function w(fmt, ...)
		fp:write(string.format(fmt, ...), "\n")
	end

	w("Anvil file changes debug dump")
	w("time=%s", os.date("%Y-%m-%d %H:%M:%S"))
	w("buffer.filename=%s", tostring(buffer and buffer.filename))
	w("buffer.abs_filename=%s", tostring(buffer and buffer.abs_filename))
	w("buffer.lines=%s", tostring(buffer and buffer.lines and #buffer.lines))
	w("buffer.encoding=%s", tostring(buffer and buffer.encoding))
	w("buffer.binary=%s", tostring(buffer and buffer.binary))
	w("git_path=%s", tostring(git_executable()))
	w("")
	w("state.is_in_repo=%s", tostring(state.is_in_repo))
	w("state.baseline_kind=%s", tostring(state.baseline_kind))
	w("state.buffer_baseline_origin=%s", tostring(state.buffer_baseline_origin))
	w("state.operational=%s", tostring(state.operational))
	w("state.loading=%s", tostring(state.loading))
	w("state.too_large=%s", tostring(state.too_large))
	w("state.error=%s", tostring(state.error))
	w("state.repo_root=%s", tostring(state.repo_root))
	w("state.rel_path=%s", tostring(state.rel_path))
	w("state.base_generation=%s", tostring(state.base_generation))
	w("state.local_generation=%s", tostring(state.local_generation))
	w("state.base_worker_running=%s", tostring(state.base_worker_running))
	w("state.local_worker_running=%s", tostring(state.local_worker_running))
	w("state.base_lines=%s", tostring(state.base_lines and #state.base_lines))
	w("state.ranges=%d", #(state.ranges or {}))
	w("state.indexed_lines=%d", table_count(state.line_index))
	w("")
	w("Ranges:")
	for i, range in ipairs(state.ranges or {}) do
		if i > 200 then
			w("... truncated after 200 ranges")
			break
		end
		w(
			"%04d type=%s current=[%s,%s) base=[%s,%s)",
			i,
			tostring(range.type),
			tostring(range.current_start),
			tostring(range.current_end),
			tostring(range.base_start),
			tostring(range.base_end)
		)
	end
	fp:close()
	system.set_clipboard(path)
	core.log("File changes debug dump saved and copied to clipboard: %s", path)
	return path
end

local function read_available(proc, stream, chunks, cap)
	while true do
		local chunk, errmsg, errcode = proc:read(stream, 8192)
		if chunk and #chunk > 0 then
			chunks[#chunks + 1] = chunk
			cap.total = cap.total + #chunk
			if cap.total > cap.max then return false, "output too large" end
		elseif errcode == process.ERROR_WOULDBLOCK or chunk == "" then
			return true
		elseif not chunk then
			if errcode == process.ERROR_PIPE or (errmsg == nil and errcode == nil) then return true end
			return false, errmsg or "process read failed"
		else
			return true
		end
	end
end

local function run_process_capture(args, max_stdout)
	local proc, start_err = process.start(args, {
		stdout = process.REDIRECT_PIPE,
		stderr = process.REDIRECT_PIPE,
	})
	if not proc then
		if args[1] == git_executable() then warn_git_missing(start_err) end
		return nil, "", start_err or "process start failed"
	end

	local stdout_chunks, stderr_chunks = {}, {}
	local stdout_cap = { total = 0, max = max_stdout or plugin_config.max_file_size + 1 }
	local stderr_cap = { total = 0, max = 64 * 1024 }

	while proc:running() do
		local ok, err = read_available(proc, process.STREAM_STDOUT, stdout_chunks, stdout_cap)
		if not ok then proc:kill(); return nil, table.concat(stdout_chunks), err end
		ok, err = read_available(proc, process.STREAM_STDERR, stderr_chunks, stderr_cap)
		if not ok then proc:kill(); return nil, table.concat(stdout_chunks), err end
		coroutine.yield(0.02)
	end

	local ok, err = read_available(proc, process.STREAM_STDOUT, stdout_chunks, stdout_cap)
	if not ok then return nil, table.concat(stdout_chunks), err end
	ok, err = read_available(proc, process.STREAM_STDERR, stderr_chunks, stderr_cap)
	if not ok then return nil, table.concat(stdout_chunks), err end

	return proc:returncode() or 0, table.concat(stdout_chunks), table.concat(stderr_chunks)
end

local function git(args, max_stdout)
	local path = git_executable()
	if not path then return nil, "", "Git integration is disabled" end
	local full = { path }
	for _, arg in ipairs(args) do full[#full + 1] = arg end
	return run_process_capture(full, max_stdout)
end

local function head_path_for_staged_rename(root, rel)
	local rc, output, err = git({
		"--no-optional-locks", "--literal-pathspecs", "-C", root,
		"diff", "--cached", "--name-status", "-z", "-M", "HEAD", "--",
	}, 64 * 1024 * 1024)
	if rc ~= 0 then return nil, err, false end

	local fields = split_nul(output)
	local index = 1
	while index <= #fields do
		local status = fields[index] or ""
		index = index + 1
		if status:match("^[RC]%d*$") then
			local old_path, new_path = fields[index], fields[index + 1]
			index = index + 2
			if normalize_git_path(new_path) == rel then
				return normalize_git_path(old_path), nil, true
			end
		elseif status ~= "" then
			index = index + 1
		end
	end
	return nil, nil, true
end

local function decode_base_text(buffer, text)
	if buffer.needs_encoding_conversion and buffer:needs_encoding_conversion() then
		if not encoding or not encoding.convert then return nil, "encoding conversion unavailable" end
		local ok, converted = pcall(encoding.convert, "UTF-8", buffer.encoding, text, {
			strict = false,
			handle_from_bom = true,
		})
		if not ok or not converted then return nil, "base encoding conversion failed" end
		text = converted
	elseif not text:uisvalid() then
		return nil, "base is not valid UTF-8"
	end
	if text:find("\0", 1, true) then return nil, "binary file" end
	-- Buffer:load() removes a UTF-8 BOM from the first stored line. Keep the
	-- Git baseline in the same representation before splitting it into lines.
	if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
	return text
end

local function build_line_index(buffer, state)
	local index = {}
	local max_line = #buffer.lines
	for _, range in ipairs(state.ranges or {}) do
		if range.type == "deletion" then
			local line = math.max(1, math.min(max_line, range.current_start))
			index[line] = index[line] and "modification" or "deletion"
		else
			local start_line = math.max(1, range.current_start)
			local end_line = math.min(max_line, range.current_end - 1)
			for line = start_line, end_line do
				index[line] = index[line] and "modification" or range.type
			end
		end
	end
	state.line_index = index
end

local function finish_base_worker(buffer, state)
	state = state or ensure_state(buffer)
	state.base_worker_running = false
	state.loading = false
	if state.closed then
		state.base_reload_requested = false
		return
	end
	if state.base_reload_requested then
		state.base_reload_requested = false
		schedule_base_reload(buffer, "queued-base-reload")
	end
end

schedule_local_diff = function(buffer, reason)
	if not buffer or buffer_gitdiff_disabled(buffer) then return end
	local state = ensure_state(buffer)
	if state.closed then return end
	if not state.base_lines then return end

	state.local_generation = state.local_generation + 1
	state.local_deadline = system.get_time() + plugin_config.local_diff_debounce_ms / 1000
	if state.local_worker_running then return end
	state.local_worker_running = true

	core.add_thread(function()
		while true do
			local current_state = ensure_state(buffer)
			if current_state.closed then
				current_state.local_worker_running = false
				return
			end
			local deadline = current_state.local_deadline or 0
			local now = system.get_time()
			if now >= deadline then break end
			coroutine.yield(math.min(0.05, deadline - now))
		end

		local current_state = ensure_state(buffer)
		if current_state.closed then
			current_state.local_worker_running = false
			return
		end
		local generation = current_state.local_generation
		local built, meta = ranges.build(current_state.base_lines or {}, buffer.lines or {}, {
			max_diff_lines = plugin_config.max_diff_lines,
		})
		if generation ~= current_state.local_generation then
			current_state.local_worker_running = false
			schedule_local_diff(buffer, "stale-local-diff")
			return
		end

		current_state.too_large = meta and meta.too_large or false
		current_state.operational = not current_state.too_large and current_state.base_lines ~= nil
		current_state.error = meta and meta.error or (meta and meta.reason)
		current_state.ranges = built or {}
		build_line_index(buffer, current_state)
		current_state.local_worker_running = false
		if plugin_config.debug_log or current_state.too_large or current_state.error then
			core.log_quiet(
				"[gitdiff_highlight] local diff %s: ranges=%d too_large=%s error=%s cells=%s",
				buffer.abs_filename or "?",
				#current_state.ranges,
				tostring(current_state.too_large),
				tostring(current_state.error),
				tostring(meta and meta.cells)
			)
		end
		core.redraw = true
	end)
end

schedule_base_reload = function(buffer, reason)
	if not buffer or not buffer.abs_filename or buffer_gitdiff_disabled(buffer) then return end
	local state = ensure_state(buffer)
	if state.closed then return end
	-- Keep the shared status service aware of open Editors. This discovery does
	-- not request a refresh and therefore cannot create a watcher loop.
	git_status:lookup(buffer.abs_filename, false)
	if state.base_worker_running then
		state.base_reload_requested = true
		state.background_reload = state.background_reload
			or tostring(reason or ""):match("^shared%-git%-") ~= nil
		return
	end
	state.base_worker_running = true
	state.loading = true
	state.background_reload = state.background_reload
		or tostring(reason or ""):match("^shared%-git%-") ~= nil
	state.local_generation = state.local_generation + 1
	state.base_generation = state.base_generation + 1
	local base_generation = state.base_generation

	core.add_thread(function()
		if state.closed then finish_base_worker(buffer, state); return end
		local full_path = buffer.abs_filename
		local git_full_path = normalize_git_path(full_path)
		local file_dir = dirname(full_path)

		if buffer.binary then
			clear_state(buffer, "binary file")
			finish_base_worker(buffer, state)
			return
		end

		local rc, root, err = git({ "-C", file_dir, "rev-parse", "--show-toplevel" }, 64 * 1024)
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc ~= 0 then
			use_buffer_fallback(buffer, "not in git repository")
			finish_base_worker(buffer, state)
			return
		end
		root = trim_eol(root)

		local rel
		rc, rel, err = git({
			"--literal-pathspecs", "-C", root,
			"ls-files", "--full-name", "--error-unmatch", "-z", "--", git_full_path,
		}, 64 * 1024)
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc ~= 0 then
			local fallback_rel = repo_relative_path(root, full_path)
			if fallback_rel then
				rc, rel, err = git({
					"--literal-pathspecs", "-C", root,
					"ls-files", "--full-name", "--error-unmatch", "-z", "--", fallback_rel,
				}, 64 * 1024)
			end
		end
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc ~= 0 then
			use_buffer_fallback(buffer, "file is not tracked: " .. tostring(err))
			finish_base_worker(buffer, state)
			return
		end
		local rel_end = rel and rel:find("\0", 1, true)
		if rel_end then rel = rel:sub(1, rel_end - 1) end
		rel = normalize_git_path(rel or "")
		if rel == "" then
			use_buffer_fallback(buffer, "tracked path lookup returned no path")
			finish_base_worker(buffer, state)
			return
		end

		local max_stdout = plugin_config.max_file_size + 1
		local base_text
		local base_from_head_path = false
		local head_rc, head_output, head_err = git({ "-C", root, "rev-parse", "--verify", "HEAD" }, 64 * 1024)
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		local unborn_head = head_rc ~= 0 and is_unborn_head_error(head_err)
		if head_rc ~= 0 and not unborn_head then
			use_buffer_fallback(buffer, head_err or "HEAD lookup failed")
			finish_base_worker(buffer, state)
			return
		end

		if unborn_head then
			use_buffer_fallback(buffer, "repository has no committed baseline")
			finish_base_worker(buffer, state)
			return
		end
		local head_identity = trim_eol(head_output)
		if state.background_reload and state.base_from_head_path
			and common.path_equals(state.repo_root, root) and state.rel_path == rel
			and state.head_identity == head_identity then
			state.loading = false
			if not state.base_reload_requested then state.background_reload = false end
			state.error = nil
			finish_base_worker(buffer, state)
			schedule_local_diff(buffer, reason or "base-reload")
			return
		end
		rc, base_text, err = git({ "-C", root, "show", "--textconv", "HEAD:" .. rel }, max_stdout)
		if rc == 0 then base_from_head_path = true end
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc == nil then
			use_buffer_fallback(buffer, err or "git show failed")
			finish_base_worker(buffer, state)
			return
		elseif rc ~= 0 then
			if not is_missing_head_path_error(err) then
				use_buffer_fallback(buffer, err or "git show failed")
				finish_base_worker(buffer, state)
				return
			end
			local old_path, rename_err, rename_query_ok = head_path_for_staged_rename(root, rel)
			if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
			if not rename_query_ok then
				use_buffer_fallback(buffer, rename_err or "staged rename lookup failed")
				finish_base_worker(buffer, state)
				return
			end
			if old_path then
				rc, base_text, err = git({ "-C", root, "show", "--textconv", "HEAD:" .. old_path }, max_stdout)
				if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
				if rc == nil or rc ~= 0 then
					use_buffer_fallback(buffer, err or rename_err or "renamed Git baseline lookup failed")
					finish_base_worker(buffer, state)
					return
				end
			else
				-- A tracked index path absent from HEAD is a staged addition.
				use_buffer_fallback(buffer, "file has no committed baseline")
				finish_base_worker(buffer, state)
				return
			end
		end
		if #base_text > plugin_config.max_file_size then
			use_buffer_fallback(buffer, "base file too large")
			finish_base_worker(buffer, state)
			return
		end

		local decoded, decode_err = decode_base_text(buffer, base_text)
		if not decoded then
			use_buffer_fallback(buffer, decode_err)
			finish_base_worker(buffer, state)
			return
		end

		local current_state = ensure_state(buffer)
		if current_state.buffer_baseline_text and current_state.buffer_baseline_origin == "manual" then
			activate_buffer_baseline(buffer, current_state.buffer_baseline_text, "manual", false)
			finish_base_worker(buffer, current_state)
			return
		end
		if current_state.buffer_baseline_origin == "automatic" then
			remove_persisted_identity(baseline_identity(buffer))
			current_state.buffer_baseline_text = nil
			current_state.buffer_baseline_origin = nil
		end
		current_state.is_in_repo = true
		current_state.operational = true
		current_state.loading = false
		current_state.error = nil
		if not current_state.base_reload_requested then current_state.background_reload = false end
		current_state.repo_root = root
		current_state.rel_path = rel
		current_state.head_identity = unborn_head and "UNBORN" or trim_eol(head_output)
		current_state.base_from_head_path = base_from_head_path
		current_state.baseline_kind = "git"
		current_state.base_text = decoded
		current_state.base_lines = ranges.split_buffer_lines(decoded)
		if plugin_config.debug_log then
			core.log_quiet(
				"[gitdiff_highlight] base loaded %s: root=%s rel=%s base_lines=%d",
				buffer.abs_filename or "?",
				tostring(root),
				tostring(rel),
				#current_state.base_lines
			)
		end
		finish_base_worker(buffer, current_state)
		schedule_local_diff(buffer, reason or "base-reload")
	end)
end

local function effective_diff_for_line(buffer, line)
	local state = get_state(buffer)
	return state.line_index and state.line_index[line]
end

local function gitdiff_padding(dv)
	local line_number_width = dv:line_number_gutter_visible()
		and dv:get_line_number_gutter_width()
		or 0
	return style.padding.x * 1.5 + line_number_width
end

local old_textview_gutter = TextView.draw_line_gutter
local old_gutter_width = TextView.get_gutter_width
function TextView:draw_line_gutter(line, x, y, width)
	local state = get_state(self.buffer)
	if self.suppress_gitdiff_gutter or not plugin_config.gutter or not state.operational then
		return old_textview_gutter(self, line, x, y, width)
	end

	local lh = self:get_line_height()
	local gutter_height = old_textview_gutter(self, line, x, y, width) or lh

	local line_diff = effective_diff_for_line(self.buffer, line)
	if line_diff == nil then return gutter_height end
	local first_row = self:get_visual_row(line, 1, false)
	local marker_height = self:get_visual_row_y_offset(
		first_row + self:get_visual_row_count_for_line(line)
	) - self:get_visual_row_y_offset(first_row)
	marker_height = math.max(1, marker_height)

	local color = color_for_diff(line_diff)
	x = x + gitdiff_padding(self)

	if line_diff ~= "deletion" then
		renderer.draw_rect(x, y, style.gitdiff_width, marker_height, color)
		return gutter_height
	end

	renderer.draw_rect(x - style.gitdiff_width * 3, y, style.gitdiff_width * 6, math.max(1, common.round(2 * SCALE)), color)
	return gutter_height
end

function TextView:get_gutter_width()
	local gw, gpad = old_gutter_width(self)
	if self.suppress_gitdiff_gutter or not plugin_config.gutter then return gw, gpad end
	-- Reserve the gitdiff marker lane immediately so newly opened files do not
	-- shift right after async git state flips from unknown to tracked.
	return gw + style.padding.x * style.gitdiff_width / 12, gpad
end

local old_draw_scrollbar = TextView.draw_scrollbar
function TextView:draw_scrollbar()
	old_draw_scrollbar(self)
	if not plugin_config.overview or self.diff_view_parent then return end
	local state = get_state(self.buffer)
	if not state.operational or not state.ranges or #state.ranges == 0 then return end

	local source_h = math.max(1, self:get_scrollable_size())

	for _, range in ipairs(state.ranges) do
		local count = math.max(0, range.current_end - range.current_start)
		local anchor = math.max(1, math.min(#self.buffer.lines, range.current_start))
		local start_row = self:get_visual_row(anchor, 1, false)
		local start_offset = self:get_visual_row_y_offset(start_row)
		local end_offset = start_offset
		if count > 0 then
			local end_line = math.max(1, math.min(#self.buffer.lines, range.current_end - 1))
			local end_row = self:get_visual_row(end_line, 1, false)
				+ self:get_visual_row_count_for_line(end_line)
			end_offset = self:get_visual_row_y_offset(end_row)
		end
		local ratio_start = common.clamp(start_offset / source_h, 0, 1)
		local ratio_end = common.clamp(end_offset / source_h, ratio_start, 1)
		local marker_x, y, sw, h = self.v_scrollbar:get_overview_marker_rect(
			ratio_start, ratio_end
		)
		if marker_x then
			-- Overview markers are a narrow stripe aligned to the left edge of the
			-- actual vertical scrollbar handle/track area. They are about a third of
			-- the handle width and are drawn before the thumb is redrawn below.
			local marker_w = math.max(1, sw / 3.5)
			renderer.draw_rect(marker_x, y, marker_w, h, overview_color_for_diff(range.type))
		end
	end

	-- We called the previous scrollbar draw first for override compatibility, so
	-- redraw the vertical thumb to keep overview markers visually beneath it.
	self.v_scrollbar:draw_thumb()
end

local old_text_change = Buffer.on_text_change
function Buffer:on_text_change(change_type, transaction, ...)
	local result = old_text_change(self, change_type, transaction, ...)
	if not buffer_gitdiff_disabled(self) then
		local state = ensure_state(self)
		if change_type == "paste" and not state.base_lines
			and (self.intellij_untitled or self.new_file or state.awaiting_initial_baseline)
			and transaction and type(transaction.edits) == "table" and #transaction.edits == 1 then
			local pasted = tostring(transaction.edits[1].text or "")
			local meaningful_paste = pasted:gsub("%s", "")
			local meaningful_buffer = table.concat(self.lines or {}):gsub("%s", "")
			if pasted:ulen() > AUTOMATIC_PASTE_MIN_CHARACTERS
				and meaningful_paste ~= "" and meaningful_buffer == meaningful_paste then
				activate_buffer_baseline(self, table.concat(self.lines or {}), "automatic", true)
				core.log_quiet("File changes: captured initial pasted Buffer Baseline for %s", self:get_name())
			end
		end
		if ensure_state(self).base_lines then schedule_local_diff(self, "text-change") end
	end
	return result
end

local old_buffer_load = Buffer.load
function Buffer:load(...)
	local results = pack_results(old_buffer_load(self, ...))
	if not buffer_gitdiff_disabled(self) then
		local state = ensure_state(self)
		if not state.buffer_baseline_text
			and (not self.loaded_file_size or self.loaded_file_size <= plugin_config.max_file_size) then
			state.initial_text = table.concat(self.lines or {})
		end
		load_buffer_baseline(self)
		schedule_base_reload(self, "load")
	end
	return unpack(results, 1, results.n)
end

-- A save does not change the active baseline. Keep the live ranges in place.

local old_set_filename = Buffer.set_filename
function Buffer:set_filename(...)
	local old_path = self.abs_filename
	local old_identity = baseline_identity(self)
	local previous = get_state(self)
	local retained_text = previous.buffer_baseline_text
	local retained_origin = previous.buffer_baseline_origin
	local results = pack_results(old_set_filename(self, ...))
	if self.new_file and self.abs_filename then
		ensure_state(self).awaiting_initial_baseline = true
	end
	local same_path = old_path == self.abs_filename
		or (old_path and self.abs_filename and common.path_equals(old_path, self.abs_filename))
	if same_path then return unpack(results, 1, results.n) end
	local state = ensure_state(self)
	state.base_generation = state.base_generation + 1
	state.local_generation = state.local_generation + 1
	clear_state(self, "path changed")
	state.initial_text = nil
	if retained_text then
		state.buffer_baseline_text = retained_text
		state.buffer_baseline_origin = retained_origin
		activate_buffer_baseline(self, retained_text, retained_origin, true)
		local new_identity = baseline_identity(self)
		if old_identity and old_identity ~= new_identity then remove_persisted_identity(old_identity) end
	else
		local loaded = load_buffer_baseline(self)
		if not loaded and old_path and not self.binary then
			activate_buffer_baseline(self, table.concat(self.lines or {}), "automatic", true)
		end
	end
	if self.abs_filename and not buffer_gitdiff_disabled(self) then schedule_base_reload(self, "path-change") end
	return unpack(results, 1, results.n)
end

-- add minimap support only after all plugins are loaded
core.add_thread(function()
	if false == config.plugins.minimap then return end
	local found, MiniMap = pcall(require, "plugins.minimap")
	if not found then return end

	local old_line_highlight_color = MiniMap.line_highlight_color
	function MiniMap:line_highlight_color(line_index)
		local view = core.active_view
		local buffer = view and view.buffer
		local state = buffer and get_state(buffer)
		if state and state.operational and state.line_index and state.line_index[line_index] then
			return color_for_diff(state.line_index[line_index])
		end
		return old_line_highlight_color(line_index)
	end
end)

local function file_change_unavailable_message(state)
	if state.loading and not state.background_reload and not state.operational then return "File changes are still loading" end
	if state.too_large then return "File changes unavailable: diff too large" end
	if not state.operational then return "File changes unavailable" end
end

local function preview_file_change(view, point)
  local state = get_state(view.buffer)
  local range = point.range
  local preview = require "core.poi_preview"
  if range.base_start == range.base_end then
    preview.dismiss(view)
    return true
  end
  -- A deletion is anchored at the next surviving line. Show its removed text
  -- before that line. A deletion beyond the Buffer ends after its final line.
  local placement = range.type == "deletion" and range.current_start <= #view.buffer.lines
    and "before" or "after"
  local lines = {}
  for line = range.base_start or 1, (range.base_end or 1) - 1 do
    if #lines >= 24 then lines[#lines + 1] = "..."; break end
    lines[#lines + 1] = ((state.base_lines or {})[line] or "")
  end
  -- Keep large previews bounded. Do not compare incomplete blocks.
  if #lines > 24 or range.current_end - range.current_start > 24 then
    return preview.show(view, point, "Baseline code", lines, {
      code = true, placement = placement,
    })
  end
  local current = {}
  for line = range.current_start, range.current_end - 1 do
    current[#current + 1] = view.buffer.lines[line] or ""
  end
  local model = require("plugins.diff.model").compute(lines, current)
  return preview.show(view, point, "Baseline code", lines, {
    code = true, changes = model.a_changes,
    current_changes = model.b_changes, current_start = range.current_start,
    placement = placement,
  })
end

function gitdiff_highlight.get_patch_source(buffer)
	local state = get_state(buffer)
	local unavailable = file_change_unavailable_message(state)
	if unavailable or state.closed or buffer_gitdiff_disabled(buffer) or not state.base_lines then
		return nil, unavailable or "File changes unavailable"
	end
	return {
		before = state.base_lines, after = buffer.lines,
		before_name = state.rel_path or buffer:get_name(),
		after_name = state.rel_path or buffer:get_name(),
	}
end

local old_buffer_close = Buffer.on_close
function Buffer:on_close(...)
	local state = states[self]
	if state then
		state.closed = true
		state.base_generation = (state.base_generation or 0) + 1
		state.local_generation = (state.local_generation or 0) + 1
		state.base_reload_requested = false
		state.ranges = {}
		state.line_index = {}
	end
	return old_buffer_close(self, ...)
end

local function file_change_points_for_view(view)
	if not file_context.is_editor_view(view) or not view.buffer then return nil, "no-provider" end
	local buffer = view.buffer
	local state = get_state(buffer)
	local unavailable = file_change_unavailable_message(state)
	if unavailable then return nil, unavailable end
	local points = {}
	for _, range in ipairs(state.ranges or {}) do
		local line = math.min(#buffer.lines, math.max(1, range.current_start or 1))
		local last = math.min(#buffer.lines, math.max(line, (range.current_end or line + 1) - 1))
		points[#points + 1] = {
			line = line,
			col = 1,
			line2 = last,
			col2 = #(buffer.lines[last] or "") + 1,
			text_bounds = true,
			preserve_col = true,
			line_only_navigation = true,
			kind = "file-change",
			label = range.type,
			range = range,
			-- File change regions provide navigation previews, not caret activation.
			preview = preview_file_change,
		}
	end
	return points
end

local textview_get_points_of_interest = TextView.get_points_of_interest
function TextView:get_points_of_interest(opts)
	local file_change_points, unavailable = file_change_points_for_view(self, opts)
	local provider_points, provider_unavailable
	if textview_get_points_of_interest then
		provider_points, provider_unavailable = textview_get_points_of_interest(self, opts)
	end
	if file_change_points and provider_points then
		local combined = {}
		for _, point in ipairs(file_change_points) do combined[#combined + 1] = point end
		for _, point in ipairs(provider_points) do combined[#combined + 1] = point end
		return combined
	end
	return file_change_points or provider_points, unavailable or provider_unavailable
end

command.add(function()
	local view = core.active_view
	return file_context.is_editor_view(view) and view:supports_text_input()
		and not buffer_gitdiff_disabled(view.buffer), view
end, {
	["editor:set_buffer_baseline"] = command.palette(function(view)
		local text = table.concat(view.buffer.lines or {})
		if activate_buffer_baseline(view.buffer, text, "manual", true) then
			core.log_quiet("File changes: set Buffer Baseline for %s", view.buffer:get_name())
		end
	end, { keywords = { "change", "markers", "snapshot", "diff" } }),
	["editor:revert_file_change"] = function(view)
		local buffer = view.buffer
		local state = get_state(buffer)
		if file_change_unavailable_message(state) or not state.base_lines or state.closed then return end
		-- Rebuild now: the displayed markers can lag behind unsaved edits.
		local current_ranges, meta = ranges.build(state.base_lines, buffer.lines, {
			max_diff_lines = plugin_config.max_diff_lines,
		})
		if meta.too_large or meta.error then return end
		local caret = buffer:get_selection()
		local count = #buffer.lines
		for _, range in ipairs(current_ranges) do
			local first = math.min(count, range.current_start)
			local last = math.min(count, math.max(first, range.current_end - 1))
			if caret >= first and caret <= last then
				local replacement = table.concat(state.base_lines, "", range.base_start, range.base_end - 1)
				local line1, col1 = range.current_start, 1
				local line2, col2 = range.current_end, 1
				-- Buffer keeps a final newline that is not editable text.
				if line2 > count or (count == 1 and buffer.lines[1] == "\n") then
					line2, col2 = count, #buffer.lines[count]
					replacement = replacement:gsub("\n$", "")
					if line1 > count then
						line1, col1 = count, #buffer.lines[count]
						replacement = "\n" .. replacement
					elseif range.base_start == range.base_end and line1 > 1 then
						line1 = line1 - 1
						col1 = #buffer.lines[line1]
					end
				end
				local result = buffer:apply_edits({ {
					line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = replacement,
				} }, { merge_undo = false })
				if result.changed then
					require("core.poi_preview").dismiss(view)
					core.log_quiet("Reverted file %s in %s at line %d", range.type, buffer:get_name(), first)
				end
				return
			end
		end
	end,
})

command.add("core.textview", {
	["editor:refresh_file_changes"] = function()
		local view = core.active_view
		if view and view.buffer then schedule_base_reload(view.buffer, "manual-refresh") end
	end,
	["core:debug_file_changes"] = function()
		local view = core.active_view
		local buffer = view and view.buffer
		if not buffer then return end
		write_debug_dump(buffer)
	end,
})

local function refresh_published_repository(root, reason, err)
	if err or not root then return end
	if plugin_config.debug_log then
		core.log_quiet("[gitdiff_highlight] shared Git refresh root=%s reason=%s", tostring(root), tostring(reason))
	end
	for buffer, state in pairs(states) do
		if not state.closed and buffer.abs_filename
			and (common.path_equals(buffer.abs_filename, root)
				or common.path_belongs_to(buffer.abs_filename, root)) then
			schedule_base_reload(buffer, "shared-git-" .. tostring(reason or "refresh"))
		end
	end
end

-- Unsubscribe first so a reloaded module cannot retain an old callback.
git_status:unsubscribe(gitdiff_highlight)
git_status:subscribe(gitdiff_highlight, refresh_published_repository)

function gitdiff_highlight.initialize_buffer(buffer)
	if not buffer or buffer_gitdiff_disabled(buffer) then return false end
	local loaded = load_buffer_baseline(buffer)
	if loaded then schedule_local_diff(buffer, "initialize-buffer") end
	return loaded
end

function gitdiff_highlight.refresh_buffer(buffer)
	local state = buffer and ensure_state(buffer)
	if not state or not state.base_lines then return false end
	schedule_local_diff(buffer, "refresh-buffer")
	return true
end

function gitdiff_highlight.discard_buffer_baseline(buffer)
	if not buffer then return false end
	remove_persisted_identity(baseline_identity(buffer))
	local state = ensure_state(buffer)
	if state.baseline_kind ~= "buffer" and not state.buffer_baseline_text then return false end
	state.buffer_baseline_text = nil
	state.buffer_baseline_origin = nil
	clear_state(buffer, "Buffer Baseline discarded")
	return true
end

function gitdiff_highlight._set_state_for_tests(buffer, state)
	state.operational = state.operational ~= false and (state.base_lines ~= nil or state.is_in_repo == true)
	state.baseline_kind = state.baseline_kind or "git"
	state.base_generation = state.base_generation or 0
	state.local_generation = state.local_generation or 0
	state.ranges = state.ranges or {}
	state.line_index = state.line_index or {}
	states[buffer] = state
end

return gitdiff_highlight
