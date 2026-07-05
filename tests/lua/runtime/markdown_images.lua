local common = require "core.common"
local images = require "core.markdown.images"
local test = require "core.test"

local function write_file(path, content)
  local file, err = io.open(path, "wb")
  test.not_nil(file, err)
  file:write(content or "")
  file:close()
end

test.describe("Markdown image helpers", function()
  test.it("uses stable cache paths for remote images", function()
    local one = images.get_image_cache_path("https://example.com/a/diagram.png?rev=1", USERDIR .. PATHSEP .. "cache")
    local two = images.get_image_cache_path("https://example.com/a/diagram.png?rev=1", USERDIR .. PATHSEP .. "cache")
    test.equal(one, two)
    test.ok(one:match("%.png$"))
  end)

  test.it("does not download remote images when policy is disabled", function()
    local called = false
    local entry = images.ensure_entry("https://example.com/track.png", {
      download_remote = false,
      downloader = function()
        called = true
      end,
    })
    test.equal(entry.status, "remote-disabled")
    test.equal(called, false)
  end)

  test.it("resolves local image URLs after stripping fragments and queries", function(context)
    local root = USERDIR .. PATHSEP .. "markdown-image-tests-" .. system.get_process_id()
    local ok, err = common.mkdirp(root)
    test.ok(ok, err)
    local image_path = root .. PATHSEP .. "diagram.png"
    write_file(image_path, "not-a-real-png")

    test.equal(images.resolve_local_path("diagram.png#caption", { source_path = root .. PATHSEP .. "note.md" }), image_path)
    test.equal(images.resolve_local_path("diagram.png?v=2", { project_root = root }), image_path)

    os.remove(image_path)
    common.rm(root, true)
  end)

  test.it("resolves Obsidian attachmentFolderPath from app.json", function()
    local root = USERDIR .. PATHSEP .. "markdown-image-attachments-" .. system.get_process_id()
    local obsidian = root .. PATHSEP .. ".obsidian"
    local media = root .. PATHSEP .. "configured-media"
    local ok, err = common.mkdirp(obsidian)
    test.ok(ok, err)
    ok, err = common.mkdirp(media)
    test.ok(ok, err)
    write_file(obsidian .. PATHSEP .. "app.json", [[{"attachmentFolderPath":"./configured-media"}]])
    local image_path = media .. PATHSEP .. "diagram.png"
    write_file(image_path, "not-a-real-png")

    test.equal(
      images.resolve_local_path("diagram.png", { source_path = root .. PATHSEP .. "Planificación Fabricación.md" }),
      image_path
    )

    os.remove(image_path)
    common.rm(root, true)
  end)

  test.it("parses and applies resize constraints without upscaling by default", function()
    local resize = images.parse_resize("100x145")
    test.equal(resize.width, 100)
    test.equal(resize.height, 145)

    local width, height = images.scale_size(50, 50, 500, { width = 100 }, false)
    test.equal(width, 50)
    test.equal(height, 50)

    width, height = images.scale_size(200, 100, 80, { width = 160 }, true)
    test.equal(width, 80)
    test.equal(height, 40)
  end)
end)
