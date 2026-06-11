-- mod-version:3
-- Canonical native editor plugin entry point.
-- The implementation still lives in native_text_sandbox.lua while the view is
-- promoted out of its sandbox phase; keep this module as the stable workspace
-- and command-facing plugin name.
return require "plugins.native_text_sandbox"
