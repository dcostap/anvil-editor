local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local test = require "core.test"
local symbol_index = require "core.treesitter.symbol_index"
local treesitter = require "core.treesitter"
local autocomplete = require "plugins.autocomplete"

local function track(context, kind, value)
  context[kind] = context[kind] or {}
  table.insert(context[kind], value)
  return value
end

local function remove_doc(doc)
  for i = #core.docs, 1, -1 do
    if core.docs[i] == doc then
      table.remove(core.docs, i)
      doc:on_close()
      return
    end
  end
end

local function open_editor(context, text)
  local doc = track(context, "docs", core.open_doc())
  if text and text ~= "" then doc:text_input(text) end
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  return view, doc
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "")
  fp:close()
end

local function open_file_editor(context, path)
  local doc = track(context, "docs", core.open_doc(path))
  doc:set_selection(#doc.lines, #(doc.lines[#doc.lines] or ""))
  local view = track(context, "views", core.root_panel:open_doc(doc))
  core.set_active_view(view)
  return view, doc
end

local function wait_treesitter_ready(doc, timeout)
  local deadline = system.get_time() + (timeout or 3)
  while system.get_time() < deadline do
    treesitter.poll_doc(doc)
    if doc.treesitter and doc.treesitter.status == "ready" then return true end
    coroutine.yield(0.01)
  end
  return false
end

local function seed_odin_project_symbol(context, active_relative_path)
  symbol_index.reset_for_tests()
  context.reset_symbol_index = true
  context.autocomplete_scope = context.autocomplete_scope or config.plugins.autocomplete.suggestions_scope
  config.plugins.autocomplete.suggestions_scope = "none"
  local suffix = tostring(system.get_process_id()) .. "-" .. tostring(math.floor(system.get_time() * 1000000))
  local root = core.root_project().path
  local fixture_root = root .. PATHSEP .. ".autocomplete-odin-project-" .. suffix
  common.mkdirp(fixture_root)
  context.temp_roots = context.temp_roots or {}
  context.temp_roots[#context.temp_roots + 1] = fixture_root

  local source_path = common.normalize_path(fixture_root .. PATHSEP .. "types.odin")
  write_file(source_path, "package demo\nRoute_Message_Type :: enum c.uchar { RESOLVE = 0xb }\n")
  local index = symbol_index.status(root)
  index.status = "ready"
  index.symbol_status = "ready"
  index.usage_status = "ready"
  -- Keep this focused UI fixture synchronous; filesystem watcher behavior is
  -- covered by the Tree-sitter runtime suite.
  index.watch_running = true
  index.finished_at = system.get_time()
  index.symbols = {
    {
      name = "RESOLVE",
      text = "RESOLVE",
      kind = "enum_member",
      parent_name = "Route_Message_Type",
      signature = "0xb",
      language_id = "odin",
      path = source_path,
      file = "types.odin",
      relpath = "types.odin",
      start_line = 2,
      start_col = 42,
      end_line = 2,
      end_col = 49,
      name_range = {
        start = { line = 2, col = 42 },
        ["end"] = { line = 2, col = 49 },
      },
    },
  }

  local active_path = common.normalize_path(fixture_root .. PATHSEP .. active_relative_path)
  write_file(active_path, "reso")
  return root, active_path
end

local function set_view_selections(view, selections)
  view:with_selection_state(function()
    view.doc:set_selection(selections[1], selections[2], selections[3], selections[4])
    for i = 5, #selections, 4 do
      view.doc:set_selections((i - 1) / 4 + 1, selections[i], selections[i + 1], selections[i + 2], selections[i + 3], nil, 0)
    end
  end)
end

local function view_selections(view)
  return view:with_selection_state(function()
    local selections = {}
    for i = 1, #view.doc.selections do selections[i] = view.doc.selections[i] end
    return selections
  end)
end

test.describe("autocomplete batch behavior", function()
  test.after_each(function(context)
    autocomplete.close()
    if context.autocomplete_max_symbol_length then
      config.plugins.autocomplete.max_symbol_length = context.autocomplete_max_symbol_length
    end
    if context.autocomplete_scope then
      config.plugins.autocomplete.suggestions_scope = context.autocomplete_scope
    end
    local root = core.root_panel.root_node
    for _, view in ipairs(context.views or {}) do
      local node = root:get_node_for_view(view)
      if node then node:remove_view(root, view) end
    end
    for _, doc in ipairs(context.docs or {}) do
      if doc:is_dirty() then doc:clean() end
      remove_doc(doc)
    end
    if context.reset_symbol_index then symbol_index.reset_for_tests() end
    for _, root_path in ipairs(context.temp_roots or {}) do common.rm(root_path, true) end
    for _, path in ipairs(context.temp_files or {}) do os.remove(path) end
  end)

  test.it("typing over many overlapping selected ranges should not be rejected into autocomplete-only state", function(context)
    local line = string.rep("alpha", 20)
    local selections = {}
    for i = 1, 20 do
      local start_col = (i - 1) * 2 + 1
      selections[#selections + 1] = 1
      selections[#selections + 1] = start_col + 5
      selections[#selections + 1] = 1
      selections[#selections + 1] = start_col
    end
    local view, doc = open_editor(context, line)
    set_view_selections(view, selections)
    autocomplete.add({
      name = "test-overlap-autocomplete-regression",
      files = ".*",
      items = { alphabet = "" },
    })

    core.root_panel:on_text_input("z")

    test.ok(
      table.concat(doc.lines) ~= line .. "\n" and not autocomplete.is_open(),
      "typing should modify the document instead of leaving the autocomplete popup open"
    )
  end)

  test.it("keeps the popup open while deleting letters from the active word", function(context)
    local view, doc = open_editor(context, "")
    autocomplete.add({
      name = "test-autocomplete-delete-refresh",
      files = ".*",
      items = { foobar = "", foobaz = "" },
    })

    core.root_panel:on_text_input("foobar")
    test.ok(autocomplete.is_open(), "expected autocomplete to open while typing")

    test.ok(command.perform("doc:backspace"))
    core.root_panel:update()

    test.equal(table.concat(doc.lines), "fooba\n")
    test.ok(autocomplete.is_open(), "expected autocomplete to stay open after deleting a letter")
    test.ok(command.perform("autocomplete:next"))
    test.equal(autocomplete.get_selected_suggestion().text, "foobaz")

    for _ = 1, 3 do
      test.ok(command.perform("doc:backspace"))
      core.root_panel:update()
    end
    test.equal(table.concat(doc.lines), "fo\n")
    test.ok(autocomplete.is_open(), "expected autocomplete to stay open below the normal minimum length")
  end)

  test.it("ignores oversized suggestions before matching", function(context)
    context.autocomplete_max_symbol_length = config.plugins.autocomplete.max_symbol_length
    config.plugins.autocomplete.max_symbol_length = 40
    open_editor(context, "aaa")
    autocomplete.complete({
      name = "test-autocomplete-long-symbol-filter",
      files = ".*",
      items = { [string.rep("a", 41)] = "" },
    })

    test.ok(not autocomplete.is_open(), "expected oversized suggestion to be ignored")
  end)

  test.it("completes matching partials at multiple carets in one document change", function(context)
    local view, doc = open_editor(context, "fo\nfo")
    set_view_selections(view, {
      1, 3, 1, 3,
      2, 3, 2, 3,
    })
    local changes = 0
    function doc:on_text_change()
      changes = changes + 1
    end

    autocomplete.complete({
      name = "test-autocomplete-batch",
      files = ".*",
      items = { foobar = "" },
    })
    test.ok(command.perform("autocomplete:complete"))

    test.equal(table.concat(doc.lines), "foobar\nfoobar\n")
    test.equal(changes, 1)
    test.same(view_selections(view), {
      1, 7, 1, 7,
      2, 7, 2, 7,
    })
  end)

  test.it("scores code-symbol chunk fuzzy fallback and cuts off weak matches", function()
    local query, chunks = autocomplete._test.code_symbol_chunk_query("text_dra")
    test.equal(query, "text dra")
    local draw_text = autocomplete._test.code_symbol_chunk_match_score("draw_text", chunks)
    local context_draw = autocomplete._test.code_symbol_chunk_match_score("context_draw", chunks)
    test.ok(draw_text)
    test.ok(context_draw)
    test.ok(draw_text > context_draw)
    test.is_nil(autocomplete._test.code_symbol_chunk_match_score("D3D11_CREATE_2D_TEXTURE_FAILED", chunks))
    test.is_nil(autocomplete._test.code_symbol_chunk_match_score("_sg_d3d11_CreateTexture2D", chunks))
  end)

  test.it("does not offer loaded Project symbols in an external unsupported-language file", function(context)
    seed_odin_project_symbol(context, "current.odin")
    local seeded, reason, status = symbol_index.workspace_symbols("reso", {
      kind = "autocomplete", limit = 10, allow_stale = true,
    })
    test.ok(status == "fresh" or status == "stale", reason)
    test.equal(#(seeded or {}), 1)
    test.equal(seeded[1].name, "RESOLVE")
    local external = USERDIR .. PATHSEP .. "autocomplete-external-" .. tostring(system.get_process_id()) .. ".js"
    write_file(external, "reso")
    context.temp_files = context.temp_files or {}
    context.temp_files[#context.temp_files + 1] = external
    open_file_editor(context, external)

    autocomplete.trigger()

    test.ok(not autocomplete.is_open(), "external JavaScript should not receive Odin Project symbols")
  end)

  test.it("does not offer Project symbols from an incompatible language", function(context)
    local _, active_path = seed_odin_project_symbol(context, "current.kt")
    open_file_editor(context, active_path)

    autocomplete.trigger()

    test.ok(not autocomplete.is_open(), "Kotlin should not receive Odin Project symbols")
  end)

  test.it("accepts contextual enum-member Project suggestions with their enum prefix", function(context)
    local _, active_path = seed_odin_project_symbol(context, "current.odin")
    local _, doc = open_file_editor(context, active_path)

    autocomplete.trigger()

    test.ok(autocomplete.is_open())
    local item = test.not_nil(autocomplete.get_selected_suggestion())
    test.equal(item.preview_text, "Route_Message_Type.RESOLVE = 0xb")
    test.same(item.preview_name_span, { 20, 26 })
    test.equal(item.info, "enum member")
    test.equal(item.preview_show_info, true)
    test.equal(item.icon, "enum_member")
    test.ok(not item.no_icon, "expected the code-symbol suggestion to show its kind icon")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "Route_Message_Type.RESOLVE\n")
  end)

  test.it("does not duplicate an enum prefix already present at the caret", function(context)
    local _, active_path = seed_odin_project_symbol(context, "current.odin")
    write_file(active_path, "Route_Message_Type.reso")
    local _, doc = open_file_editor(context, active_path)

    autocomplete.trigger()

    test.ok(autocomplete.is_open())
    test.equal(test.not_nil(autocomplete.get_selected_suggestion()).text, "RESOLVE")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "Route_Message_Type.RESOLVE\n")
  end)

  test.it("opens after a container dot and prioritizes that container's members", function(context)
    local root, active_path = seed_odin_project_symbol(context, "current.odin")
    local index = symbol_index.status(root)
    index.symbols[#index.symbols + 1] = common.merge({}, index.symbols[1], {
      parent_name = "Other_Message_Type",
      path = common.normalize_path(root .. PATHSEP .. "other.odin"),
      file = "other.odin",
      relpath = "other.odin",
    })
    write_file(active_path, "Route_Message_Type")
    local _, doc = open_file_editor(context, active_path)

    core.root_panel:on_text_input(".")

    test.ok(autocomplete.is_open(), "expected member completion to open immediately after the dot")
    core.root_panel:on_text_input("R")
    test.ok(autocomplete.is_open(), "expected member completion to remain open below the normal minimum length")
    local item = test.not_nil(autocomplete.get_selected_suggestion())
    test.equal(item.text, "RESOLVE")
    test.equal(item.preview_context, "Route_Message_Type")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "Route_Message_Type.RESOLVE\n")
  end)

  test.it("uses the same container context for non-enum members", function(context)
    local root, active_path = seed_odin_project_symbol(context, "current.odin")
    local symbol = symbol_index.status(root).symbols[1]
    symbol.name = "count"
    symbol.text = "count"
    symbol.kind = "field"
    symbol.parent_name = "Point"
    symbol.signature = "int"
    write_file(active_path, "Point")
    local _, doc = open_file_editor(context, active_path)

    core.root_panel:on_text_input(".")

    test.ok(autocomplete.is_open())
    local item = test.not_nil(autocomplete.get_selected_suggestion())
    test.equal(item.text, "count")
    test.equal(item.preview_context, "Point")
    test.equal(item.icon, "field")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "Point.count\n")
  end)

  test.it("uses freshly parsed members from the current Document", function(context)
    local _, active_path = seed_odin_project_symbol(context, "current.odin")
    write_file(active_path, "Point :: struct { count: int }\nPoint.")
    local _, doc = open_file_editor(context, active_path)
    test.ok(wait_treesitter_ready(doc), "expected current Document Tree-sitter data")

    autocomplete.trigger()

    test.ok(autocomplete.is_open())
    local item = test.not_nil(autocomplete.get_selected_suggestion())
    test.equal(item.text, "count")
    test.equal(item.preview_context, "Point")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "Point :: struct { count: int }\nPoint.count\n")
  end)

  test.it("does not force generic suggestions after an unresolved receiver dot", function(context)
    local _, active_path = seed_odin_project_symbol(context, "current.odin")
    write_file(active_path, "instance")
    open_file_editor(context, active_path)

    core.root_panel:on_text_input(".")

    test.ok(not autocomplete.is_open(), "an unresolved instance receiver should not force generic suggestions")
  end)

  test.it("uses the active language's configured member separator", function(context)
    local root, active_path = seed_odin_project_symbol(context, "current.cpp")
    local symbol = symbol_index.status(root).symbols[1]
    symbol.name = "reset"
    symbol.text = "reset"
    symbol.kind = "method"
    symbol.parent_name = "MenuGui"
    symbol.signature = "()"
    symbol.language_id = "cpp"
    write_file(active_path, "MenuGui")
    local _, doc = open_file_editor(context, active_path)

    core.root_panel:on_text_input("::")

    test.ok(autocomplete.is_open())
    test.equal(test.not_nil(autocomplete.get_selected_suggestion()).text, "reset")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "MenuGui::reset\n")
  end)

  test.it("does not add an invalid qualifier to unscoped C enum members", function(context)
    local root, active_path = seed_odin_project_symbol(context, "current.c")
    local symbol = symbol_index.status(root).symbols[1]
    symbol.name = "RED"
    symbol.text = "RED"
    symbol.parent_name = "Color"
    symbol.language_id = "c"
    write_file(active_path, "RE")
    local _, doc = open_file_editor(context, active_path)

    autocomplete.trigger()

    test.ok(autocomplete.is_open())
    test.equal(test.not_nil(autocomplete.get_selected_suggestion()).text, "RED")
    test.ok(command.perform("autocomplete:complete"))
    test.equal(table.concat(doc.lines), "RED\n")
  end)
end)
