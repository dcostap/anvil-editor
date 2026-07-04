local live_render = require "core.markdown.live_render"
live_render.install()

return {
  parser = require "core.markdown.parser",
  links = require "core.markdown.links",
  anchors = require "core.markdown.anchors",
  images = require "core.markdown.images",
  live_render = live_render,
  vault_index = require "core.markdown.vault_index",
}
