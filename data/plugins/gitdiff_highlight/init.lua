-- mod-version:3
-- Highlights changed lines, if file is in a git repository.
-- Also supports MiniMap, if user has it installed and activated.
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local Doc = require "core.doc"
local command = require "core.command"
local style = require "core.style"
local file_context = require "core.file_context"
local ranges = require "plugins.gitdiff_highlight.ranges"
local git_backend = require "plugins.git.backend"

local unpack = table.unpack or unpack
local function pack_results(...)
	return { n = select("#", ...), ... }
end

local plugin_config = config.plugins.gitdiff_highlight

local gitdiff_highlight = {}

local function color_for_diff(diff)
	if diff == "addition" then
		return style.gitdiff_addition
	elseif diff == "modification" then
		return style.gitdiff_modification
	else
		return style.gitdiff_deletion
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

local function new_state()
	return {
		is_in_repo = false,
		operational = false,
		loading = false,
		too_large = false,
		generation = 0,
		base_generation = 0,
		local_generation = 0,
		ranges = {},
		line_index = {},
	}
end

local function get_state(doc)
	return states[doc] or { is_in_repo = false, operational = false, ranges = {}, line_index = {} }
end

local function ensure_state(doc)
	local state = states[doc]
	if not state then
		state = new_state()
		states[doc] = state
	end
	return state
end

local function clear_state(doc, error_message)
	local state = ensure_state(doc)
	state.is_in_repo = false
	state.operational = false
	state.loading = false
	state.too_large = false
	state.error = error_message
	state.base_text = nil
	state.base_lines = nil
	state.ranges = {}
	state.line_index = {}
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
		"anvil_gitdiff_debug_%04d%02d%02d_%02d%02d%02d.txt",
		t.year, t.month, t.day, t.hour, t.min, t.sec
	)
end

local function write_debug_dump(doc)
	local state = get_state(doc)
	local path = temp_dir() .. PATHSEP .. timestamp_name()
	local fp, err = io.open(path, "wb")
	if not fp then
		core.error("gitdiff debug dump failed: %s", err or "could not open file")
		return
	end

	local function w(fmt, ...)
		fp:write(string.format(fmt, ...), "\n")
	end

	w("Anvil gitdiff_highlight debug dump")
	w("time=%s", os.date("%Y-%m-%d %H:%M:%S"))
	w("doc.filename=%s", tostring(doc and doc.filename))
	w("doc.abs_filename=%s", tostring(doc and doc.abs_filename))
	w("doc.lines=%s", tostring(doc and doc.lines and #doc.lines))
	w("doc.encoding=%s", tostring(doc and doc.encoding))
	w("doc.binary=%s", tostring(doc and doc.binary))
	w("git_path=%s", tostring(git_executable()))
	w("")
	w("state.is_in_repo=%s", tostring(state.is_in_repo))
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
	core.log("gitdiff debug dump saved and copied to clipboard: %s", path)
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
			if errcode == process.ERROR_PIPE then return true end
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

	read_available(proc, process.STREAM_STDOUT, stdout_chunks, stdout_cap)
	read_available(proc, process.STREAM_STDERR, stderr_chunks, stderr_cap)

	return proc:returncode() or 0, table.concat(stdout_chunks), table.concat(stderr_chunks)
end

local function git(args, max_stdout)
	local path = git_executable()
	if not path then return nil, "", "Git integration is disabled" end
	local full = { path }
	for _, arg in ipairs(args) do full[#full + 1] = arg end
	return run_process_capture(full, max_stdout)
end

local function decode_base_text(doc, text)
	if text:find("%z", 1, true) then return nil, "binary file" end
	if doc.needs_encoding_conversion and doc:needs_encoding_conversion() then
		if not encoding or not encoding.convert then return nil, "encoding conversion unavailable" end
		local ok, converted = pcall(encoding.convert, "UTF-8", doc.encoding, text, {
			strict = false,
			handle_from_bom = true,
		})
		if not ok or not converted then return nil, "base encoding conversion failed" end
		text = converted
	elseif not text:uisvalid() then
		return nil, "base is not valid UTF-8"
	end
	return text
end

local function build_line_index(doc, state)
	local index = {}
	local max_line = #doc.lines
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

local schedule_local_diff
local schedule_base_reload

local function finish_base_worker(doc, state)
	state = state or ensure_state(doc)
	state.base_worker_running = false
	state.loading = false
	if state.base_reload_requested then
		state.base_reload_requested = false
		schedule_base_reload(doc, "queued-base-reload")
	end
end

schedule_local_diff = function(doc, reason)
	if not doc or not doc.abs_filename then return end
	local state = ensure_state(doc)
	if not state.base_lines then return end

	state.local_generation = state.local_generation + 1
	state.local_deadline = system.get_time() + plugin_config.local_diff_debounce_ms / 1000
	if state.local_worker_running then return end
	state.local_worker_running = true

	core.add_thread(function()
		while true do
			local current_state = ensure_state(doc)
			local deadline = current_state.local_deadline or 0
			local now = system.get_time()
			if now >= deadline then break end
			coroutine.yield(math.min(0.05, deadline - now))
		end

		local current_state = ensure_state(doc)
		local generation = current_state.local_generation
		local built, meta = ranges.build(current_state.base_lines or {}, doc.lines or {}, {
			max_diff_cells = plugin_config.max_diff_cells,
			max_diff_lines = plugin_config.max_diff_lines,
		})
		if generation ~= current_state.local_generation then
			current_state.local_worker_running = false
			schedule_local_diff(doc, "stale-local-diff")
			return
		end

		current_state.too_large = meta and meta.too_large or false
		current_state.operational = not current_state.too_large and current_state.is_in_repo
		current_state.error = meta and meta.error or (meta and meta.reason)
		current_state.ranges = built or {}
		build_line_index(doc, current_state)
		current_state.local_worker_running = false
		if plugin_config.debug_log then
			core.log_quiet(
				"[gitdiff_highlight] local diff %s: ranges=%d too_large=%s error=%s cells=%s",
				doc.abs_filename or "?",
				#current_state.ranges,
				tostring(current_state.too_large),
				tostring(current_state.error),
				tostring(meta and meta.cells)
			)
		end
		core.redraw = true
	end)
end

schedule_base_reload = function(doc, reason)
	if not doc or not doc.abs_filename then return end
	local state = ensure_state(doc)
	if state.base_worker_running then
		state.base_reload_requested = true
		return
	end
	state.base_worker_running = true
	state.loading = true
	state.base_generation = state.base_generation + 1
	local base_generation = state.base_generation

	core.add_thread(function()
		local full_path = doc.abs_filename
		local git_full_path = normalize_git_path(full_path)
		local file_dir = dirname(full_path)

		if doc.binary then
			clear_state(doc, "binary file")
			finish_base_worker(doc, state)
			return
		end

		local rc, root, err = git({ "-C", file_dir, "rev-parse", "--show-toplevel" }, 64 * 1024)
		if base_generation ~= ensure_state(doc).base_generation then finish_base_worker(doc, state); return end
		if rc ~= 0 then
			clear_state(doc, "not in git repository")
			finish_base_worker(doc, state)
			return
		end
		root = trim_eol(root)

		local rel
		rc, rel, err = git({ "-C", root, "ls-files", "--full-name", "--error-unmatch", "--", git_full_path }, 64 * 1024)
		if base_generation ~= ensure_state(doc).base_generation then finish_base_worker(doc, state); return end
		if rc ~= 0 then
			local fallback_rel = repo_relative_path(root, full_path)
			if fallback_rel then
				rc, rel, err = git({ "-C", root, "ls-files", "--full-name", "--error-unmatch", "--", fallback_rel }, 64 * 1024)
			end
		end
		if rc ~= 0 then
			clear_state(doc, "file is not tracked: " .. tostring(err))
			finish_base_worker(doc, state)
			return
		end
		rel = normalize_git_path(trim_eol(rel))

		local max_stdout = plugin_config.max_file_size + 1
		local base_text
		rc, base_text, err = git({ "-C", root, "show", "--textconv", "HEAD:" .. rel }, max_stdout)
		if base_generation ~= ensure_state(doc).base_generation then finish_base_worker(doc, state); return end
		if rc == nil then
			clear_state(doc, err or "git show failed")
			finish_base_worker(doc, state)
			return
		elseif rc ~= 0 then
			-- Unborn HEAD or a path tracked in the index but absent from HEAD: treat
			-- the base as empty for v1. Rename-aware base lookup can be added later.
			base_text = ""
		end
		if #base_text > plugin_config.max_file_size then
			clear_state(doc, "base file too large")
			finish_base_worker(doc, state)
			return
		end

		local decoded, decode_err = decode_base_text(doc, base_text)
		if not decoded then
			clear_state(doc, decode_err)
			finish_base_worker(doc, state)
			return
		end

		local current_state = ensure_state(doc)
		current_state.is_in_repo = true
		current_state.operational = true
		current_state.loading = false
		current_state.error = nil
		current_state.repo_root = root
		current_state.rel_path = rel
		current_state.base_text = decoded
		current_state.base_lines = ranges.split_doc_lines(decoded)
		if plugin_config.debug_log then
			core.log_quiet(
				"[gitdiff_highlight] base loaded %s: root=%s rel=%s base_lines=%d",
				doc.abs_filename or "?",
				tostring(root),
				tostring(rel),
				#current_state.base_lines
			)
		end
		finish_base_worker(doc, current_state)
		schedule_local_diff(doc, reason or "base-reload")
	end)
end

local function effective_diff_for_line(doc, line)
	local state = get_state(doc)
	return state.line_index and state.line_index[line]
end

local function gitdiff_padding(dv)
	return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end

local old_docview_gutter = DocView.draw_line_gutter
local old_gutter_width = DocView.get_gutter_width
function DocView:draw_line_gutter(line, x, y, width)
	if not plugin_config.gutter or not get_state(self.doc).is_in_repo then
		return old_docview_gutter(self, line, x, y, width)
	end

	local lh = self:get_line_height()
	old_docview_gutter(self, line, x, y, width)

	local line_diff = effective_diff_for_line(self.doc, line)
	if line_diff == nil then return lh end

	local color = color_for_diff(line_diff)
	x = x + gitdiff_padding(self)

	if line_diff ~= "deletion" then
		renderer.draw_rect(x, y, style.gitdiff_width, lh, color)
		return lh
	end

	renderer.draw_rect(x - style.gitdiff_width * 2, y, style.gitdiff_width * 4, math.max(1, SCALE), color)
	return lh
end

function DocView:get_gutter_width()
	local gw, gpad = old_gutter_width(self)
	-- Reserve the gitdiff marker lane immediately so newly opened files do not
	-- shift right after async git state flips from unknown to tracked.
	return gw + style.padding.x * style.gitdiff_width / 12, gpad
end

local old_draw_scrollbar = DocView.draw_scrollbar
function DocView:draw_scrollbar()
	old_draw_scrollbar(self)
	if not plugin_config.overview or self.diff_view_parent then return end
	local state = get_state(self.doc)
	if not state.is_in_repo or not state.ranges or #state.ranges == 0 then return end

	local sx, sy, sw, sh = self.v_scrollbar:get_track_rect()
	if sw <= 0 or sh <= 0 then return end

	local lh = self:get_line_height()
	local source_h = math.max(1, #self.doc.lines * lh)
	local min_h = style.gitdiff_overview_min_height

	for _, range in ipairs(state.ranges) do
		local count = math.max(0, range.current_end - range.current_start)
		local anchor = math.max(1, math.min(#self.doc.lines, range.current_start))
		local y = sy + (((anchor - 1) * lh) / source_h) * sh
		local h = math.max(min_h, (count * lh / source_h) * sh)
		if y + h > sy + sh then h = sy + sh - y end
		if h > 0 then
			-- Overview markers are a narrow stripe aligned to the left edge of the
			-- actual vertical scrollbar handle/track area. They are about a third of
			-- the handle width and are drawn before the thumb is redrawn below.
			local marker_w = math.max(1, sw / 3.5)
			local marker_x = sx
			renderer.draw_rect(marker_x, y, marker_w, h, overview_color_for_diff(range.type))
		end
	end

	-- We called the previous scrollbar draw first for override compatibility, so
	-- redraw the vertical thumb to keep overview markers visually beneath it.
	self.v_scrollbar:draw_thumb()
end

local old_text_change = Doc.on_text_change
function Doc:on_text_change(change_type, transaction, ...)
	local result = old_text_change(self, change_type, transaction, ...)
	if get_state(self).is_in_repo then schedule_local_diff(self, "text-change") end
	return result
end

local old_doc_save = Doc.save
function Doc:save(...)
	local results = pack_results(old_doc_save(self, ...))
	schedule_base_reload(self, "save")
	return unpack(results, 1, results.n)
end

local old_doc_load = Doc.load
function Doc:load(...)
	local results = pack_results(old_doc_load(self, ...))
	schedule_base_reload(self, "load")
	return unpack(results, 1, results.n)
end

local old_set_filename = Doc.set_filename
function Doc:set_filename(...)
	local state = ensure_state(self)
	state.base_generation = state.base_generation + 1
	state.local_generation = state.local_generation + 1
	local results = pack_results(old_set_filename(self, ...))
	clear_state(self, "path changed")
	if self.abs_filename then schedule_base_reload(self, "path-change") end
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
		local doc = view and view.doc
		local state = doc and get_state(doc)
		if state and state.is_in_repo and state.line_index and state.line_index[line_index] then
			return color_for_diff(state.line_index[line_index])
		end
		return old_line_highlight_color(line_index)
	end
end)

local function gitdiff_unavailable_message(state)
	if state.loading then return "Git changes are still loading" end
	if state.too_large then return "Git changes unavailable: diff too large" end
	if not state.is_in_repo then return "Git changes unavailable" end
end

local function gitdiff_points_for_view(view)
	if not file_context.is_editor_view(view) or not view.doc then return nil, "no-provider" end
	local doc = view.doc
	local state = get_state(doc)
	local unavailable = gitdiff_unavailable_message(state)
	if unavailable then return nil, unavailable end
	local points = {}
	for _, range in ipairs(state.ranges or {}) do
		local line = math.min(#doc.lines, math.max(1, range.current_start or 1))
		points[#points + 1] = {
			line = line,
			col = 1,
			preserve_col = true,
			line_only_navigation = true,
			kind = "git-change",
			label = range.type,
			range = range,
		}
	end
	return points
end

function DocView:get_points_of_interest(opts)
	return gitdiff_points_for_view(self, opts)
end

local function active_editor_view()
	local view = core.active_view
	return file_context.is_editor_view(view), view
end

local function jump_to_gitdiff_change(view, direction)
	local poi = require("core.poi")
	return poi.navigate(view, direction)
end

command.add(active_editor_view, {
	["gitdiff:previous-change"] = function(view) jump_to_gitdiff_change(view, -1) end,
	["gitdiff:next-change"] = function(view) jump_to_gitdiff_change(view, 1) end,
})

command.add("core.docview", {
	["gitdiff:refresh"] = function()
		local view = core.active_view
		if view and view.doc then schedule_base_reload(view.doc, "manual-refresh") end
	end,
	["gitdiff:debug-state"] = function()
		local view = core.active_view
		local doc = view and view.doc
		if not doc then return end
		write_debug_dump(doc)
	end,
})

function gitdiff_highlight._set_state_for_tests(doc, state)
	states[doc] = state
end

return gitdiff_highlight
