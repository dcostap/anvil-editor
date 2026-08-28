local core = require "core"
local common = require "core.common"
local Project = require "core.project"
local project_paths = require "core.project_paths"
local test = require "core.test"

local fuzzy_searcher = require "plugins.fuzzy_searcher"
local helpers = fuzzy_searcher._test

local function join_path(...)
  return table.concat({...}, PATHSEP)
end

local function mkdirp(path)
  local ok, err = common.mkdirp(path)
  test.ok(ok, err)
end

local function write_file(path, text)
  local fp = assert(io.open(path, "wb"))
  fp:write(text or "test\n")
  fp:close()
end

local function wait_until(predicate, timeout)
  local deadline = system.get_time() + (timeout or 5)
  while not predicate() and system.get_time() < deadline do coroutine.yield(0.02) end
  return predicate()
end

local function picker_result_for_path(picker, path)
  for _, result in ipairs(picker.results or {}) do
    if result.abs_path and common.path_equals(result.abs_path, path) then return result end
  end
end

test.describe("Fuzzy Searcher Project Path Roles", function()
  test.before_each(function(context)
    context.original_projects = core.projects
    context.original_visited_files = core.visited_files
    context.original_cwd = system.getcwd()
    context.temp_root = USERDIR
      .. PATHSEP .. "fuzzy-project-paths-tests-"
      .. system.get_process_id() .. "-"
      .. math.floor(system.get_time() * 1000000)
    context.root = join_path(context.temp_root, "app")
    context.external = join_path(context.temp_root, "jdk-src")
    mkdirp(join_path(context.root, "src", "vendor", "library1", "foo"))
    mkdirp(join_path(context.external, "java", "lang"))
    core.projects = { Project(context.root) }
    core.visited_files = {}
    system.chdir(context.root)
    project_paths.configure_workspace {
      external = {
        { path = "../jdk-src", label = "Java Sources" },
      },
      vendored = {
        { path = "src/vendor/library1", label = "library1" },
      },
    }
  end)

  test.after_each(function(context)
    if core.fuzzy_searcher_active_view then core.fuzzy_searcher_active_view:close() end
    project_paths.configure_workspace {}
    project_paths.load_workspace_state(nil)
    core.projects = context.original_projects
    core.visited_files = context.original_visited_files
    if context.original_cwd then pcall(system.chdir, context.original_cwd) end
    if context.temp_root and system.get_file_info(context.temp_root) then
      local ok, err = common.rm(context.temp_root, true)
      test.ok(ok, err)
    end
  end)

  test.it("renders external and vendored files with role labels and keeps absolute activation paths", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file)
    write_file(vendored_file)

    local external_item = helpers.file_display_item(external_file)
    local vendored_item = helpers.file_display_item(vendored_file)
    local rows = helpers.file_search_rows("String", { external_item, vendored_item }, nil, 20)
    local external_row = rows[1]

    test.equal(external_row.file, "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(external_row.root_label, "Java Sources")
    test.equal(external_row.root_role, "external")
    test.same(external_row.prefix_span, { 1, #"Java Sources" })
    test.ok(common.path_equals(helpers.fullpath(external_row), external_file))

    rows = helpers.file_search_rows("Baz", { external_item, vendored_item }, nil, 20)
    local vendored_row = rows[1]
    test.equal(vendored_row.file, "library1" .. PATHSEP .. "foo" .. PATHSEP .. "Baz.java")
    test.equal(vendored_row.root_role, "vendored")
    test.same(vendored_row.prefix_span, { 1, #"library1" })
    test.ok(common.path_equals(helpers.fullpath(vendored_row), vendored_file))
  end)

  test.it("disambiguates identical display paths without losing activation paths", function(context)
    local root_collision = join_path(context.root, "jdk-src", "Foo.java")
    mkdirp(join_path(context.root, "jdk-src"))
    local external_collision = join_path(context.external, "Foo.java")
    write_file(root_collision)
    write_file(external_collision)

    local root_item = helpers.file_display_item(root_collision)
    local external_item = helpers.file_display_item(external_collision)

    test.not_equal(root_item, external_item)
    test.ok(common.path_equals(helpers.fullpath(root_item), root_collision))
    test.ok(common.path_equals(helpers.fullpath(external_item), external_collision))
  end)

  test.it("prefers Root Project files over matching External Project Directory files", function(context)
    local root_file = join_path(context.root, "String.java")
    local external_file = join_path(context.external, "String.java")
    write_file(root_file)
    write_file(external_file)

    local root_item = helpers.file_display_item(root_file)
    local external_item = helpers.file_display_item(external_file)
    local rows = helpers.file_search_rows("String", { external_item, root_item }, nil, 20)

    test.ok(common.path_equals(helpers.fullpath(rows[1]), root_file), "expected Root Project file to rank first")
    test.ok(common.path_equals(helpers.fullpath(rows[2]), external_file), "expected External Project Directory file to remain visible")
  end)

  test.it("builds grep scope and display metadata from activation paths, not role labels", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "Baz.java")
    write_file(external_file, "NEEDLE\n")
    write_file(vendored_file, "NEEDLE\n")
    local external_item = helpers.file_display_item(external_file)
    local vendored_item = helpers.file_display_item(vendored_file)
    helpers.set_file_cache_for_test({ external_item, vendored_item })

    local scope = helpers.build_scope("String", nil, 20)
    test.ok(common.path_equals(scope[1], external_file), "expected grep scope to use external absolute path")

    local result = helpers.decorate_grep_result({ file = "java/lang/String.java", line = 1, col = 1, text = "NEEDLE" }, context.external)
    test.equal(result.file, external_item)
    test.same(result.prefix_span, { 1, #"Java Sources" })
    test.ok(common.path_equals(result.abs_path, external_file))

    result = helpers.decorate_grep_result({ file = common.relative_path(context.root, vendored_file), line = 1, col = 1, text = "NEEDLE" }, context.root)
    test.equal(result.file, vendored_item)
    test.ok(common.path_equals(result.abs_path, vendored_file))
  end)

  test.it("preserves Project Path roles through native filesystem ingestion", function(context)
    local external_file = join_path(context.external, "java", "lang", "NativeString.java")
    local vendored_file = join_path(context.root, "src", "vendor", "library1", "foo", "NativeBaz.java")
    write_file(external_file)
    write_file(vendored_file)

    fuzzy_searcher.open("NativeString")
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_result_for_path(picker, external_file) end),
      "expected the native index to publish the External Project Directory file")
    local external = picker_result_for_path(picker, external_file)
    test.equal(external.file, "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "NativeString.java")
    test.equal(external.root_role, "external")
    test.equal(helpers.file_index_status().native, true)

    picker.input:set_text("NativeBaz")
    test.ok(wait_until(function() return picker_result_for_path(picker, vendored_file) end),
      "expected the native index to retain the Vendored Project Directory mapping")
    local vendored = picker_result_for_path(picker, vendored_file)
    test.equal(vendored.file, "library1" .. PATHSEP .. "foo" .. PATHSEP .. "NativeBaz.java")
    test.equal(vendored.root_role, "vendored")
  end)

  test.it("ranks literal and compact path-scope matches ahead of loose subsequence paths", function(context)
    local fmt_file = join_path(context.root, "fmt", "doc.odin")
    local fmt_impl = join_path(context.root, "fmt", "fmt.odin")
    local compact = join_path(context.root, "odin", "doc-format", "doc_format.odin")
    local loose = join_path(context.root, "sys", "darwin", "Foundation", "NSEnumerator.odin")
    mkdirp(join_path(context.root, "fmt"))
    mkdirp(join_path(context.root, "odin", "doc-format"))
    mkdirp(join_path(context.root, "sys", "darwin", "Foundation"))
    local fmt_file_display = helpers.file_display_item(fmt_file)
    local fmt_impl_display = helpers.file_display_item(fmt_impl)
    local compact_display = helpers.file_display_item(compact)
    local loose_display = helpers.file_display_item(loose)
    helpers.set_file_cache_for_test({ fmt_file_display, fmt_impl_display, compact_display, loose_display })
    local scope, scope_meta = helpers.build_scope("fmt", nil, 4)
    test.equal(#scope, 4, "expected literal, compact, and loose fuzzy paths in scope")
    local function result(path, display, line, content_score)
      local path_info = scope_meta.by_path[common.path_compare_key(path)]
      test.not_nil(path_info, "expected scope ranking metadata for " .. display)
      return {
        kind = "grep",
        file = display,
        abs_path = path,
        line = line,
        fuzzy_score = content_score,
        path_match_class = path_info.match_class,
        path_score = path_info.score,
      }
    end
    local results = helpers.order_grep_results({
      result(fmt_file, fmt_file_display, 1, 11484),
      result(fmt_file, fmt_file_display, 2, 11177),
      result(fmt_impl, fmt_impl_display, 1, 11477),
      result(fmt_impl, fmt_impl_display, 2, 10800),
      result(compact, compact_display, 1, 10000),
      result(loose, loose_display, 1, 11476),
    })

    local loose_index
    for i, result in ipairs(results) do
      if common.path_equals(result.abs_path, loose) then loose_index = i end
    end
    test.not_nil(loose_index, "expected the loose F-m-t path to remain searchable")
    for i, result in ipairs(results) do
      if common.path_equals(result.abs_path, fmt_file)
      or common.path_equals(result.abs_path, fmt_impl)
      or common.path_equals(result.abs_path, compact) then
        test.ok(
          i < loose_index,
          string.format(
            "expected literal and compact fmt paths ahead of the loose path match: path=%s class=%s loose_index=%s index=%s",
            tostring(result.abs_path), tostring(result.path_match_class), tostring(loose_index), tostring(i)
          )
        )
      end
    end
  end)

  test.it("reports when a path scope omits additional matching files", function(context)
    local first = join_path(context.root, "fmt", "first.odin")
    local second = join_path(context.root, "fmt", "second.odin")
    mkdirp(join_path(context.root, "fmt"))
    helpers.set_file_cache_for_test({
      helpers.file_display_item(first),
      helpers.file_display_item(second),
    })

    local scope, meta = helpers.build_scope("fmt", nil, 1)

    test.equal(#scope, 1)
    test.equal(meta.count, 1)
    test.equal(meta.limit, 1)
    test.equal(meta.has_more, true)
  end)

  test.it("searches fuzzy path matches beyond the first scope batch", function(context)
    local headers = join_path(context.root, "headers")
    mkdirp(headers)
    local files = {}
    for i = 1, 405 do
      local path = join_path(headers, string.format("header_%03d.h", i))
      write_file(path, "ordinary text\n")
      files[#files+1] = helpers.file_display_item(path)
    end
    helpers.set_file_cache_for_test(files)

    local complete_scope = helpers.build_scope(".h", nil, #files)
    test.equal(#complete_scope, #files)
    local target = complete_scope[#complete_scope]
    write_file(target, "GENERAL SCOPE NEEDLE\n")

    local first_scope, first_meta = helpers.build_scope(".h", nil, 400)
    test.equal(#first_scope, 400)
    test.equal(first_meta.has_more, true)
    for _, path in ipairs(first_scope) do
      test.not_ok(common.path_equals(path, target), "expected target after the first scope batch")
    end

    fuzzy_searcher.open('.h #"GENERAL SCOPE NEEDLE"')
    local picker = assert(core.fuzzy_searcher_active_view)
    test.ok(wait_until(function() return picker_result_for_path(picker, target) end, 15),
      "expected exact grep to continue through all fuzzy path matches: " .. tostring(picker.status))
    test.ok(wait_until(function() return picker.status == "1 exact matches" end, 15),
      "expected exact grep to finish every path batch: " .. tostring(picker.status))

    picker.input:set_text(".h #GENERAL SCOPE")
    test.ok(wait_until(function()
      local result = picker_result_for_path(picker, target)
      return result and result.exact == false
    end, 15), "expected fuzzy grep to continue through all fuzzy path matches: " .. tostring(picker.status))
  end)

  test.it("restarts an unchanged scoped grep when the file scope finishes changing", function()
    fuzzy_searcher.open("fmt#")
    local picker = core.fuzzy_searcher_active_view
    local calls = 0
    picker.start_grep = function(_, base, _, grep)
      calls = calls + 1
      test.equal(base, "fmt")
      test.equal(grep, "enum")
    end

    picker.dirty = true
    picker:refresh("fmt#enum")
    test.equal(calls, 1)

    helpers.set_file_cache_for_test({})
    picker.dirty = true
    picker:refresh("fmt#enum")

    test.equal(calls, 2, "expected the completed file scope to restart the unchanged grep")
  end)

  test.it("keeps related same-file grep results coherent beyond nearby score neighbors", function(context)
    local anchor = join_path(context.root, "fmt", "fmt.odin")
    local results = {
      { abs_path = anchor, file = "fmt/fmt.odin", line = 1, fuzzy_score = 1000,
        path_match_class = helpers.grep_path_match_class("fmt", "fmt/fmt.odin") },
      { abs_path = anchor, file = "fmt/fmt.odin", line = 2, fuzzy_score = 900,
        path_match_class = helpers.grep_path_match_class("fmt", "fmt/fmt.odin") },
    }
    for i = 1, 10 do
      results[#results+1] = {
        abs_path = join_path(context.root, "fmt", "other" .. i .. ".odin"),
        file = "fmt/other" .. i .. ".odin",
        line = 1,
        fuzzy_score = 1000 - i,
        path_match_class = helpers.grep_path_match_class("fmt", "fmt/other" .. i .. ".odin"),
      }
    end

    results = helpers.order_grep_results(results)

    test.ok(common.path_equals(results[1].abs_path, anchor))
    test.ok(common.path_equals(results[2].abs_path, anchor),
      "expected a related result to stay with its file instead of depending on an eight-row window")
  end)

  test.it("retains the best grep candidates rather than the first streamed candidates", function()
    local retained = {}
    for score = 1, 10 do
      helpers.retain_top_grep_result(retained, {
        file = "file" .. score .. ".odin",
        line = 1,
        fuzzy_score = score,
        path_match_class = helpers.grep_path_match_class("fmt", "fmt/file" .. score .. ".odin"),
      }, 3)
    end

    retained = helpers.order_grep_results(retained)

    test.same({ retained[1].fuzzy_score, retained[2].fuzzy_score, retained[3].fuzzy_score }, { 10, 9, 8 })
  end)

  test.it("uses Project Path labels in symbol results", function(context)
    local external_file = join_path(context.external, "java", "lang", "String.java")
    write_file(external_file)
    local display = project_paths.display_path(external_file, { kind = "symbols" })

    local row = helpers.symbol_result_from_item({
      name = "String",
      path = external_file,
      file = display.text,
      display_file = display.text,
      root_label = display.root_label,
      root_role = display.root_role,
      root_id = display.root_id,
      prefix_span = display.prefix_span,
      line = 1,
      col = 1,
    }, "String", { scope = "project" })

    test.equal(row.file, "Java Sources" .. PATHSEP .. "java" .. PATHSEP .. "lang" .. PATHSEP .. "String.java")
    test.equal(row.root_label, "Java Sources")
    test.equal(row.root_role, "external")
    test.same(row.prefix_span, { 1, #"Java Sources" })
    test.ok(common.path_equals(row.path, external_file))
  end)

end)
