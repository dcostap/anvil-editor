# Deprecated bundled plugins

This directory stores old bundled plugin source that is intentionally outside Anvil's normal plugin discovery path.

Archived plugins are reference material only. They are not loaded by `core.load_plugins`, are not supported during the native editor replacement, and may depend on Lua `Doc` / `DocView` APIs that are planned for removal.

If behavior from an archived plugin is wanted again, implement it through native editor capabilities or supported Lua app-shell orchestration instead of adapting the archived code around old editor internals.
