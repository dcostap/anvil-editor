local live_render = require "core.markdown.live_render"
live_render.install()

return {
  parser = require "core.markdown.parser",
  model = require "core.markdown.model",
  links = require "core.markdown.links",
  anchors = require "core.markdown.anchors",
  images = require "core.markdown.images",
  attachments = require "core.markdown.attachments",
  live_render = live_render,
  vault_index = require "core.markdown.vault_index",
}
