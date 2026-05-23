-- mod-version:3
-- Highlights changed lines, if file is in a git repository.
-- Also supports MiniMap, if user has it installed and activated.
local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local Doc = require "core.doc"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local gitdiff = require "plugins.gitdiff_highlight.gitdiff"

-- vscode defaults
style.gitdiff_addition = style.gitdiff_addition or { common.color "#587c0c" }
style.gitdiff_modification = style.gitdiff_modification or { common.color "#0c7d9d" }
style.gitdiff_deletion = style.gitdiff_deletion or { common.color "#94151b" }

local function color_for_diff(diff)
	if diff == "addition" then
		return style.gitdiff_addition
	elseif diff == "modification" then
		return style.gitdiff_modification
	else
		return style.gitdiff_deletion
	end
end

style.gitdiff_width = style.gitdiff_width or 3

-- maximum size of git diff to read, multiplied by current filesize
local gitdiff_highlight = {
	max_diff_size = 2,
}


local diffs = setmetatable({}, { __mode = "k" })

local function get_diff(doc)
	return diffs[doc] or { is_in_repo = false }
end

local function is_blank_line(doc, line)
	local text = doc.lines[line]
	return text ~= nil and text:match("^%s*$") ~= nil
end

local function effective_diff_for_line(doc, line)
	local diff = get_diff(doc)
	local change = diff[line]
	if change or not is_blank_line(doc, line) then return change end

	-- IntelliJ paints change markers continuously through blank lines inside a
	-- changed block.  git --word-diff often reports the surrounding edited lines
	-- but leaves completely blank lines in between unmarked, which creates a
	-- dashed/intermittent gutter stripe.  If this blank line is between changed
	-- lines with only blank lines in between, treat it as part of that block.
	local prev_line = line - 1
	while prev_line >= 1 and is_blank_line(doc, prev_line) do
		prev_line = prev_line - 1
	end

	local next_line = line + 1
	while next_line <= #doc.lines and is_blank_line(doc, next_line) do
		next_line = next_line + 1
	end

	local prev_change = diff[prev_line]
	local next_change = diff[next_line]
	if prev_change and next_change then
		return prev_change == next_change and prev_change or "modification"
	end
end

local function gitdiff_padding(dv)
	return style.padding.x * 1.5 + dv:get_font():get_width(#dv.doc.lines)
end

local function update_diff(doc)
	if not doc or not doc.abs_filename then return end

	local full_path = doc.abs_filename
	core.log_quiet("[gitdiff_highlight] updating diff for " .. full_path)

	local path = full_path:match("(.*" .. PATHSEP .. ")")

	if not get_diff(doc).is_in_repo then
		local git_proc = process.start({
			"git", "-C", path, "ls-files", "--error-unmatch", full_path
		})
		while git_proc:running() do
			coroutine.yield(0.1)
		end
		if 0 ~= git_proc:returncode() then
			core.log_quiet("[gitdiff_highlight] file "
					.. full_path .. " is not in a git repository")

			return
		end
	end

	local max_diff_size
	local finfo = system.get_file_info(full_path)
	max_diff_size = gitdiff_highlight.max_diff_size * finfo.size
	local diff_proc = process.start({
		"git", "-C", path, "diff", "HEAD", "--word-diff",
		"--unified=1", "--no-color", full_path
	})
	while diff_proc:running() do
		coroutine.yield(0.1)
	end
	diffs[doc] = gitdiff.changed_lines(diff_proc:read_stdout(max_diff_size))
	diffs[doc].is_in_repo = true
end

local old_docview_gutter = DocView.draw_line_gutter
local old_gutter_width = DocView.get_gutter_width
function DocView:draw_line_gutter(line, x, y, width)
	if not get_diff(self.doc).is_in_repo then
		return old_docview_gutter(self, line, x, y, width)
	end

	local lh = self:get_line_height()

	-- Use the caller-provided width, which already includes the always-reserved
	-- gitdiff lane. Otherwise line numbers shift left when async git state flips
	-- from unknown/non-repo to in-repo.
	old_docview_gutter(self, line, x, y, width)

	local line_diff = effective_diff_for_line(self.doc, line)
	if line_diff == nil then
		return lh
	end

	local color = color_for_diff(line_diff)

	-- add margin in between highlight and text
	x = x + gitdiff_padding(self)

	if line_diff ~= "deletion" then
		renderer.draw_rect(x, y, style.gitdiff_width,
				lh, color)
		return lh
	end

	renderer.draw_rect(x - style.gitdiff_width * 2,
			y, style.gitdiff_width * 4, 2, color)

	return lh
end

function DocView:get_gutter_width()
	local gw, gpad = old_gutter_width(self)
	-- Reserve the gitdiff marker lane immediately so newly opened files do not
	-- shift right after the async git check/diff finishes.
	return gw + style.padding.x * style.gitdiff_width / 12, gpad
end

local old_text_change = Doc.on_text_change
local function on_text_change(doc)
	doc.gitdiff_highlight_last_doc_lines = #doc.lines
	return old_text_change(doc, type)
end
function Doc:on_text_change(type)
	if not get_diff(self).is_in_repo then return on_text_change(self) end

	local line = self:get_selection()
	if diffs[self][line] == "addition" then return on_text_change(self) end

	-- TODO figure out how to detect an addition
	local last_doc_lines = self.gitdiff_highlight_last_doc_lines or 0
	if type == "insert" or (type == "remove" and #self.lines == last_doc_lines) then
		diffs[self][line] = "modification"
	elseif type == "remove" then
		diffs[self][line] = "deletion"
	end
	return on_text_change(self)
end

local old_doc_save = Doc.save
function Doc:save(...)
	old_doc_save(self, ...)
	core.add_thread(update_diff, nil, self)
end

local old_doc_load = Doc.load
function Doc:load(...)
	old_doc_load(self, ...)
	self.gitdiff_highlight_last_doc_lines = #self.lines
	core.add_thread(update_diff, nil, self)
end

-- add minimap support only after all plugins are loaded
core.add_thread(function()
	-- don't load minimap if user has disabled it
	if false == config.plugins.minimap then return end

	-- abort if MiniMap isn't installed
	local found, MiniMap = pcall(require, "plugins.minimap")
	if not found then return end


	-- Override MiniMap's line_highlight_color, but first
	-- stash the old one
	local old_line_highlight_color = MiniMap.line_highlight_color
	function MiniMap:line_highlight_color(line_index)
		local diff = get_diff(core.active_view.doc)
		if diff.is_in_repo and diff[line_index] then
			return color_for_diff(diff[line_index])
		end
		return old_line_highlight_color(line_index)
	end
end)

local function jump_to_next_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()
	if not get_diff(doc).is_in_repo then return end

	while diffs[doc][line] do
		line = line + 1
	end

	while line <= #doc.lines do
		if diffs[doc][line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line + 1
	end
end

local function jump_to_previous_change()
	local doc = core.active_view.doc
	local line, col = doc:get_selection()
	if not get_diff(doc).is_in_repo then return end

	while diffs[doc][line] do
		line = line - 1
	end

	while line > 0 do
		if diffs[doc][line] then
			doc:set_selection(line, col, line, col)
			return
		end
		line = line - 1
	end
end

command.add("core.docview", {
	["gitdiff:previous-change"] = jump_to_previous_change,
	["gitdiff:next-change"] = jump_to_next_change
})
