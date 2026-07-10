local Doc = require "core.doc"
local markdown_model = require "core.markdown.model"
local test = require "core.test"
local worker_pool = require "core.worker_pool"

local function make_doc(text, filename)
  filename = filename or "model.md"
  local doc = Doc(filename, filename, true)
  doc:insert(1, 1, text)
  doc:clear_undo_redo()
  return doc
end

local function wait_status(instance, wanted, timeout)
  local deadline = system.get_time() + (timeout or 5)
  repeat
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    if instance.status == wanted then return true end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  return instance.status == wanted
end

local function find_node(nodes, node_type)
  for _, node in ipairs(nodes or {}) do
    if node.type == node_type then return node end
  end
end

test.describe("Markdown semantic model", function()
  test.it("shares one asynchronously published model per Document", function()
    local doc = make_doc("# Heading\n\nText with **bold** and *italic*.\n")
    local first = markdown_model.get(doc)
    local second = markdown_model.get(doc)
    test.equal(first, second)
    test.equal(first.status, "pending")
    test.ok(wait_status(first, "ready"), first.reason)
    test.equal(first.published_revision, doc.text_revision)

    local nodes, reason = first:nodes_for_lines(1, 3)
    test.not_nil(nodes, reason)
    local heading = test.not_nil(find_node(nodes, "heading"))
    local strong = test.not_nil(find_node(nodes, "strong"))
    local emphasis = test.not_nil(find_node(nodes, "emphasis"))
    test.ok(#heading.marker_ranges >= 1)
    test.ok(#strong.marker_ranges >= 2)
    test.equal(#emphasis.marker_ranges, 2)
    test.equal(strong.source.line1, 3)
    test.equal(strong.source.col1, 11)
    test.equal(strong.source.col2, 19)

    markdown_model.close(doc, "test")
  end)

  test.it("preserves semantic identities through incremental publications", function()
    local doc = make_doc("# Heading\n\nText with **bold**.\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local before = test.not_nil(instance:nodes_for_lines(1, 3))
    local heading_id = test.not_nil(find_node(before, "heading")).id
    local strong_id = test.not_nil(find_node(before, "strong")).id

    doc:insert(#doc.lines, 1, "Tail paragraph.\n")
    test.equal(instance.status, "pending")
    test.ok(wait_status(instance, "ready"), instance.reason)
    local after = test.not_nil(instance:nodes_for_lines(1, 3))
    test.equal(test.not_nil(find_node(after, "heading")).id, heading_id)
    test.equal(test.not_nil(find_node(after, "strong")).id, strong_id)
    test.equal(instance.diagnostics.incremental_publications, 1)
    test.ok(instance.diagnostics.reused_block_captures > 0)
    test.ok(instance.diagnostics.reused_inline_regions > 0)
    test.equal(#instance.changed_ranges, 1)
    test.equal(instance.changed_ranges[1].line1, 4)
    test.equal(instance.changed_ranges[1].line2, 5)
    local published_result = instance.result
    markdown_model.close(doc, "test")
    test.equal(pcall(function() published_result:summary() end), false)
  end)

  test.it("drops stale inline captures when an edited construct becomes plain source", function()
    local doc = make_doc("Text with **bold**.\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.not_nil(find_node(test.not_nil(instance:nodes_for_lines(1, 1)), "strong"))

    doc:remove(1, 11, 1, 13)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local after = test.not_nil(instance:nodes_for_lines(1, 1))
    test.equal(find_node(after, "strong"), nil)
    test.not_nil(find_node(after, "paragraph"))
    test.equal(instance.diagnostics.incremental_publications, 1)
    markdown_model.close(doc, "test")
  end)

  test.it("keeps pending and incomplete syntax on the raw-fallback path", function()
    local doc = make_doc("Incomplete **bold\n")
    local instance = markdown_model.get(doc)
    local nodes, reason = instance:nodes_for_lines(1, 1)
    test.equal(nodes, nil)
    test.equal(reason, "pending")
    test.ok(wait_status(instance, "ready"), instance.reason)
    nodes = test.not_nil(instance:nodes_for_lines(1, 1))
    test.equal(find_node(nodes, "strong"), nil)
    markdown_model.close(doc, "test")
  end)

  test.it("rejects stale parse publication after a newer text revision", function()
    local lines = {}
    for i = 1, 4000 do lines[i] = "Paragraph " .. i .. " with **bold** text." end
    local doc = make_doc(table.concat(lines, "\n"))
    local instance = markdown_model.get(doc)
    local first_generation = instance.parse_generation
    doc:insert(1, 1, "# New heading\n")
    test.ok(wait_status(instance, "ready", 10), instance.reason)
    test.ok(instance.parse_generation > first_generation)
    test.equal(instance.published_revision, doc.text_revision)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 1))
    test.not_nil(find_node(nodes, "heading"))
    test.ok(instance.diagnostics.stale + instance.diagnostics.cancelled >= 1)
    markdown_model.close(doc, "test")
  end)

  test.it("publishes exact Obsidian Wikilink and embed semantics", function()
    local doc = make_doc("[[Note#Heading|Alias]] and ![[image.png|640x480]]\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 1))
    local wiki = test.not_nil(find_node(nodes, "wiki_link"))
    test.equal(wiki.source.col1, 1)
    test.equal(wiki.source.col2, 23)
    test.equal(#wiki.marker_ranges, 2)
    test.equal(wiki.attributes.target.col1, 3)
    test.equal(wiki.attributes.target.col2, 15)
    test.equal(wiki.attributes.alias.col1, 16)
    test.equal(wiki.attributes.alias.col2, 21)
    local embed = test.not_nil(find_node(nodes, "embed"))
    test.equal(#embed.marker_ranges, 2)
    test.not_nil(embed.attributes.target)
    test.not_nil(embed.attributes.alias)
    test.equal(find_node(nodes, "link_reference"), nil)
    local captures = test.not_nil(instance:captures_for_lines("inline", 1, 1))
    local wiki_match, embed_match, wiki_marker_match
    for _, capture in ipairs(captures) do
      if capture.capture == "span.wiki_link" then wiki_match = capture.match_id end
      if capture.capture == "span.embed" then embed_match = capture.match_id end
      if capture.capture == "marker.wiki_open" then wiki_marker_match = capture.match_id end
    end
    test.not_nil(wiki_match)
    test.not_nil(embed_match)
    test.ok(wiki_match ~= embed_match)
    test.equal(wiki_marker_match, wiki_match)
    markdown_model.close(doc, "test")
  end)

  test.it("publishes highlights and multiline comments with code suppression", function()
    local doc = make_doc("==highlight **bold**== and `==code==`\n%%hidden **not bold**\nstill hidden%%\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 3))
    test.not_nil(find_node(nodes, "highlight"))
    test.not_nil(find_node(nodes, "strong"))
    local comment = test.not_nil(find_node(nodes, "comment"))
    test.equal(comment.source.line1, 2)
    test.equal(comment.source.line2, 3)
    local strong_count = 0
    local highlight_count = 0
    for _, node in ipairs(nodes) do
      if node.type == "strong" then strong_count = strong_count + 1 end
      if node.type == "highlight" then highlight_count = highlight_count + 1 end
    end
    test.equal(strong_count, 1)
    test.equal(highlight_count, 1)
    markdown_model.close(doc, "test")
  end)

  test.it("leaves escaped and incomplete Obsidian delimiters raw", function()
    local doc = make_doc("\\[[Escaped]] [[Incomplete\n\\==escaped==\n==incomplete\n[[]] [[|Alias]] %%%%\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 4))
    test.equal(find_node(nodes, "wiki_link"), nil)
    test.equal(find_node(nodes, "highlight"), nil)
    test.equal(find_node(nodes, "comment"), nil)
    markdown_model.close(doc, "test")
  end)

  test.it("republishes after legacy raw edits and reload", function()
    local doc = make_doc("# Original\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local generation = instance.generation

    doc:raw_insert(1, 1, "prefix\n", doc.undo_stack, system.get_time())
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > generation)
    local heading = test.not_nil(find_node(instance:nodes_for_lines(2, 2), "heading"))
    test.equal(heading.source.line1, 2)

    local path = USERDIR .. PATHSEP .. "markdown-model-reload-" .. system.get_process_id() .. ".md"
    local fp = test.not_nil(io.open(path, "wb"))
    fp:write("# Reloaded\n")
    fp:close()
    generation = instance.generation
    doc:load(path)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > generation)
    heading = test.not_nil(find_node(instance:nodes_for_lines(1, 1), "heading"))
    test.equal(heading.source.line1, 1)

    generation = instance.generation
    doc:load(path)
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.ok(instance.generation > generation)
    test.equal(instance.published_revision, doc.text_revision)
    os.remove(path)
    markdown_model.close(doc, "test")
  end)

  test.it("invalidates queued debounce work when the model closes", function()
    local doc = make_doc("# Before\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    doc:insert(2, 1, "change\n")
    local requests = instance.diagnostics.requests
    test.equal(instance.status, "pending")
    test.equal(markdown_model.close(doc, "test-close"), true)
    coroutine.yield(0.03)
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    test.equal(instance.status, "closed")
    test.equal(instance.diagnostics.requests, requests)
    test.equal(markdown_model.peek(doc), nil)
  end)

  test.it("does not parse Markdown nested inside raw HTML blocks", function()
    local doc = make_doc("<div>\n**not emphasis** ==not highlight== [[Not a link]]\n</div>\n")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local nodes = test.not_nil(instance:nodes_for_lines(1, 3))
    test.not_nil(find_node(nodes, "html"))
    test.equal(find_node(nodes, "strong"), nil)
    test.equal(find_node(nodes, "highlight"), nil)
    test.equal(find_node(nodes, "wiki_link"), nil)
    markdown_model.close(doc, "test")
  end)

  test.it("automatically detaches and republishes across metadata eligibility changes", function()
    local doc = make_doc("# Heading\n", "note.md")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)

    doc:set_filename("note.txt", "note.txt")
    test.equal(instance.status, "detached")
    test.equal(instance.result, nil)

    doc:set_filename("note.md", "note.md")
    test.equal(instance.status, "pending")
    test.ok(wait_status(instance, "ready"), instance.reason)
    test.equal(instance.published_revision, doc.text_revision)
    markdown_model.close(doc, "test")
  end)

  test.it("coalesces a queued text parse into an immediate metadata parse", function()
    local doc = make_doc("# Heading\n", "note.md")
    local instance = markdown_model.get(doc)
    test.ok(wait_status(instance, "ready"), instance.reason)
    local requests = instance.diagnostics.requests

    doc:insert(1, #doc.lines[1], " changed")
    doc:set_filename("moved.md", "moved.md")
    test.ok(wait_status(instance, "ready"), instance.reason)
    coroutine.yield(0.03)
    local pool = worker_pool.current_system()
    if pool then pool:drain({ max_ms = 5, max_messages = 64 }) end
    test.equal(instance.diagnostics.requests, requests + 1)
    markdown_model.close(doc, "test")
  end)

  test.it("does not allocate models for non-Markdown Documents", function()
    local doc = make_doc("# Plain text", "note.txt")
    test.equal(markdown_model.get(doc), nil)
    test.equal(markdown_model.peek(doc), nil)
  end)
end)
