local Object = require "core.object"
local Highlighter = require ".highlighter"
local translate = require ".translate"
local core = require "core"
local syntax = require "core.syntax"
local config = require "core.config"
local common = require "core.common"

-- Match IntelliJ-style default: keep a backup and restore it if writing fails.
-- Set config.safe_write = false to use the old direct truncate/write path.
if config.safe_write == nil then config.safe_write = true end
local tokenizer = require "core.tokenizer"

---@class core.doc : core.object
local Doc = Object:extend()

function Doc:__tostring() return "Doc" end

local function split_lines(text)
  local res = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(res, line)
  end
  return res
end

local reset_registered_selection_states
local sanitize_registered_selection_states
local snapshot_registered_selection_states
local restore_registered_selection_states


function Doc:new(filename, abs_filename, new_file)
  self.new_file = new_file
  self.encoding = nil
  self.bom = nil
  self.binary = false
  self.cache = {}
  self:reset()
  if filename then
    self:set_filename(filename, abs_filename)
    if not new_file then
      self:load(abs_filename)
    end
  end
  if new_file then
    self.crlf = config.line_endings == "crlf"
  end
end


function Doc:reset()
  self.lines = { "\n" }
  self.selections = { 1, 1, 1, 1 }
  self.search_selections = {}
  self.last_selection = 1
  self.undo_stack = { idx = 1 }
  self.redo_stack = { idx = 1 }
  self.clean_change_id = 1
  self.highlighter = Highlighter(self)
  self.overwrite = false
  self:reset_syntax()
  reset_registered_selection_states(self)
end


function Doc:clear_undo_redo()
  self.clean_change_id = 1
  self.undo_stack = { idx = 1 }
  self.redo_stack = { idx = 1 }
end


---Always returns a valid utf8 line even if the file contains binary data.
---@param idx integer
---@return string
function Doc:get_utf8_line(idx)
  if self.binary and self.clean_lines[idx] then
    return self.clean_lines[idx]
  end
  return self.lines[idx]
end


function Doc:reset_syntax()
  local header = self:get_text(1, 1, self:position_offset(1, 1, 128))
  local path = self.abs_filename
  if not path and self.filename then
    path = core.root_project().path .. PATHSEP .. self.filename
  end
  if path then path = common.normalize_path(path) end
  local syn = syntax.get(path, header)
  if self.syntax ~= syn then
    self.syntax = syn
    self.highlighter:soft_reset()
  end
end


function Doc:set_filename(filename, abs_filename)
  self.filename = filename
  self.abs_filename = abs_filename
  self:reset_syntax()
end


function Doc:needs_encoding_conversion()
  local charset = self.encoding
  if charset and charset ~= "UTF-8" and charset ~= "ASCII" then
    return true
  end
  return false
end

local copy_file, prompt_stale_backup

function Doc:load(filename)
  if prompt_stale_backup then prompt_stale_backup(filename) end
  local selection_snapshots = snapshot_registered_selection_states(self)
  if not self.encoding then
    local errmsg
    self.encoding, self.bom, errmsg = encoding.detect(filename);
    if not self.encoding then
      core.error("%s", errmsg)
      self.encoding = "UTF-8"
    end
  elseif self.bom then
    self.bom = encoding.get_charset_bom(self.encoding)
  end
  local convert = self:needs_encoding_conversion()
  local fp = assert( io.open(filename, "rb") )
  self:reset()
  self.lines = {}
  self.clean_lines = {}
  local i = 1
  if convert then
    local content = fp:read("*a");
    content = assert(encoding.convert("UTF-8", self.encoding, content, {
      strict = false,
      handle_from_bom = true
    }))
    for line in content:gmatch("([^\n]*)\n?") do
      if line:byte(-1) == 13 then
        line = line:sub(1, -2)
        self.crlf = true
      end
      table.insert(self.lines, line .. "\n")
      self.highlighter.lines[i] = false
      i = i + 1
    end
    content = nil
  else
    for line in fp:lines() do
      if (i == 1) then line = encoding.strip_bom(line, "UTF-8") end
      if line:byte(-1) == 13 then
        line = line:sub(1, -2)
        self.crlf = true
      end
      table.insert(self.lines, line .. "\n")
      if not line:uisvalid() then
        self.binary = true
        self.clean_lines[i] = line:uclean("\26", true) .. "\n"
      end
      self.highlighter.lines[i] = false
      i = i + 1
    end
  end
  if #self.lines == 0 then
    table.insert(self.lines, "\n")
  end
  fp:close()
  self:reset_syntax()
  restore_registered_selection_states(self, selection_snapshots)
end


function Doc:reload()
  if self.filename then
    self:load(self.abs_filename)
    self:clean()
    sanitize_registered_selection_states(self)
  end
end


local function open_for_writing(filename)
  local fp
  if PLATFORM == "Windows" then
    -- On Windows, opening a hidden file with wb fails with a permission error.
    -- To get around this, we must open the file as r+b and truncate.
    -- Since r+b fails if file doesn't exist, fall back to wb.
    fp = io.open(filename, "r+b")
    if fp then
      system.ftruncate(fp)
    else
      -- file probably doesn't exist, create one
      fp = assert ( io.open(filename, "wb") )
    end
  else
    fp = assert ( io.open(filename, "wb") )
  end
  return fp
end


local function split_path(filename)
  local dir, base = filename:match("^(.*[\\/])([^\\/]*)$")
  if dir then return dir, base end
  return "", filename
end


local function unique_sidecar_name(filename, suffix)
  local dir, base = split_path(filename)
  local seed = tostring(math.floor(system.get_time() * 1000000))
  for i = 1, 1000 do
    local candidate = string.format("%s.%s.%s.%d.%s", dir, base, seed, i, suffix)
    if not system.get_file_info(candidate) then return candidate end
  end
  error("could not allocate temporary filename for " .. filename)
end


local function check_io(ok, err)
  if not ok then error(err or "I/O error") end
  return ok
end


copy_file = function(src, dst)
  local input = assert(io.open(src, "rb"))
  local output, open_err = io.open(dst, "wb")
  if not output then
    input:close()
    error(open_err or "could not open output file")
  end
  local ok, err = pcall(function()
    while true do
      local chunk = input:read(1024 * 1024)
      if not chunk then break end
      check_io(output:write(chunk))
    end
    check_io(output:flush())
  end)
  local close_in_ok, close_in_err = input:close()
  local close_out_ok, close_out_err = output:close()
  if not ok then error(err) end
  check_io(close_in_ok, close_in_err)
  check_io(close_out_ok, close_out_err)
end


local prompted_backups = {}

local function find_stale_backup(filename)
  local dir, base = split_path(filename)
  local list_dir = dir ~= "" and dir:sub(1, -2) or "."
  local items = system.list_dir(list_dir)
  if not items then return nil end
  local prefix = "." .. base .. "."
  local best, best_time
  for _, item in ipairs(items) do
    if item:sub(1, #prefix) == prefix and item:match("%.anvil%-bak$") then
      local path = dir .. item
      local info = system.get_file_info(path)
      if info and (not best_time or info.modified > best_time) then
        best, best_time = path, info.modified
      end
    end
  end
  return best
end

prompt_stale_backup = function(filename)
  local backup = find_stale_backup(filename)
  if not backup or prompted_backups[backup] then return end
  prompted_backups[backup] = true
  core.nag_view:show(
    "Save Backup Found",
    string.format("Anvil found a backup created during an earlier save of %s. The previous save may have been interrupted.", filename),
    {
      { text = "Restore Backup" },
      { text = "Delete Backup" },
      { text = "Ignore", default_no = true },
    },
    function(item)
      if item.text == "Restore Backup" then
        local ok, err = pcall(copy_file, backup, filename)
        if ok then
          os.remove(backup)
          for _, doc in ipairs(core.docs or {}) do
            if common.path_equals(doc.abs_filename, filename) then
              local loaded, load_err = pcall(doc.load, doc, filename)
              if loaded then
                doc:clean()
                sanitize_registered_selection_states(doc)
              else
                core.error("Couldn't reload restored backup %s: %s", filename, load_err)
              end
            end
          end
          core.log("Restored save backup for %s", filename)
        else
          core.error("Couldn't restore save backup %s: %s", backup, err)
        end
      elseif item.text == "Delete Backup" then
        local removed, err = os.remove(backup)
        if not removed then core.error("Couldn't delete save backup %s: %s", backup, err) end
      end
    end
  )
end


local function ensure_parent_directory(filename)
  local dir = common.dirname(filename)
  if not dir then return end
  local info = system.get_file_info(dir)
  if info then
    if info.type ~= "dir" then
      error(string.format("parent path is not a directory: %s", dir))
    end
    return
  end
  local ok, err, path = common.mkdirp(dir)
  if not ok then
    error(string.format("could not create parent directory %s: %s", path or dir, err or "unknown error"))
  end
  core.log_quiet("Created parent directory hierarchy \"%s\" before saving", dir)
end

local function write_file_safely(filename, writer)
  ensure_parent_directory(filename)

  local backup
  if config.safe_write ~= false and system.get_file_info(filename) then
    backup = unique_sidecar_name(filename, "anvil-bak")
    copy_file(filename, backup)
  end

  local fp = open_for_writing(filename)
  local ok, err = pcall(function()
    writer(fp)
    check_io(fp:flush())
    check_io(fp:close())
  end)

  if not ok then
    pcall(function() fp:close() end)
    if backup then
      local restored, restore_err = pcall(copy_file, backup, filename)
      if not restored then
        error(string.format("%s; additionally failed to restore backup %s: %s", tostring(err), backup, tostring(restore_err)))
      end
    end
    error(err)
  end

  if backup then
    local removed, remove_err = os.remove(backup)
    if not removed then core.error("Couldn't delete save backup %s: %s", backup, remove_err) end
  end
end


function Doc:save(filename, abs_filename)
  if not filename then
    assert(self.filename, "no filename set to default to")
    filename = self.filename
    abs_filename = self.abs_filename
  else
    assert(self.filename or abs_filename, "calling save on unnamed doc without absolute path")
    abs_filename = abs_filename or core.project_absolute_path(filename)
  end

  local output
  if self:needs_encoding_conversion() then
    output = table.concat(self.lines)
    if self.crlf then output = output:gsub("\n", "\r\n") end
    local errmsg
    output, errmsg = encoding.convert(self.encoding, "UTF-8", output, {
      strict = true
    })
    if not output then
      self.new_file = true
      core.error("%s", errmsg)
      error(errmsg)
    elseif self.bom then
      output = self.bom .. output
    end
  end

  write_file_safely(abs_filename, function(fp)
    if output then
      check_io(fp:write(output))
    else
      if self.bom then check_io(fp:write(self.bom)) end
      for _, line in ipairs(self.lines) do
        if self.crlf then line = line:gsub("\n", "\r\n") end
        check_io(fp:write(line))
      end
    end
  end)

  self:set_filename(filename, abs_filename)
  self.new_file = false
  self:clean()
end


function Doc:get_name()
  return self.filename or "unsaved"
end


function Doc:is_dirty()
  if self.new_file then
    if self.filename then return true end
    return #self.lines > 1 or #self:get_utf8_line(1) > 1
  else
    return self.clean_change_id ~= self:get_change_id()
  end
end


function Doc:clean()
  self.clean_change_id = self:get_change_id()
end


function Doc:get_indent_info()
  if not self.indent_info then return config.tab_type, config.indent_size, false end
  return self.indent_info.type or config.tab_type,
         self.indent_info.size or config.indent_size,
         self.indent_info.confirmed
end


function Doc:get_change_id()
  return self.undo_stack.idx
end

local function sort_positions(line1, col1, line2, col2)
  if line1 > line2 or line1 == line2 and col1 > col2 then
    return line2, col2, line1, col1, true
  end
  return line1, col1, line2, col2, false
end

local function selection_state_count(state)
  return math.max(1, math.floor(#(state.selections or {}) / 4))
end

local function sync_unbound_selection_mutation(self)
  if self.bound_selection_view or self.__selection_text_adjusting then return end
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.sync_doc_mirror_owner_state then
    DocView.sync_doc_mirror_owner_state(self)
  end
end

reset_registered_selection_states = function(self)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.reset_registered_selection_states then
    DocView.reset_registered_selection_states(self)
  end
end

sanitize_registered_selection_states = function(self)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.sanitize_registered_selection_states then
    DocView.sanitize_registered_selection_states(self)
  end
end

snapshot_registered_selection_states = function(self)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.snapshot_registered_selection_states then
    return DocView.snapshot_registered_selection_states(self)
  end
  return nil
end

restore_registered_selection_states = function(self, snapshots)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.restore_registered_selection_states then
    DocView.restore_registered_selection_states(self, snapshots)
  end
end

local function adjust_registered_selection_states(self, kind, ...)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.adjust_registered_selection_states then
    DocView.adjust_registered_selection_states(self, kind, self.bound_selection_view, ...)
  end
end

local function adjust_registered_selection_states_for_batch(self, mapper, transaction)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.adjust_registered_selection_states_for_batch then
    DocView.adjust_registered_selection_states_for_batch(self, self.bound_selection_view, mapper, transaction)
  end
end

local function current_selection_owner_id(self)
  if self.bound_selection_owner_id then return self.bound_selection_owner_id end
  if self.bound_selection_session_id then return self.bound_selection_session_id end
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.get_doc_mirror_owner_id then
    return DocView.get_doc_mirror_owner_id(self)
  end
  if ok and DocView.get_doc_mirror_owner_session_id then
    return DocView.get_doc_mirror_owner_session_id(self)
  end
end

local function registered_docview_count(self)
  local ok, DocView = pcall(require, "core.docview")
  if ok and DocView.count_registered_docviews then
    return DocView.count_registered_docviews(self)
  end
  return 0
end

local function can_restore_selection_undo(self, cmd)
  local owner = cmd.selection_owner_id or cmd.selection_session_id
  if owner then
    return owner == current_selection_owner_id(self)
  end
  return registered_docview_count(self) <= 1
end

local function state_selection_iterator(invariant, idx)
  local target = invariant[3] and (idx*4 - 7) or (idx*4 + 1)
  if target > #invariant[1] or target <= 0 or (type(invariant[3]) == "number" and invariant[3] ~= idx - 1) then return end
  if invariant[2] then
    return idx+(invariant[3] and -1 or 1), sort_positions(table.unpack(invariant[1], target, target+4))
  else
    return idx+(invariant[3] and -1 or 1), table.unpack(invariant[1], target, target+4)
  end
end

local function each_state_selection(state, sort_intra, idx_reverse)
  local selections = state.selections
  return state_selection_iterator, { selections, sort_intra, idx_reverse },
    idx_reverse == true and ((#selections / 4) + 1) or ((idx_reverse or -1)+1)
end

local function set_state_selections(self, state, idx, line1, col1, line2, col2, swap, rm)
  assert(not line2 == not col2, "expected 3 or 5 arguments")
  if swap then line1, col1, line2, col2 = line2, col2, line1, col1 end
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2 or line1, col2 or col1)
  common.splice(state.selections, (idx - 1)*4 + 1, rm == nil and 4 or rm, { line1, col1, line2, col2 })
end

local function sanitize_selection_state(self, state)
  if type(state.selections) ~= "table" or #state.selections < 4 then
    local line, col = self:sanitize_position(1, 1)
    state.selections = { line, col, line, col }
  end
  for idx, line1, col1, line2, col2 in each_state_selection(state, false) do
    set_state_selections(self, state, idx, line1, col1, line2, col2)
  end
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_state_count(state))
end

local function merge_state_cursors(state, idx)
  local table_index = idx and (idx - 1) * 4 + 1
  for i = (table_index or (#state.selections - 3)), (table_index or 5), -4 do
    for j = 1, i - 4, 4 do
      if state.selections[i] == state.selections[j] and
        state.selections[i+1] == state.selections[j+1] then
          common.splice(state.selections, i, 4)
          if state.last_selection >= (i+3)/4 then
            state.last_selection = state.last_selection - 1
          end
          break
      end
    end
  end
  state.last_selection = common.clamp(math.floor(tonumber(state.last_selection) or 1), 1, selection_state_count(state))
end

function Doc:adjust_selection_state_for_insert(state, line, col, lines, len)
  sanitize_selection_state(self, state)
  for idx, cline1, ccol1, cline2, ccol2 in each_state_selection(state, true, true) do
    if cline1 < line then break end
    local line_addition = (line < cline1 or col < ccol1) and #lines - 1 or 0
    local column_addition = line == cline1 and ccol1 > col and len or 0
    set_state_selections(self, state, idx, cline1 + line_addition, ccol1 + column_addition, cline2 + line_addition, ccol2 + column_addition)
  end
  sanitize_selection_state(self, state)
end

function Doc:adjust_selection_state_for_remove(state, line1, col1, line2, col2)
  if type(state.selections) ~= "table" or #state.selections < 4 then
    local line, col = self:sanitize_position(1, 1)
    state.selections = { line, col, line, col }
  end
  local line_removal = line2 - line1
  local col_removal = col2 - col1
  local merge = false
  for idx, cline1, ccol1, cline2, ccol2 in each_state_selection(state, true, true) do
    if cline2 < line1 then break end
    local l1, c1, l2, c2 = cline1, ccol1, cline2, ccol2

    if cline1 > line1 or (cline1 == line1 and ccol1 > col1) then
      if cline1 > line2 then
        l1 = l1 - line_removal
      else
        l1 = line1
        c1 = (cline1 == line2 and ccol1 > col2) and c1 - col_removal or col1
      end
    end

    if cline2 > line1 or (cline2 == line1 and ccol2 > col1) then
      if cline2 > line2 then
        l2 = l2 - line_removal
      else
        l2 = line1
        c2 = (cline2 == line2 and ccol2 > col2) and c2 - col_removal or col1
      end
    end

    if l1 == line1 and c1 == col1 then merge = true end
    set_state_selections(self, state, idx, l1, c1, l2, c2)
  end
  if merge then merge_state_cursors(state) end
  sanitize_selection_state(self, state)
end

-- Cursor section. Cursor indices are *only* valid during a get_selections() call.
-- Cursors will always be iterated in order from top to bottom. Through normal operation
-- curors can never swap positions; only merge or split, or change their position in cursor
-- order.
function Doc:get_selection(sort)
  local line1, col1, line2, col2, swap = self:get_selection_idx(self.last_selection, sort)
  if not line1 then
    line1, col1, line2, col2, swap = self:get_selection_idx(1, sort)
  end
  return line1, col1, line2, col2, swap
end


---Get the selection specified by `idx`
---@param idx integer @the index of the selection to retrieve
---@param sort? boolean @whether to sort the selection returned
---@return integer,integer,integer,integer,boolean? @line1, col1, line2, col2, was the selection sorted
function Doc:get_selection_idx(idx, sort)
  local line1, col1, line2, col2 = self.selections[idx*4-3], self.selections[idx*4-2], self.selections[idx*4-1], self.selections[idx*4]
  if line1 and sort then
    return sort_positions(line1, col1, line2, col2)
  else
    return line1, col1, line2, col2
  end
end

function Doc:get_selection_text(limit)
  limit = limit or math.huge
  local result = {}
  for idx, line1, col1, line2, col2 in self:get_selections() do
    if idx > limit then break end
    if line1 ~= line2 or col1 ~= col2 then
      local text = self:get_text(line1, col1, line2, col2)
      if text ~= "" then result[#result + 1] = text end
    end
  end
  return table.concat(result, "\n")
end

function Doc:has_selection()
  local line1, col1, line2, col2 = self:get_selection(false)
  return line1 ~= line2 or col1 ~= col2
end

function Doc:has_any_selection()
  for idx, line1, col1, line2, col2 in self:get_selections() do
    if line1 ~= line2 or col1 ~= col2 then return true end
  end
  return false
end

function Doc:sanitize_selection()
  for idx, line1, col1, line2, col2 in self:get_selections() do
    self:set_selections(idx, line1, col1, line2, col2)
  end
end

function Doc:set_selections(idx, line1, col1, line2, col2, swap, rm)
  assert(not line2 == not col2, "expected 3 or 5 arguments")
  if swap then line1, col1, line2, col2 = line2, col2, line1, col1 end
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2 or line1, col2 or col1)
  common.splice(self.selections, (idx - 1)*4 + 1, rm == nil and 4 or rm, { line1, col1, line2, col2 })
  sync_unbound_selection_mutation(self)
end

function Doc:add_selection(line1, col1, line2, col2, swap)
  local l1, c1 = sort_positions(line1, col1, line2 or line1, col2 or col1)
  local target = #self.selections / 4 + 1
  for idx, tl1, tc1 in self:get_selections(true) do
    if l1 < tl1 or l1 == tl1 and c1 < tc1 then
      target = idx
      break
    end
  end
  self:set_selections(target, line1, col1, line2, col2, swap, 0)
  self.last_selection = target
  sync_unbound_selection_mutation(self)
end


function Doc:remove_selection(idx)
  if self.last_selection >= idx then
    self.last_selection = self.last_selection - 1
  end
  common.splice(self.selections, (idx - 1) * 4 + 1, 4)
  if #self.selections < 4 then
    local line, col = self:sanitize_position(1, 1)
    self.selections = { line, col, line, col }
  end
  self.last_selection = common.clamp(math.floor(tonumber(self.last_selection) or 1), 1, selection_state_count(self))
  sync_unbound_selection_mutation(self)
end


function Doc:set_selection(line1, col1, line2, col2, swap)
  self.selections = {}
  self:set_selections(1, line1, col1, line2, col2, swap)
  self.last_selection = 1
  sync_unbound_selection_mutation(self)
end

function Doc:merge_cursors(idx)
  local table_index = idx and (idx - 1) * 4 + 1
  for i = (table_index or (#self.selections - 3)), (table_index or 5), -4 do
    for j = 1, i - 4, 4 do
      if self.selections[i] == self.selections[j] and
        self.selections[i+1] == self.selections[j+1] then
          common.splice(self.selections, i, 4)
          if self.last_selection >= (i+3)/4 then
            self.last_selection = self.last_selection - 1
          end
          break
      end
    end
  end
  self.last_selection = common.clamp(math.floor(tonumber(self.last_selection) or 1), 1, selection_state_count(self))
  sync_unbound_selection_mutation(self)
end

local function selection_iterator(invariant, idx)
  local target = invariant[3] and (idx*4 - 7) or (idx*4 + 1)
  if target > #invariant[1] or target <= 0 or (type(invariant[3]) == "number" and invariant[3] ~= idx - 1) then return end
  if invariant[2] then
    return idx+(invariant[3] and -1 or 1), sort_positions(table.unpack(invariant[1], target, target+4))
  else
    return idx+(invariant[3] and -1 or 1), table.unpack(invariant[1], target, target+4)
  end
end

-- If idx_reverse is true, it'll reverse iterate. If nil, or false, regular iterate.
-- If a number, runs for exactly that iteration.
function Doc:get_selections(sort_intra, idx_reverse)
  return selection_iterator, { self.selections, sort_intra, idx_reverse },
    idx_reverse == true and ((#self.selections / 4) + 1) or ((idx_reverse or -1)+1)
end
-- End of cursor seciton.

function Doc:sanitize_position(line, col)
  local nlines = #self.lines
  if line > nlines then
    return nlines, #self:get_utf8_line(nlines)
  elseif line < 1 then
    return 1, 1
  end
  return line, common.clamp(col, 1, #self:get_utf8_line(line))
end


local function position_offset_func(self, line, col, fn, ...)
  line, col = self:sanitize_position(line, col)
  return fn(self, line, col, ...)
end


local function position_offset_byte(self, line, col, offset)
  line, col = self:sanitize_position(line, col)
  col = col + offset
  while line > 1 and col < 1 do
    line = line - 1
    col = col + #self:get_utf8_line(line)
  end
  while line < #self.lines and col > #self:get_utf8_line(line) do
    col = col - #self:get_utf8_line(line)
    line = line + 1
  end
  return self:sanitize_position(line, col)
end


local function position_offset_linecol(self, line, col, lineoffset, coloffset)
  return self:sanitize_position(line + lineoffset, col + coloffset)
end


function Doc:position_offset(line, col, ...)
  if type(...) ~= "number" then
    return position_offset_func(self, line, col, ...)
  elseif select("#", ...) == 1 then
    return position_offset_byte(self, line, col, ...)
  elseif select("#", ...) == 2 then
    return position_offset_linecol(self, line, col, ...)
  else
    error("bad number of arguments")
  end
end


---Returns the content of the doc between two positions. </br>
---The positions will be sanitized and sorted. </br>
---The character at the "end" position is not included by default.
---@see core.doc.sanitize_position
---@param line1 integer
---@param col1 integer
---@param line2 integer
---@param col2 integer
---@param inclusive boolean? Whether or not to return the character at the last position
---@return string
function Doc:get_text(line1, col1, line2, col2, inclusive)
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  local col2_offset = inclusive and 0 or 1
  if line1 == line2 then
    return self.lines[line1]:sub(col1, col2 - col2_offset)
  end
  local lines = { self.lines[line1]:sub(col1) }
  for i = line1 + 1, line2 - 1 do
    table.insert(lines, self.lines[i])
  end
  table.insert(lines, self.lines[line2]:sub(1, col2 - col2_offset))
  return table.concat(lines)
end


function Doc:get_char(line, col)
  line, col = self:sanitize_position(line, col)
  return self:get_utf8_line(line):sub(col, col)
end


local function push_undo(undo_stack, time, type, ...)
  undo_stack[undo_stack.idx] = { type = type, time = time, ... }
  undo_stack[undo_stack.idx - config.max_undos] = nil
  undo_stack.idx = undo_stack.idx + 1
  return undo_stack[undo_stack.idx - 1]
end

local function copy_undo_array(t)
  local res = {}
  if t then for i = 1, #t do res[i] = t[i] end end
  return res
end

local function push_batch_undo(undo_stack, time, transaction, before_selections, before_last_selection, after_selections, after_last_selection)
  undo_stack[undo_stack.idx] = {
    type = "batch",
    time = time,
    change_type = transaction.type,
    selection_owner_id = transaction.selection_owner_id,
    before_selections = before_selections,
    before_last_selection = before_last_selection,
    after_selections = after_selections,
    after_last_selection = after_last_selection,
    edits = transaction.inverse_edits,
  }
  undo_stack[undo_stack.idx - config.max_undos] = nil
  undo_stack.idx = undo_stack.idx + 1
  return undo_stack[undo_stack.idx - 1]
end

local function push_selection_undo(self, undo_stack, time)
  local cmd = push_undo(undo_stack, time, "selection", table.unpack(self.selections))
  cmd.selection_owner_id = current_selection_owner_id(self)
  cmd.selection_session_id = cmd.selection_owner_id -- deprecated compatibility alias
  return cmd
end


local function pop_undo(self, undo_stack, redo_stack, modified)
  -- pop command
  local cmd = undo_stack[undo_stack.idx - 1]
  if not cmd then return end
  undo_stack.idx = undo_stack.idx - 1

  -- handle command
  if cmd.type == "insert" then
    local line, col, text = table.unpack(cmd)
    self:raw_insert(line, col, text, redo_stack, cmd.time)
  elseif cmd.type == "remove" then
    local line1, col1, line2, col2 = table.unpack(cmd)
    self:raw_remove(line1, col1, line2, col2, redo_stack, cmd.time)
  elseif cmd.type == "batch" then
    local is_redo = undo_stack == self.redo_stack
    local current_selections = copy_undo_array(self.selections)
    local current_last_selection = self.last_selection or 1
    local restore_selection = can_restore_selection_undo(self, cmd)
    local selections = restore_selection and (is_redo and cmd.after_selections or cmd.before_selections) or nil
    local last_selection = restore_selection and (is_redo and cmd.after_last_selection or cmd.before_last_selection) or nil
    local tx = self:apply_edits(cmd.edits, {
      type = is_redo and "redo" or "undo",
      record_undo = false,
      notify = false,
      clear_redo = false,
      selections = selections,
      last_selection = last_selection,
      merge_cursors = false,
      owner_id = cmd.selection_owner_id,
    })
    if tx and tx.applied and tx.changed then
      local before_selections, before_last_selection, after_selections, after_last_selection
      if is_redo then
        before_selections = current_selections
        before_last_selection = current_last_selection
        after_selections = tx.new_selections
        after_last_selection = tx.new_last_selection
      else
        before_selections = tx.new_selections
        before_last_selection = tx.new_last_selection
        after_selections = current_selections
        after_last_selection = current_last_selection
      end
      push_batch_undo(
        redo_stack,
        cmd.time,
        tx,
        before_selections,
        before_last_selection,
        after_selections,
        after_last_selection
      )
    end
  elseif cmd.type == "selection" then
    if can_restore_selection_undo(self, cmd) then
      self.selections = { table.unpack(cmd) }
      self:sanitize_selection()
      sync_unbound_selection_mutation(self)
    end
  end

  modified = modified or (cmd.type ~= "selection")

  -- if next undo command is within the merge timeout then treat as a single
  -- command and continue to execute it
  local next = undo_stack[undo_stack.idx - 1]
  if next and math.abs(cmd.time - next.time) < config.undo_merge_timeout then
    return pop_undo(self, undo_stack, redo_stack, modified)
  end

  if modified then
    self:on_text_change("undo")
  end
end

local function update_clean_lines(self, line1, line2)
  if self.binary then
    for i=line1, line2 do
      local clean_text, was_valid = "", true
      if self.lines[i] then
        clean_text, was_valid = self.lines[i]:uclean("\26", true)
      end
      if self.clean_lines[i] then self.clean_lines[i] = nil end
      if not was_valid then self.clean_lines[i] = clean_text end
    end
  end
end


function Doc:clear_cache(l, n)
  for _, cache in pairs(self.cache) do
    local lines = l + n
    for ln=l-1, lines do
      local line = ln + 1
      if cache[line] then
        cache[line] = nil
      end
      if line == lines then break end
    end
  end
end

function Doc:normalize_edit_text(text, edit, opts)
  return tostring(text or "")
end

function Doc:can_apply_edits(edits, opts)
  return true
end

local function copy_array(t)
  local res = {}
  if t then for i = 1, #t do res[i] = t[i] end end
  return res
end

local function line_starts_for(lines)
  local starts, offset = {}, 0
  for i = 1, #lines do
    starts[i] = offset
    offset = offset + #lines[i]
  end
  return starts, offset
end

local function sanitize_position_in_lines(lines, line, col)
  local nlines = #lines
  if line > nlines then
    return nlines, #(lines[nlines] or "")
  elseif line < 1 then
    return 1, 1
  end
  return line, common.clamp(col, 1, #(lines[line] or ""))
end

local function position_to_offset(starts, line, col)
  return starts[line] + col - 1
end

local function offset_to_position(lines, starts, total, offset)
  if offset <= 0 then return 1, 1 end
  if offset >= total then return #lines, #(lines[#lines] or "") end
  local lo, hi = 1, #lines
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local next_start = starts[mid + 1] or total + 1
    if offset < starts[mid] then
      hi = mid - 1
    elseif offset >= next_start then
      lo = mid + 1
    else
      return mid, offset - starts[mid] + 1
    end
  end
  return #lines, #(lines[#lines] or "")
end

local function text_from_lines(lines, line1, col1, line2, col2)
  if line1 == line2 then
    return lines[line1]:sub(col1, col2 - 1)
  end
  local parts = { lines[line1]:sub(col1) }
  for line = line1 + 1, line2 - 1 do
    parts[#parts + 1] = lines[line]
  end
  parts[#parts + 1] = lines[line2]:sub(1, col2 - 1)
  return table.concat(parts)
end

local function append_text_linewise(out, text)
  local pos = 1
  while true do
    local nl = text:find("\n", pos, true)
    if not nl then
      out[#out] = out[#out] .. text:sub(pos)
      break
    end
    out[#out] = out[#out] .. text:sub(pos, nl)
    out[#out + 1] = ""
    pos = nl + 1
  end
end

local function append_span(out, lines, line1, col1, line2, col2)
  if line1 > line2 or (line1 == line2 and col1 >= col2) then return end
  if line1 == line2 then
    append_text_linewise(out, lines[line1]:sub(col1, col2 - 1))
    return
  end
  append_text_linewise(out, lines[line1]:sub(col1))
  for line = line1 + 1, line2 - 1 do
    append_text_linewise(out, lines[line])
  end
  append_text_linewise(out, lines[line2]:sub(1, col2 - 1))
end

local function append_span_to_end(out, lines, line, col)
  if line > #lines then return end
  append_text_linewise(out, lines[line]:sub(col))
  for i = line + 1, #lines do
    append_text_linewise(out, lines[i])
  end
end

local function finalize_lines(out)
  if #out > 1 and out[#out] == "" then out[#out] = nil end
  if #out == 0 or (#out == 1 and out[1] == "") then return { "\n" } end
  return out
end

function Doc:apply_edits(edits, opts)
  opts = opts or {}
  local time = opts.time or system.get_time()
  local owner_id = opts.owner_id or current_selection_owner_id(self)
  local old_lines = self.lines
  local old_starts = line_starts_for(old_lines)
  local old_selections = copy_array(self.selections)
  local old_last_selection = self.last_selection or 1
  local normalized = {}
  local transaction = {
    applied = false,
    changed = false,
    selection_changed = false,
    rejected = false,
    type = opts.type or "batch",
    edits = normalized,
    inverse_edits = {},
    changed_ranges = {},
    old_selections = old_selections,
    new_selections = old_selections,
    old_last_selection = old_last_selection,
    new_last_selection = old_last_selection,
    selection_owner_id = owner_id,
  }

  if type(edits) ~= "table" then
    transaction.rejected = true
    transaction.reason = "edits must be a table"
    if opts.strict then error(transaction.reason) end
    return transaction
  end

  for i, edit in ipairs(edits) do
    local line1, col1 = sanitize_position_in_lines(old_lines, edit.line1 or 1, edit.col1 or 1)
    local line2, col2 = sanitize_position_in_lines(old_lines, edit.line2 or line1, edit.col2 or col1)
    line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
    local text = self:normalize_edit_text(edit.text or "", edit, opts)
    local old_text = text_from_lines(old_lines, line1, col1, line2, col2)
    if opts.allow_selection_only or old_text ~= text then
      local start_offset = position_to_offset(old_starts, line1, col1)
      local end_offset = position_to_offset(old_starts, line2, col2)
      normalized[#normalized + 1] = {
        line1 = line1, col1 = col1, line2 = line2, col2 = col2,
        text = text, old_text = old_text, idx = edit.idx, selection = edit.selection,
        affinity = edit.affinity, start_offset = start_offset, end_offset = end_offset,
        order = i,
      }
    end
  end

  table.sort(normalized, function(a, b)
    if a.start_offset == b.start_offset then return a.end_offset < b.end_offset end
    return a.start_offset < b.start_offset
  end)

  for i = 2, #normalized do
    local prev, cur = normalized[i - 1], normalized[i]
    if prev.end_offset > cur.start_offset
    or (prev.start_offset == prev.end_offset and cur.start_offset == cur.end_offset and prev.start_offset == cur.start_offset) then
      transaction.rejected = true
      transaction.reason = "overlapping edits"
      core.log_quiet("Rejected batch edit for %s: %s", self:get_name(), transaction.reason)
      if opts.strict then error(transaction.reason) end
      return transaction
    end
  end

  if not self:can_apply_edits(normalized, opts) then
    transaction.rejected = true
    transaction.reason = "document rejected edits"
    core.log_quiet("Rejected batch edit for %s: %s", self:get_name(), transaction.reason)
    if opts.strict then error(transaction.reason) end
    return transaction
  end

  local changed = #normalized > 0
  local out = { "" }
  local cursor_line, cursor_col = 1, 1
  for _, edit in ipairs(normalized) do
    append_span(out, old_lines, cursor_line, cursor_col, edit.line1, edit.col1)
    append_text_linewise(out, edit.text)
    cursor_line, cursor_col = edit.line2, edit.col2
  end
  append_span_to_end(out, old_lines, cursor_line, cursor_col)
  local new_lines = finalize_lines(out)
  local new_starts, new_total = line_starts_for(new_lines)

  local delta = 0
  for _, edit in ipairs(normalized) do
    local new_start = edit.start_offset + delta
    local new_end = new_start + #edit.text
    local il1, ic1 = offset_to_position(new_lines, new_starts, new_total, new_start)
    local il2, ic2 = offset_to_position(new_lines, new_starts, new_total, new_end)
    transaction.inverse_edits[#transaction.inverse_edits + 1] = {
      line1 = il1, col1 = ic1, line2 = il2, col2 = ic2, text = edit.old_text,
    }
    transaction.changed_ranges[#transaction.changed_ranges + 1] = {
      old_line1 = edit.line1,
      old_line2 = edit.line2,
      new_line1 = il1,
      new_line2 = il2,
      old_line_count = edit.line2 - edit.line1 + 1,
      new_line_count = il2 - il1 + 1,
      line_delta = (il2 - il1) - (edit.line2 - edit.line1),
    }
    delta = delta + #edit.text - (edit.end_offset - edit.start_offset)
  end

  self.lines = new_lines

  local function map_position(line, col, affinity)
    line, col = sanitize_position_in_lines(old_lines, line, col)
    local pos = position_to_offset(old_starts, line, col)
    local map_delta = 0
    for _, edit in ipairs(normalized) do
      if pos < edit.start_offset then
        break
      elseif edit.start_offset == edit.end_offset and pos == edit.start_offset then
        if affinity == "after" then map_delta = map_delta + #edit.text end
        break
      elseif pos <= edit.end_offset then
        return offset_to_position(new_lines, new_starts, new_total, edit.start_offset + map_delta)
      else
        map_delta = map_delta + #edit.text - (edit.end_offset - edit.start_offset)
      end
    end
    return offset_to_position(new_lines, new_starts, new_total, pos + map_delta)
  end

  local new_selections
  if opts.selections then
    new_selections = copy_array(opts.selections)
  else
    new_selections = {}
    local by_idx = {}
    for _, edit in ipairs(normalized) do
      if edit.selection then by_idx[edit.idx or edit.order] = edit.selection end
    end
    if next(by_idx) then
      for i = 1, math.max(1, #old_selections / 4) do
        local selection = by_idx[i]
        if selection then
          for j = 1, 4 do new_selections[#new_selections + 1] = selection[j] end
        end
      end
    else
      for i = 1, #old_selections, 4 do
        local l1, c1 = map_position(old_selections[i], old_selections[i + 1])
        local l2, c2 = map_position(old_selections[i + 2], old_selections[i + 3])
        new_selections[#new_selections + 1] = l1
        new_selections[#new_selections + 1] = c1
        new_selections[#new_selections + 1] = l2
        new_selections[#new_selections + 1] = c2
      end
    end
  end
  if #new_selections == 0 then new_selections = { 1, 1, 1, 1 } end
  local state = { selections = new_selections, last_selection = opts.last_selection or old_last_selection }
  sanitize_selection_state(self, state)
  if opts.merge_cursors then merge_state_cursors(state) end
  local selection_target = self.selections
  if type(selection_target) == "table" then
    for i = #selection_target, 1, -1 do selection_target[i] = nil end
    for i = 1, #state.selections do selection_target[i] = state.selections[i] end
    self.selections = selection_target
  else
    self.selections = state.selections
  end
  self.last_selection = state.last_selection
  transaction.new_selections = copy_array(self.selections)
  transaction.new_last_selection = self.last_selection
  transaction.selection_changed = true

  transaction.applied = true
  transaction.changed = changed

  if changed then
    local first_line = transaction.changed_ranges[1] and transaction.changed_ranges[1].new_line1 or 1
    update_clean_lines(self, first_line, #self.lines)
    if self.highlighter.batch_notify then
      self.highlighter:batch_notify(transaction.changed_ranges)
    else
      self.highlighter:soft_reset()
    end
    self:clear_cache(first_line, #self.lines - first_line)
    adjust_registered_selection_states_for_batch(self, map_position, transaction)

    if opts.record_undo ~= false then
      if opts.clear_redo ~= false then self.redo_stack = { idx = 1 } end
      if self:get_change_id() < self.clean_change_id then self.clean_change_id = -1 end
      push_batch_undo(self.undo_stack, time, transaction, old_selections, old_last_selection, transaction.new_selections, transaction.new_last_selection)
    end
    self:on_text_transaction(transaction)
    if opts.notify ~= false then self:on_text_change(transaction.type, transaction) end
    core.log_quiet("Applied batch edit to %s: edits=%d lines=%d", self:get_name(), #normalized, #self.lines)
  else
    sync_unbound_selection_mutation(self)
  end

  return transaction
end


function Doc:raw_insert(line, col, text, undo_stack, time)
  -- split text into lines and merge with line at insertion point
  local lines = split_lines(text)
  local len = #lines[#lines]
  local before = self.lines[line]:sub(1, col - 1)
  local after = self.lines[line]:sub(col)
  for i = 1, #lines - 1 do
    lines[i] = lines[i] .. "\n"
  end
  lines[1] = before .. lines[1]
  lines[#lines] = lines[#lines] .. after

  -- splice lines into line array
  common.splice(self.lines, line, 1, lines)

  update_clean_lines(self, line, ((line + #lines - 1) == line) and line or #self.lines)

  -- keep cursors where they should be
  local active_state = { selections = self.selections, last_selection = self.last_selection }
  self.__selection_text_adjusting = true
  self:adjust_selection_state_for_insert(active_state, line, col, lines, len)
  self.__selection_text_adjusting = nil
  self.selections = active_state.selections
  self.last_selection = active_state.last_selection
  adjust_registered_selection_states(self, "insert", line, col, lines, len)

  -- push undo
  local line2, col2 = self:position_offset(line, col, #text)
  push_selection_undo(self, undo_stack, time)
  push_undo(undo_stack, time, "remove", line, col, line2, col2)

  -- update highlighter and assure selection is in bounds
  self.highlighter:insert_notify(line, #lines - 1)
  self:clear_cache(line, #lines - 1)
  self:sanitize_selection()
end


function Doc:raw_remove(line1, col1, line2, col2, undo_stack, time)
  -- push undo
  local text = self:get_text(line1, col1, line2, col2)
  push_selection_undo(self, undo_stack, time)
  push_undo(undo_stack, time, "insert", line1, col1, text)

  -- get line content before/after removed text
  local before = self.lines[line1]:sub(1, col1 - 1)
  local after = self.lines[line2]:sub(col2)

  local line_removal = line2 - line1
  local col_removal = col2 - col1

  -- splice line into line array
  common.splice(self.lines, line1, line_removal + 1, { before .. after })

  update_clean_lines(self, line1, line2 == line1 and line2 or #self.lines)

  -- keep selections in correct positions: each pair (line, col)
  -- * remains unchanged if before the deleted text
  -- * is set to (line1, col1) if in the deleted text
  -- * is set to (line1, col - col_removal) if on line2 but out of the deleted text
  -- * is set to (line - line_removal, col) if after line2
  local active_state = { selections = self.selections, last_selection = self.last_selection }
  self.__selection_text_adjusting = true
  self:adjust_selection_state_for_remove(active_state, line1, col1, line2, col2)
  self.__selection_text_adjusting = nil
  self.selections = active_state.selections
  self.last_selection = active_state.last_selection
  adjust_registered_selection_states(self, "remove", line1, col1, line2, col2)

  -- update highlighter and assure selection is in bounds
  self.highlighter:remove_notify(line1, line_removal)
  self:clear_cache(line1, line_removal)
  self:sanitize_selection()
end


function Doc:insert(line, col, text)
  line, col = self:sanitize_position(line, col)
  return self:apply_edits({
    { line1 = line, col1 = col, line2 = line, col2 = col, text = text },
  }, {
    type = "insert",
    merge_cursors = false,
  })
end


function Doc:remove(line1, col1, line2, col2)
  line1, col1 = self:sanitize_position(line1, col1)
  line2, col2 = self:sanitize_position(line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  return self:apply_edits({
    { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = "" },
  }, {
    type = "remove",
    merge_cursors = true,
  })
end


function Doc:undo()
  pop_undo(self, self.undo_stack, self.redo_stack, false)
end


function Doc:redo()
  pop_undo(self, self.redo_stack, self.undo_stack, false)
end

local function build_lines_for_normalized_edits(old_lines, normalized)
  local out = { "" }
  local cursor_line, cursor_col = 1, 1
  for _, edit in ipairs(normalized) do
    append_span(out, old_lines, cursor_line, cursor_col, edit.line1, edit.col1)
    append_text_linewise(out, edit.text)
    cursor_line, cursor_col = edit.line2, edit.col2
  end
  append_span_to_end(out, old_lines, cursor_line, cursor_col)
  return finalize_lines(out)
end

local function plan_normalized_edits(self, edits, opts)
  opts = opts or {}
  local old_lines = self.lines
  local starts = line_starts_for(old_lines)
  local normalized = {}
  for _, edit in ipairs(edits) do
    local line1, col1 = sanitize_position_in_lines(old_lines, edit.line1, edit.col1)
    local line2, col2 = sanitize_position_in_lines(old_lines, edit.line2, edit.col2)
    line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
    local text = self:normalize_edit_text(edit.text or "", edit, opts)
    local start_offset = position_to_offset(starts, line1, col1)
    local end_offset = position_to_offset(starts, line2, col2)
    normalized[#normalized + 1] = {
      line1 = line1, col1 = col1, line2 = line2, col2 = col2,
      text = text, idx = edit.idx,
      start_offset = start_offset, end_offset = end_offset,
    }
  end
  table.sort(normalized, function(a, b)
    if a.start_offset == b.start_offset then return a.end_offset < b.end_offset end
    return a.start_offset < b.start_offset
  end)
  return normalized
end

local function final_selections_after_edits(self, normalized, final_by_idx, last_selection)
  local old_lines = self.lines
  local old_starts = line_starts_for(old_lines)
  local new_lines = build_lines_for_normalized_edits(old_lines, normalized)
  local new_starts, new_total = line_starts_for(new_lines)
  local final_offsets = {}
  local delta = 0
  local function final_offset_for(target, new_start, edit)
    if target == "start" then return new_start end
    if type(target) == "number" then return new_start + target end
    return new_start + #edit.text
  end
  for _, edit in ipairs(normalized) do
    local new_start = edit.start_offset + delta
    local target = final_by_idx and final_by_idx[edit.idx]
    if type(target) == "table" then
      final_offsets[edit.idx] = {}
      for i, item in ipairs(target) do
        final_offsets[edit.idx][i] = final_offset_for(item, new_start, edit)
      end
    else
      final_offsets[edit.idx] = final_offset_for(target, new_start, edit)
    end
    delta = delta + #edit.text - (edit.end_offset - edit.start_offset)
  end

  local function map_position(line, col, affinity)
    line, col = sanitize_position_in_lines(old_lines, line, col)
    local pos = position_to_offset(old_starts, line, col)
    local map_delta = 0
    for _, edit in ipairs(normalized) do
      if pos < edit.start_offset then
        break
      elseif edit.start_offset == edit.end_offset and pos == edit.start_offset then
        if affinity == "after" then map_delta = map_delta + #edit.text end
        break
      elseif pos <= edit.end_offset then
        return offset_to_position(new_lines, new_starts, new_total, edit.start_offset + map_delta)
      else
        map_delta = map_delta + #edit.text - (edit.end_offset - edit.start_offset)
      end
    end
    return offset_to_position(new_lines, new_starts, new_total, pos + map_delta)
  end

  local new_selections = {}
  for i = 1, #self.selections, 4 do
    local selection_idx = (i - 1) / 4 + 1
    local final_offset = final_offsets[selection_idx]
    if final_offset then
      local offsets = type(final_offset) == "table" and final_offset or { final_offset }
      for _, offset in ipairs(offsets) do
        local line, col = offset_to_position(new_lines, new_starts, new_total, offset)
        new_selections[#new_selections + 1] = line
        new_selections[#new_selections + 1] = col
        new_selections[#new_selections + 1] = line
        new_selections[#new_selections + 1] = col
      end
    else
      local l1, c1 = map_position(self.selections[i], self.selections[i + 1])
      local l2, c2 = map_position(self.selections[i + 2], self.selections[i + 3])
      new_selections[#new_selections + 1] = l1
      new_selections[#new_selections + 1] = c1
      new_selections[#new_selections + 1] = l2
      new_selections[#new_selections + 1] = c2
    end
  end
  return new_selections, last_selection or self.last_selection
end

function Doc:plan_edits(edits, opts)
  return plan_normalized_edits(self, edits, opts)
end

function Doc:selections_after_edits(edits, final_by_idx, last_selection, opts)
  opts = opts or {}
  local normalized = opts.normalized and edits or plan_normalized_edits(self, edits, opts)
  return final_selections_after_edits(self, normalized, final_by_idx, last_selection)
end


function Doc:text_input_by_selection(text_by_idx, idx, opts)
  opts = opts or {}
  local edits = {}
  local final_by_idx = {}
  for sidx, line1, col1, line2, col2 in self:get_selections(true, idx or true) do
    local text = type(text_by_idx) == "function" and text_by_idx(sidx, line1, col1, line2, col2) or text_by_idx[sidx]
    text = tostring(text or "")
    local edit_line1, edit_col1, edit_line2, edit_col2 = line1, col1, line2, col2

    if opts.overwrite ~= false
    and self.overwrite
    and (line1 == line2 and col1 == col2)
    and col1 < #self:get_utf8_line(line1)
    and text:ulen(nil, nil, true) == 1 then
      edit_line2, edit_col2 = translate.next_char(self, line1, col1)
    end

    edits[#edits + 1] = {
      line1 = edit_line1, col1 = edit_col1, line2 = edit_line2, col2 = edit_col2,
      text = text, idx = sidx,
    }
    final_by_idx[sidx] = "end"
  end
  if #edits == 0 then return end
  local normalized = self:plan_edits(edits, opts)
  local new_selections, new_last_selection = self:selections_after_edits(normalized, final_by_idx, self.last_selection, { normalized = true })
  return self:apply_edits(edits, {
    type = opts.type or "insert",
    selections = new_selections,
    last_selection = new_last_selection,
    merge_cursors = opts.merge_cursors or false,
  })
end

function Doc:text_input(text, idx)
  text = tostring(text or "")
  return self:text_input_by_selection(function() return text end, idx, { type = "insert" })
end


function Doc:ime_text_editing(text, start, length, idx)
  for sidx, line1, col1, line2, col2 in self:get_selections(true, idx or true) do
    if line1 ~= line2 or col1 ~= col2 then
      self:delete_to_cursor(sidx)
    end
    self:insert(line1, col1, text)
    self:set_selections(sidx, line1, col1 + #text, line1, col1)
  end
end


function Doc:replace_cursor(idx, line1, col1, line2, col2, fn)
  local old_text = self:get_text(line1, col1, line2, col2)
  local new_text, res = fn(old_text)
  if old_text ~= new_text then
    self:insert(line2, col2, new_text)
    self:remove(line1, col1, line2, col2)
    if line1 == line2 and col1 == col2 then
      line2, col2 = self:position_offset(line1, col1, #new_text)
      self:set_selections(idx, line1, col1, line2, col2)
    end
  end
  return res
end

function Doc:replace(fn)
  local has_selection, results, edits, final_by_idx = false, { }, {}, {}
  for idx, line1, col1, line2, col2 in self:get_selections(true) do
    if line1 ~= line2 or col1 ~= col2 then
      local old_text = self:get_text(line1, col1, line2, col2)
      local new_text, res = fn(old_text)
      results[idx] = res
      if old_text ~= new_text then
        edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = new_text, idx = idx }
        final_by_idx[idx] = "start"
      end
      has_selection = true
    end
  end
  if not has_selection then
    self:set_selection(table.unpack(self.selections))
    local line1, col1, line2, col2 = 1, 1, #self.lines, #self.lines[#self.lines]
    local old_text = self:get_text(line1, col1, line2, col2)
    local new_text, res = fn(old_text)
    results[1] = res
    if old_text ~= new_text then
      edits[#edits + 1] = { line1 = line1, col1 = col1, line2 = line2, col2 = col2, text = new_text, idx = 1 }
    end
  end
  if #edits > 0 then
    local normalized = self:plan_edits(edits)
    local selections, last_selection
    if next(final_by_idx) then
      selections, last_selection = self:selections_after_edits(normalized, final_by_idx, self.last_selection, { normalized = true })
    end
    self:apply_edits(edits, {
      type = "replace",
      selections = selections,
      last_selection = last_selection,
      merge_cursors = false,
    })
  end
  return results
end


function Doc:delete_to_cursor(idx, ...)
  local edits = {}
  local final_by_idx = {}
  local final_positions = {}
  for sidx, line1, col1, line2, col2 in self:get_selections(true, idx) do
    local start_line, start_col, end_line, end_col = line1, col1, line2, col2
    if line1 == line2 and col1 == col2 then
      local l2, c2 = self:position_offset(line1, col1, ...)
      start_line, start_col, end_line, end_col = sort_positions(line1, col1, l2, c2)
    end
    edits[#edits + 1] = {
      line1 = start_line, col1 = start_col, line2 = end_line, col2 = end_col,
      text = "", idx = sidx,
    }
    final_by_idx[sidx] = "start"
    final_positions[sidx] = { start_line, start_col }
  end
  if #edits == 0 then return end
  local normalized = self:plan_edits(edits)
  local changed_edits = {}
  local changed_final_by_idx = {}
  for _, edit in ipairs(normalized) do
    if edit.start_offset ~= edit.end_offset then
      changed_edits[#changed_edits + 1] = edit
      changed_final_by_idx[edit.idx] = "start"
    end
  end
  local new_selections
  if #changed_edits > 0 then
    new_selections = self:selections_after_edits(changed_edits, changed_final_by_idx, self.last_selection, { normalized = true })
  else
    new_selections = copy_array(self.selections)
    for sidx, pos in pairs(final_positions) do
      local i = (sidx - 1) * 4 + 1
      new_selections[i], new_selections[i + 1], new_selections[i + 2], new_selections[i + 3] = pos[1], pos[2], pos[1], pos[2]
    end
  end
  local tx = self:apply_edits(edits, {
    type = "remove",
    selections = new_selections,
    last_selection = self.last_selection,
    merge_cursors = true,
  })
  if not (tx and tx.changed) then
    self.selections = new_selections
    self:merge_cursors(idx)
  end
  return tx
end
function Doc:delete_to(...) return self:delete_to_cursor(nil, ...) end

function Doc:move_to_cursor(idx, ...)
  for sidx, line, col in self:get_selections(false, idx) do
    self:set_selections(sidx, self:position_offset(line, col, ...))
  end
  self:merge_cursors(idx)
end
function Doc:move_to(...) return self:move_to_cursor(nil, ...) end


function Doc:select_to_cursor(idx, ...)
  for sidx, line, col, line2, col2 in self:get_selections(false, idx) do
    line, col = self:position_offset(line, col, ...)
    self:set_selections(sidx, line, col, line2, col2)
  end
  self:merge_cursors(idx)
end
function Doc:select_to(...) return self:select_to_cursor(nil, ...) end


function Doc:get_indent_string(col)
  local indent_type, indent_size = self:get_indent_info()
  if indent_type == "hard" then
    return "\t", "\t"
  end
  return string.rep(" ", indent_size),
    string.rep(" ", indent_size - ((col-1) % indent_size))
end

-- returns the size of the original indent, and the indent
-- in your config format, rounded either up or down
function Doc:get_line_indent(line, rnd_up)
  local _, e = line:find("^[ \t]+")
  local indent_type, indent_size = self:get_indent_info()
  local soft_tab = string.rep(" ", indent_size)
  if indent_type == "hard" then
    local indent = e and line:sub(1, e):gsub(soft_tab, "\t") or ""
    return e, indent:gsub(" +", rnd_up and "\t" or "")
  else
    local indent = e and line:sub(1, e):gsub("\t", soft_tab) or ""
    local number = #indent / #soft_tab
    return e, indent:sub(1,
      (rnd_up and math.ceil(number) or math.floor(number))*#soft_tab)
  end
end

-- un/indents text; behaviour varies based on selection and un/indent.
-- * if there's a selection, it will stay static around the
--   text for both indenting and unindenting.
-- * if you are in the beginning whitespace of a line, and are indenting, the
--   cursor will insert the exactly appropriate amount of spaces, and jump the
--   cursor to the beginning of first non whitespace characters
-- * if you are not in the beginning whitespace of a line, and you indent, it
--   inserts the appropriate whitespace, as if you typed them normally.
-- * if you are unindenting, the cursor will jump to the start of the line,
--   and remove the appropriate amount of spaces (or a tab).
function Doc:indent_text(unindent, line1, col1, line2, col2)
  local _, se = self.lines[line1]:find("^[ \t]+")
  local text, text_stop = self:get_indent_string(
    unindent and (se and se + 1 or 1) or col1
  )
  local in_beginning_whitespace = col1 == 1 or (se and col1 <= se + 1)
  local has_selection = line1 ~= line2 or col1 ~= col2
  if unindent or has_selection or in_beginning_whitespace then
    local line1_delta, line2_delta = 0, 0
    local edits = {}
    for line = line1, line2 do
      if not has_selection or #self.lines[line] > 1 then -- don't indent empty lines in a selection
        local e, rnded = self:get_line_indent(self.lines[line], unindent)
        local removed = e or 0
        local replacement = unindent and rnded:sub(
          1, #rnded - (#text - (#text == #text_stop and 0 or #text_stop))
        ) or rnded .. text
        edits[#edits + 1] = {
          line1 = line,
          col1 = 1,
          line2 = line,
          col2 = removed + 1,
          text = replacement,
        }
        local delta = #replacement - removed
        if line == line1 then line1_delta = delta end
        if line == line2 then line2_delta = delta end
      end
    end
    if #edits > 0 then
      self:apply_edits(edits, {
        type = unindent and "remove" or "insert",
        merge_cursors = false,
      })
    end
    if (unindent or in_beginning_whitespace) and not has_selection then
      local start_cursor = (se and se + 1 or 1) + line1_delta or #(self.lines[line1])
      return line1, start_cursor, line2, start_cursor
    end
    return line1, col1 + line1_delta, line2, col2 + line2_delta
  end
  self:insert(line1, col1, text_stop)
  return line1, col1 + #text_stop, line1, col1 + #text_stop
end

-- Internal transaction hook for batch-aware document change observers.
function Doc:on_text_transaction(transaction)
end

-- For plugins to add custom actions of document change
function Doc:on_text_change(type, transaction)
end

-- For plugins to get notified when a document is closed
function Doc:on_close()
  -- this shouldn't be needed but we do it to better hint the gc to collect
  self.highlighter.doc = nil
  self.highlighter.lines = nil

  core.log_quiet("Closed doc \"%s\"", self:get_name())
end

---Get the lua pattern used to match symbols taking into account current subsyntax.
---@return string
function Doc:get_symbol_pattern()
  local line = self:get_selection(true)
  local current_syntax = self.syntax
  if current_syntax and line > 1 then
    local state = self.highlighter:get_line(line - 1).state
    if state then
      local syntaxes = tokenizer.extract_subsyntaxes(current_syntax, state)
      for _, s in pairs(syntaxes) do
        if s.symbol_pattern then
          current_syntax = s
          break
        end
      end
    end
  end
  return (current_syntax and current_syntax.symbol_pattern)
    and current_syntax.symbol_pattern or config.symbol_pattern
end

---Get a string of characters not belonging to a word taking into account
---current subsyntax.
---
---Note: when setting `symbol` param to true the characters property
---`symbol_non_word_chars` will be searched, if false `non_word_chars`. In both
---cases will fallback to `config.non_word_chars` when not found.
---@param symbol boolean Indicates if non word characters are for a symbol
---@return string
function Doc:get_non_word_chars(symbol)
  local non_word_chars = symbol and "symbol_non_word_chars" or "non_word_chars"
  local line = self:get_selection(true)
  local current_syntax = self.syntax
  if current_syntax and line > 1 then
    local state = self.highlighter:get_line(line - 1).state
    if state then
      local syntaxes = tokenizer.extract_subsyntaxes(current_syntax, state)
      for _, s in pairs(syntaxes) do
        if s[non_word_chars] then
          current_syntax = s
          break
        end
      end
    end
  end
  return (current_syntax and current_syntax[non_word_chars])
    and current_syntax[non_word_chars] or config.non_word_chars
end


function Doc:add_search_selection(line1, col1, line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  local idx = string.format("%d:%d-%d:%d", line1, col1, line2, col2)
  self.search_selections[idx] = true
end

function Doc:is_search_selection(line1, col1, line2, col2)
  line1, col1, line2, col2 = sort_positions(line1, col1, line2, col2)
  local idx = string.format("%d:%d-%d:%d", line1, col1, line2, col2)
  if self.search_selections[idx] then return true end
  return false
end

function Doc:clear_search_selections()
  self.search_selections = {}
end


return Doc
