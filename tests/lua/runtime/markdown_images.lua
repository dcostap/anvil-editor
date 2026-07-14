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
  test.before_each(function() images.clear_assets() end)

  test.it("uses stable cache paths for remote images", function()
    local one = images.get_image_cache_path("https://example.com/a/diagram.png?rev=1", USERDIR .. PATHSEP .. "cache")
    local two = images.get_image_cache_path("https://example.com/a/diagram.png?rev=1", USERDIR .. PATHSEP .. "cache")
    test.equal(one, two)
    test.ok(one:match("%.png$"))
  end)

  test.it("does not download remote images when policy is disabled", function()
    local called = false
    local entry = images.get_asset("https://example.com/track.png", {
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

  test.it("honors every Obsidian attachment-folder location policy", function()
    local root = USERDIR .. PATHSEP .. "markdown-image-attachment-policies-" .. system.get_process_id()
    local obsidian = root .. PATHSEP .. ".obsidian"
    local notes = root .. PATHSEP .. "notes"
    test.ok(common.mkdirp(obsidian))
    test.ok(common.mkdirp(notes))
    local source = notes .. PATHSEP .. "Note.md"
    local app_json = obsidian .. PATHSEP .. "app.json"

    write_file(app_json, [[{"attachmentFolderPath":"/"}]])
    test.equal(images.attachment_directory({ source_path = source, project_root = root }), common.normalize_path(root))

    write_file(app_json, [[{"attachmentFolderPath":"./"}]])
    test.equal(images.attachment_directory({ source_path = source, project_root = root }), common.normalize_path(notes))

    write_file(app_json, [[{"attachmentFolderPath":"./assets"}]])
    test.equal(
      images.attachment_directory({ source_path = source, project_root = root }),
      common.normalize_path(notes .. PATHSEP .. "assets")
    )

    write_file(app_json, [[{"attachmentFolderPath":"vault-assets"}]])
    test.equal(
      images.attachment_directory({ source_path = source, project_root = root }),
      common.normalize_path(root .. PATHSEP .. "vault-assets")
    )

    write_file(app_json, [[{"attachmentFolderPath":]])
    test.equal(
      images.attachment_directory({
        source_path = source, project_root = root, configured_folder = "fallback-assets",
      }),
      common.normalize_path(root .. PATHSEP .. "fallback-assets")
    )
    common.rm(root, true)
  end)

  test.it("keys local assets by resolution context and retries missing files by generation", function()
    local root = USERDIR .. PATHSEP .. "markdown-image-assets-" .. system.get_process_id()
    local one = root .. PATHSEP .. "one"
    local two = root .. PATHSEP .. "two"
    test.ok(common.mkdirp(one))
    test.ok(common.mkdirp(two))
    write_file(one .. PATHSEP .. "shared.png", "one")
    write_file(two .. PATHSEP .. "shared.png", "two")
    local loads = 0
    local function loader(path)
      loads = loads + 1
      return { path = path, get_size = function() return 1, 1 end }
    end
    local first = images.get_asset("shared.png", {
      source_path = one .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    local shared = images.get_asset("shared.png", {
      source_path = one .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    local other = images.get_asset("shared.png", {
      source_path = two .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    test.equal(first, shared)
    test.ok(first ~= other)
    test.equal(loads, 2)
    test.equal(first.path, one .. PATHSEP .. "shared.png")
    test.equal(other.path, two .. PATHSEP .. "shared.png")

    write_file(root .. PATHSEP .. "shared.png", "shared")
    local shared_from_one = images.get_asset("../shared.png", {
      source_path = one .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    local shared_from_two = images.get_asset("../shared.png", {
      source_path = two .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    test.equal(shared_from_one, shared_from_two)
    test.equal(loads, 3)

    local missing_path = one .. PATHSEP .. "later.png"
    local missing = images.get_asset("later.png", {
      source_path = one .. PATHSEP .. "Note.md", loader = loader, retry_generation = 1,
    })
    test.equal(missing.status, "error")
    write_file(missing_path, "later")
    local retried = images.get_asset("later.png", {
      source_path = one .. PATHSEP .. "Note.md", loader = loader, retry_generation = 2,
    })
    test.ok(retried ~= missing)
    test.equal(retried.status, "ready")
    test.equal(retried.path, missing_path)
    common.rm(root, true)
  end)

  test.it("shares one remote request and notifies every subscriber", function()
    local downloads, done = 0
    local opts = {
      download_remote = true,
      cache_dir = USERDIR .. PATHSEP .. "markdown-image-remote-cache",
      retry_generation = 1,
      downloader = function(_, request) downloads, done = downloads + 1, request.on_done end,
    }
    local entry = images.get_asset("https://example.com/shared.png", opts)
    test.equal(images.get_asset("https://example.com/shared.png", opts), entry)
    test.equal(downloads, 1)
    local owner1, owner2, notifications = {}, {}, 0
    images.subscribe(entry, owner1, function() notifications = notifications + 1 end)
    images.subscribe(entry, owner2, function() notifications = notifications + 1 end)
    done(false, "network disabled in test")
    test.equal(entry.status, "error")
    test.equal(notifications, 2)
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

    width, height = images.scale_size(1000, 500, 1000, { width = 640, height = 480 }, false)
    test.equal(width, 640)
    test.equal(height, 320)
    width, height = images.scale_size(500, 1000, 1000, { width = 640, height = 480 }, false)
    test.equal(width, 240)
    test.equal(height, 480)
  end)
end)
