-- mod-version:3 --priority:10
-- Compatibility facade: soft wrapping is implemented by core.docview and
-- core.linewrapping. Keep this module for old require "plugins.linewrapping"
-- callers without patching Doc, DocView, commands, or translate helpers.
return require "core.linewrapping"
