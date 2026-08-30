# Smart Indentation and Whitespace Improvement Plan

## Purpose

Improve Anvil's coding whitespace behavior using Zed's simpler layered model as the baseline, but with one Anvil-specific goal: make the smart behavior the normal behavior. Do not build a pile of compatibility modes or optional knobs.

The goal is not to make Anvil "able to indent" — it already can. The goal is to make indentation behavior predictable, integrated, language-aware, and easy to extend from one obvious place.

## Current Anvil baseline

Anvil already has several important pieces:

- `doc:newline` preserves leading indentation.
- `config.keep_newline_whitespace = false` removes whitespace-only lines when pressing Enter.
- Bracket-pair smart newline exists for `()`, `[]`, and `{}` in `data/core/commands/doc.lua`.
- `doc:backspace` has a first pass at indent-sized deletion in leading spaces.
- `trimwhitespace` exists in `data/plugins/trimwhitespace.lua`.
- `detectindent` exists in `data/plugins/detectindent.lua`.
- `core.language_intelligence` already exists as the provider registry for syntax/project intelligence.

The weakness is that these behaviors are command-local and heuristic rather than a single smart indentation system.

## Target model

Use one smart default behavior:

1. Preserve indentation first.
2. Clean indentation-only blank lines while editing.
3. Apply syntax-aware indentation correction when Anvil can infer it.
4. Trim trailing whitespace on save/autosave.
5. Keep Enter, Tab, Backspace, and Paste consistent with the same indentation rules.
6. Keep language-specific indentation data in one obvious first-party file, not buried inside core command code.

## Non-goals for the current implementation

- Do not implement IntelliJ-style delayed whitespace stripping.
- Do not add a full formatter.
- Do not require LSP formatting support.
- Do not add user-facing auto-indent modes.
- Do not add compatibility shims for old indentation behavior.
- Do not scatter language indentation rules through core command implementations.

## Test-first workflow

For every phase, write the planned tests before changing implementation code.

Run the new tests against the current code first and record which expectations already pass and which fail. Existing passing behavior should not be reimplemented just for churn. Failing tests define the actual implementation work for that phase.

Workflow per phase:

1. Add targeted tests for the intended behavior.
2. Run the targeted tests before implementation.
3. Note which tests are already green and which are red.
4. Implement only the behavior needed for the red tests and any required cleanup.
5. Re-run the targeted tests.
6. Run the relevant broader Lua suite.

When reporting a completed phase, include the red/green evidence: which tests failed before implementation, what they showed, and which tests/suites passed afterward.

## Central language rules file

Create one first-party language indentation rules file, for example:

```text
data/plugins/smart_indent_rules.lua
```

This file should contain the built-in indentation behavior for languages and file types. It should register an indentation provider with `core.language_intelligence` and expose a data-driven rule table.

Core editing commands should not know C, Lua, Python, Markdown, etc. directly. They should ask the smart indentation layer for the expected indentation, and the smart indentation layer should consult this central rules file.

Suggested shape:

```lua
local rules = {
  lua = {
    extensions = { "lua" },
    indent_after = { ... },
    outdent_before = { ... },
    continuation = { ... },
    comments = { ... },
  },
  python = {
    extensions = { "py", "pyw" },
    indent_after = { ... },
    outdent_before = { ... },
    continuation = { ... },
    comments = { ... },
  },
}
```

The exact schema should be designed during implementation, but the important rule is organizational: language indentation knowledge lives together in this file.

## Phase 1: Clean up existing Enter whitespace handling

### Problem

`doc:newline` currently handles whitespace-only lines by falling back to a temporary `Doc`, simulating edits, and replacing the whole document. This works but is heavy and harder to reason about.

### Improvement

Replace that fallback with targeted per-selection edits:

- Evaluate every selection/caret, not only the active selection.
- If a selection is collapsed and the current line is whitespace-only, replace the whole whitespace-only line range with `"\n" .. indent`.
- The edit must consume all remaining whitespace on that line so a caret in the middle of `"    \n"` leaves the previous line truly blank.
- Coalesce same-line whitespace-only newline requests before applying edits. Multiple carets on the same whitespace-only line would otherwise produce overlapping whole-line edits.
- Preserve current non-collapsed selection replacement behavior unless a later phase intentionally redesigns it.

This mirrors Zed's simple approach: pressing Enter on an indentation-only line moves the useful indent to the new line and leaves the old line truly blank, without whole-document replacement.

### Tests

Add/adjust UI tests for:

- Single caret on whitespace-only line.
- Multiple carets on whitespace-only lines.
- Multiple carets on the same whitespace-only line are coalesced.
- Mixed whitespace-only and normal lines.
- Selection replacement still behaves correctly.
- Smart bracket newline still works.

## Phase 2: Backspace to previous tab stop

### Problem

Current `doc:backspace` can delete exactly `indent_size` spaces in leading whitespace. It should instead delete to the previous actual tab stop.

Example with 4-column indentation:

- caret at column 9 -> delete to column 5;
- caret at column 7 -> delete to column 5;
- caret at column 5 -> delete to column 1.

### Improvement

When a collapsed caret is inside leading whitespace:

1. Compute the caret's visual indentation column.
2. Compute the previous tab stop.
3. Delete only the bytes needed to reach that stop.
4. Support partial indentation, spaces, tabs, and mixed indentation.

### Tests

Add tests for:

- Full soft-tab stops.
- Partial soft-tab stops.
- Hard tabs.
- Mixed indentation.
- Multiple carets.
- Non-leading-whitespace backspace still deletes one character.

## Phase 3: Make whitespace cleanup first-party default behavior

### Problem

Zed removes trailing whitespace on save by default. Anvil has `trimwhitespace`, but bundled defaults disable it.

### Improvement

Make trailing whitespace trimming part of Anvil's default first-party behavior:

```lua
plugin_defaults("trimwhitespace", {
  enabled = true,
  trim_empty_end_lines = false,
})
```

Because bundled defaults already enable `autosave_fast`, this is both explicit-save and autosave behavior. That is acceptable: Anvil should keep files clean automatically.

Before enabling by default, improve `trimwhitespace.trim` so it preserves every caret/selection endpoint that would otherwise be moved, not only the active caret from `doc:get_selection()`.

### Policy

- Trim trailing whitespace on explicit save and autosave.
- Do not move carets or selection endpoints.
- Preserve whitespace before/under every caret or selection endpoint when trimming would move it.
- Do not remove final blank lines by default as part of this phase.

### Tests

Add/adjust runtime tests for:

- Whitespace-only lines are trimmed.
- Active caret line is preserved when trimming would move the caret.
- Non-active carets inside trailing whitespace are preserved.
- Selection endpoints inside trailing whitespace are preserved.
- Explicit save invokes trimming.
- Autosave invokes trimming.
- Documents that explicitly disable trimming through existing document-local state still skip trimming if that path remains in the plugin.

## Phase 4: Make smart syntax indentation the only Enter model

### Problem

A mode system like `none | preserve | syntax` is unnecessary for this fork. The desired behavior is the smart one.

### Improvement

Make `doc:newline` follow one pipeline:

1. Build the basic newline edit by preserving current indentation.
2. Clean indentation-only source lines as in Phase 1.
3. Apply bracket-pair smart newline where appropriate.
4. Ask language intelligence for expected indentation of the new line.
5. Apply syntax-aware correction if a language rule answers.
6. Fall back to preserved indentation if no rule applies.

There should be no user-facing auto-indent mode knob. Existing behavior/configuration that conflicts with this direction should be migrated in-repo rather than preserved with compatibility branches.

### Tests

Add tests for:

- Basic indentation preservation when no language rule applies.
- Bracket-pair smart newline remains the default behavior.
- Syntax rule adjusts indentation after Enter.
- Syntax rule can outdent a closing-token line.
- Whitespace-only line cleanup composes with syntax-aware indentation.
- Multiple carets apply the same pipeline in one coherent document change.

## Phase 5: Central smart indentation rules for major languages

### Problem

Anvil's smart newline currently knows a few delimiter cases, but it does not have broad language-aware indentation. The language-specific behavior must be extensive enough to feel useful across common coding files, while still living in one obvious file.

### Improvement

Implement a central first-party indentation rule table in `data/plugins/smart_indent_rules.lua` and register it through `core.language_intelligence` as an indentation provider.

Add a helper such as:

```lua
language_intelligence.indent_for_line(doc, line, context)
```

Provider feature shape:

```lua
provider.indent_for_line(doc, line, context) -> string | nil
```

The provider should:

- identify the relevant rule by filename, extension, shebang, or existing syntax name;
- compute expected indentation from nearby document text;
- return `nil` when no safe rule applies;
- use `core.log_quiet(...)` for useful fallback/debug decisions;
- avoid formatting unrelated text;
- avoid deep parser dependencies in the first implementation.

### Rule schema goals

The central file should support data-driven entries for:

- file extensions and aliases;
- line comments and block comments;
- tokens/patterns that indent the following line;
- tokens/patterns that outdent the current line;
- paired delimiters;
- continuation indentation after open delimiters or trailing operators;
- switch/case-like constructs;
- language-specific block openers/closers;
- Markdown/list continuation where relevant.

Some languages will need custom functions. That is fine, but those functions should still live in the central smart-indent rules file unless there is a strong reason to split them out later.

### Initial top-language coverage

Be thorough up front. Prefill rule entries for roughly the top 50 common languages/file families, even if some entries start with conservative delimiter/comment rules only.

Suggested initial coverage:

1. JavaScript
2. TypeScript
3. JSX
4. TSX
5. Python
6. Java
7. C
8. C++
9. C#
10. Go
11. Rust
12. PHP
13. Ruby
14. Lua
15. Shell/Bash
16. PowerShell
17. Kotlin
18. Swift
19. Objective-C
20. Scala
21. Dart
22. R
23. Julia
24. Perl
25. Groovy
26. Haskell
27. OCaml
28. Elixir
29. Erlang
30. Clojure
31. F#
32. SQL
33. HTML
34. CSS
35. SCSS/Sass
36. Less
37. JSON
38. JSONC
39. YAML
40. TOML
41. XML
42. Markdown
43. Dockerfile
44. Makefile
45. CMake
46. Nix
47. Terraform/HCL
48. Vue
49. Svelte
50. Zig

Coverage expectations by family:

- Brace languages: indent after `{`, outdent before `}`, continue open delimiters, handle `case/default` where applicable.
- Python/YAML/Haskell-like layout languages: indent after block introducers such as `:`, avoid unsafe automatic outdent unless a clear closer exists.
- Lua/Ruby/Shell/PowerShell-like keyword block languages: indent after block openers, outdent before closers.
- Markup languages: basic tag-pair indentation and comment continuation.
- Data formats: delimiter-based indentation for JSON/TOML/XML/YAML where safe.
- Markdown: list continuation, blockquote continuation, fenced-code awareness where practical.

### Tests

Do not test all 50 languages exhaustively in the first commit. Instead:

- Add focused tests for representative families: brace, keyword-block, layout, markup, data, Markdown.
- Add a registry/schema test that every rule entry has required fields and valid pattern types.
- Add smoke tests for all prefilled language entries to ensure they load and can answer or safely return `nil`.
- Add targeted tests for Anvil's most-used languages first: Lua, C/C++, Python, JavaScript/TypeScript, JSON, Markdown, Shell, PowerShell.

## Phase 6: Smarter Tab in leading whitespace

### Problem

Zed's Tab inside indentation can repair a line to expected indentation before falling back to inserting a tab/soft tab. Anvil mostly performs generic indentation.

### Improvement

First refactor the Tab/indent command path enough to plan edits for all selections and apply them in one batch where practical. Today `doc:indent` loops selections and `Doc:indent_text` applies edits internally, which makes provider-backed multi-caret repair hard to keep atomic.

When the caret is collapsed and inside leading whitespace:

1. Ask language intelligence for expected indentation.
2. If the current line is under-indented or over-indented relative to a confident rule, replace leading whitespace with the expected indent and move the caret there.
3. Otherwise insert the normal indent string/tab stop.

Selection indentation should keep its current line-based behavior unless a separate change intentionally redesigns it.

### Tests

Add tests for:

- Tab repairs under-indented syntax-aware line.
- Tab repairs over-indented syntax-aware line only when the rule is confident.
- Tab still inserts normal indentation when no provider applies.
- Selection indentation remains unchanged.
- Multiple carets are handled in one document edit.

## Phase 7: Auto-indent on paste

### Problem

Zed has `auto_indent_on_paste`. Anvil paste currently inserts clipboard text without indentation-aware adjustment.

### Improvement

Make multi-line paste indentation-aware by default. Do not add a config toggle in the current implementation.

Initial behavior should be conservative:

- Only adjust multi-line paste.
- Preserve relative indentation inside the pasted block.
- Align the first meaningful pasted line to the current insertion indentation.
- Avoid changing paste inside strings/comments unless language intelligence can safely decide.
- Scope the first implementation to specific paste paths. Anvil's `doc:paste` has external clipboard paste, matching internal cursor clipboards, whole-line clipboards, mixed clipboard handling, and paste-all behavior. `doc:paste-primary-selection` is a separate path. Decide explicitly which paths are adjusted.
- Preserve whole-line clipboard placement semantics unless there is a deliberate user-facing change.
- Keep multi-caret paste as one coherent document change where the existing path already does so.

### Tests

Add tests for:

- Pasting an indented block into an indented location.
- Pasting at column 1 is unchanged.
- Pasting with multiple carets.
- Pasting text with blank lines.
- External clipboard paste versus internal cursor clipboard paste.
- Whole-line clipboard paste remains stable or is intentionally redesigned with tests.
- Primary-selection paste follows the chosen policy.

## Phase 8: Comment and list continuation

### Problem

Zed continues comments, doc comments, and Markdown/list markers on Enter. Anvil mainly handles bracket pairs.

### Improvement

Implement continuation through the central smart-indent rules file where possible:

- line comments, such as `//`, `#`, `--`;
- doc comments, such as `///`, `/** ... */`, `--[[ ... ]]` where practical;
- block comment continuation like `* `;
- Markdown unordered lists: `- `, `* `, `+ `;
- Markdown ordered lists: `1. ` -> `2. `;
- Markdown blockquotes: `> `.

Keep the core Enter command generic: it asks the smart indentation/continuation provider what text to insert around the newline.

### Tests

Add tests for:

- Line comment continuation.
- Empty continued comment behavior.
- Block comment continuation.
- Markdown unordered list continuation.
- Markdown ordered list increment.
- Markdown blockquote continuation.
- Bracket-pair smart newline precedence.

## Phase 9: Future idea, not current implementation: Tree-sitter indentation

Tree-sitter-backed indentation may be useful later, but it is not part of the current implementation plan.

Future possibilities:

- query-based indentation metadata;
- incremental parse-aware indentation;
- better mixed-language files such as Vue/Svelte/HTML with scripts/styles;
- fallback to central rules when parsing is unavailable or stale.

For now, build the central rule-file architecture and simple syntax-aware behavior first.

## Implementation notes

- Prefer small targeted document edits over whole-document replacement.
- Use `core.log_quiet(...)` for provider decisions, fallback decisions, and skipped syntax-indent cases.
- Keep language indentation knowledge in `data/plugins/smart_indent_rules.lua` or its chosen single-file equivalent.
- Keep first-party defaults in `data/plugins/anvil_defaults.lua` or `data/core/config.lua`, not hidden inside plugin implementations.
- Do not test exact keyboard shortcuts; test commands such as `command.perform("doc:newline")`.
- Use Meson Lua UI/runtime tests for behavior changes.

## Suggested first milestone

A good first implementation milestone would include:

1. Targeted Enter cleanup for whitespace-only lines.
2. Backspace-to-previous-tabstop.
3. Central `smart_indent_rules.lua` skeleton registered through `core.language_intelligence`.
4. Smart Enter using central rules for a small representative set: Lua, C/C++, Python, JavaScript/TypeScript, JSON, Markdown, Shell/PowerShell.
5. Regression tests for the above.

Then expand the central rules file toward the top-50 language coverage list before moving on to paste and more advanced Tab repair.
