-- mod-version:3
-- Highlights changed lines, if file is in a git repository.
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

local function clear_state(buffer, error_message)
	local state = ensure_state(buffer)
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

local function write_debug_dump(buffer)
	local state = get_state(buffer)
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
	w("buffer.filename=%s", tostring(buffer and buffer.filename))
	w("buffer.abs_filename=%s", tostring(buffer and buffer.abs_filename))
	w("buffer.lines=%s", tostring(buffer and buffer.lines and #buffer.lines))
	w("buffer.encoding=%s", tostring(buffer and buffer.encoding))
	w("buffer.binary=%s", tostring(buffer and buffer.binary))
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

local function decode_base_text(buffer, text)
	if text:find("%z", 1, true) then return nil, "binary file" end
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

local schedule_local_diff
local schedule_base_reload

local function finish_base_worker(buffer, state)
	state = state or ensure_state(buffer)
	state.base_worker_running = false
	state.loading = false
	if state.base_reload_requested then
		state.base_reload_requested = false
		schedule_base_reload(buffer, "queued-base-reload")
	end
end

schedule_local_diff = function(buffer, reason)
	if not buffer or not buffer.abs_filename or buffer_gitdiff_disabled(buffer) then return end
	local state = ensure_state(buffer)
	if not state.base_lines then return end

	state.local_generation = state.local_generation + 1
	state.local_deadline = system.get_time() + plugin_config.local_diff_debounce_ms / 1000
	if state.local_worker_running then return end
	state.local_worker_running = true

	core.add_thread(function()
		while true do
			local current_state = ensure_state(buffer)
			local deadline = current_state.local_deadline or 0
			local now = system.get_time()
			if now >= deadline then break end
			coroutine.yield(math.min(0.05, deadline - now))
		end

		local current_state = ensure_state(buffer)
		local generation = current_state.local_generation
		local built, meta = ranges.build(current_state.base_lines or {}, buffer.lines or {}, {
			max_diff_cells = plugin_config.max_diff_cells,
			max_diff_lines = plugin_config.max_diff_lines,
		})
		if generation ~= current_state.local_generation then
			current_state.local_worker_running = false
			schedule_local_diff(buffer, "stale-local-diff")
			return
		end

		current_state.too_large = meta and meta.too_large or false
		current_state.operational = not current_state.too_large and current_state.is_in_repo
		current_state.error = meta and meta.error or (meta and meta.reason)
		current_state.ranges = built or {}
		build_line_index(buffer, current_state)
		current_state.local_worker_running = false
		if plugin_config.debug_log then
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
	if state.base_worker_running then
		state.base_reload_requested = true
		return
	end
	state.base_worker_running = true
	state.loading = true
	state.base_generation = state.base_generation + 1
	local base_generation = state.base_generation

	core.add_thread(function()
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
			clear_state(buffer, "not in git repository")
			finish_base_worker(buffer, state)
			return
		end
		root = trim_eol(root)

		local rel
		rc, rel, err = git({ "-C", root, "ls-files", "--full-name", "--error-unmatch", "--", git_full_path }, 64 * 1024)
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc ~= 0 then
			local fallback_rel = repo_relative_path(root, full_path)
			if fallback_rel then
				rc, rel, err = git({ "-C", root, "ls-files", "--full-name", "--error-unmatch", "--", fallback_rel }, 64 * 1024)
			end
		end
		if rc ~= 0 then
			clear_state(buffer, "file is not tracked: " .. tostring(err))
			finish_base_worker(buffer, state)
			return
		end
		rel = normalize_git_path(trim_eol(rel))

		local max_stdout = plugin_config.max_file_size + 1
		local base_text
		rc, base_text, err = git({ "-C", root, "show", "--textconv", "HEAD:" .. rel }, max_stdout)
		if base_generation ~= ensure_state(buffer).base_generation then finish_base_worker(buffer, state); return end
		if rc == nil then
			clear_state(buffer, err or "git show failed")
			finish_base_worker(buffer, state)
			return
		elseif rc ~= 0 then
			-- Unborn HEAD or a path tracked in the index but absent from HEAD: treat
			-- the base as empty for v1. Rename-aware base lookup can be added later.
			base_text = ""
		end
		if #base_text > plugin_config.max_file_size then
			clear_state(buffer, "base file too large")
			finish_base_worker(buffer, state)
			return
		end

		local decoded, decode_err = decode_base_text(buffer, base_text)
		if not decoded then
			clear_state(buffer, decode_err)
			finish_base_worker(buffer, state)
			return
		end

		local current_state = ensure_state(buffer)
		current_state.is_in_repo = true
		current_state.operational = true
		current_state.loading = false
		current_state.error = nil
		current_state.repo_root = root
		current_state.rel_path = rel
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
	if self.suppress_gitdiff_gutter or not plugin_config.gutter or not get_state(self.buffer).is_in_repo then
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
	if self.suppress_gitdiff_gutter then return gw, gpad end
	-- Reserve the gitdiff marker lane immediately so newly opened files do not
	-- shift right after async git state flips from unknown to tracked.
	return gw + style.padding.x * style.gitdiff_width / 12, gpad
end

local old_draw_scrollbar = TextView.draw_scrollbar
function TextView:draw_scrollbar()
	old_draw_scrollbar(self)
	if not plugin_config.overview or self.diff_view_parent then return end
	local state = get_state(self.buffer)
	if not state.is_in_repo or not state.ranges or #state.ranges == 0 then return end

	local sx, sy, sw, sh = self.v_scrollbar:get_track_rect()
	if sw <= 0 or sh <= 0 then return end

	local source_h = math.max(1, self:get_scrollable_size())
	local min_h = style.gitdiff_overview_min_height

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
		local y = sy + ratio_start * sh
		local h = math.max(min_h, (ratio_end - ratio_start) * sh)
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

local old_text_change = Buffer.on_text_change
function Buffer:on_text_change(change_type, transaction, ...)
	local result = old_text_change(self, change_type, transaction, ...)
	if not buffer_gitdiff_disabled(self) and get_state(self).is_in_repo then schedule_local_diff(self, "text-change") end
	return result
end

local old_buffer_load = Buffer.load
function Buffer:load(...)
	local results = pack_results(old_buffer_load(self, ...))
	if not buffer_gitdiff_disabled(self) then schedule_base_reload(self, "load") end
	return unpack(results, 1, results.n)
end

-- A save does not change the Git base. Keep the live ranges in place.

local old_set_filename = Buffer.set_filename
function Buffer:set_filename(...)
	local old_path = self.abs_filename
	local results = pack_results(old_set_filename(self, ...))
	local same_path = old_path == self.abs_filename
		or (old_path and self.abs_filename and common.path_equals(old_path, self.abs_filename))
	if same_path then return unpack(results, 1, results.n) end
	local state = ensure_state(self)
	state.base_generation = state.base_generation + 1
	state.local_generation = state.local_generation + 1
	clear_state(self, "path changed")
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
	if not file_context.is_editor_view(view) or not view.buffer then return nil, "no-provider" end
	local buffer = view.buffer
	local state = get_state(buffer)
	local unavailable = gitdiff_unavailable_message(state)
	if unavailable then return nil, unavailable end
	local points = {}
	for _, range in ipairs(state.ranges or {}) do
		local line = math.min(#buffer.lines, math.max(1, range.current_start or 1))
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

local textview_get_points_of_interest = TextView.get_points_of_interest
function TextView:get_points_of_interest(opts)
	local git_points, unavailable = gitdiff_points_for_view(self, opts)
	local provider_points, provider_unavailable
	if textview_get_points_of_interest then
		provider_points, provider_unavailable = textview_get_points_of_interest(self, opts)
	end
	if git_points and provider_points then
		local combined = {}
		for _, point in ipairs(git_points) do combined[#combined + 1] = point end
		for _, point in ipairs(provider_points) do combined[#combined + 1] = point end
		return combined
	end
	return git_points or provider_points, unavailable or provider_unavailable
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
	["editor:previous_git_change"] = function(view) jump_to_gitdiff_change(view, -1) end,
	["editor:next_git_change"] = function(view) jump_to_gitdiff_change(view, 1) end,
})

command.add("core.textview", {
	["editor:refresh_git_changes"] = function()
		local view = core.active_view
		if view and view.buffer then schedule_base_reload(view.buffer, "manual-refresh") end
	end,
	["core:debug_git_changes"] = function()
		local view = core.active_view
		local buffer = view and view.buffer
		if not buffer then return end
		write_debug_dump(buffer)
	end,
})

function gitdiff_highlight._set_state_for_tests(buffer, state)
	states[buffer] = state
end

return gitdiff_highlight
