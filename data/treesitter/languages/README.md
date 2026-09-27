# Tree-sitter language maps

Tree-sitter parses source text into grammar-specific syntax nodes. It does not build Anvil's Project Symbol Search index.

Each language owns its selection rules under `data/treesitter/languages/<id>/`:

- `config.lua` names the grammar, file patterns, and query files.
- `outline.scm` selects declarations for Current Buffer Symbol Search and Project Symbol Search.
- `locals.scm` or `usages.scm` selects syntactic names for Project Usage Search, when available.
- `highlights.scm` selects syntax colors, when available. It does not select symbols.

The outline query captures each selected item as `@outline.<kind>`.
It captures the item's name as `@name` in the same match.
Optional `@signature` captures supply display text.
Anvil's shared code turns these captures into symbol records.
It uses source ranges to group members under containers.
Open Buffers and the Project index use the same language query.

The query must select declarations, not all identifiers. Tree-sitter node types differ between grammars. Keep grammar-specific rules in the language folder. Share extraction code only when it can follow a stable syntax rule. Do not add one pattern per pointer depth or similar wrapper count. Tree-sitter does not resolve references to their definitions. Treat usage results as syntactic hints.

## Review of registered languages

This review covers the eight languages in `data/core/treesitter/registry.lua`.
It describes the current outline queries, not all forms that each grammar can parse.
Every registered language has an outline query.
The gaps below need work before Anvil can claim complete symbol coverage.

| Language | Current selection | Known limit or review need |
| --- | --- | --- |
| C | File-scope variables, function definitions, function-like macros, named types, enum members, and fields. | Declarator patterns cover only listed pointer and array shapes. Function declarations and object-like macros have no outline pattern. |
| C++ | File-scope variables, namespaces, named types, enum members, fields, methods, and function definitions. | Globals require a translation-unit parent. Fields stop at two pointer layers. Other declarator shapes need review. |
| JavaScript | Classes, functions, methods, and top-level variables with function values. | Ordinary variables and class fields have no outline pattern. Function declarations have no top-level scope guard. |
| TypeScript | JavaScript selections plus interfaces, type aliases, enums, and method signatures. | Ordinary variables, class fields, and enum members have no outline pattern. |
| TSX | The same selection as TypeScript, with its own grammar and query file. | The TypeScript omissions apply here too. Keep TSX tests separate from TypeScript tests. |
| Kotlin | Classes, objects, top-level functions and properties, class methods and properties, constructor properties, type aliases, and enum entries. | Function and property rules select named file and class scopes. Review other scopes when users need them. |
| Odin | Procedures, named types, fields, enum entries, constants, variables, packages, and foreign blocks. | The variable rule has no scope guard. Check local declarations before claiming globals-only results. |
| Markdown | ATX and setext headings. | Headings are the only symbols. There is no usage query. |

This review does not prove that every grammar shape works.
C and C++ still use shape-by-shape declarator patterns.
Do not extend those patterns one pointer layer at a time.

## Add or change a language

1. Register the grammar in the native build and `data/core/treesitter/registry.lua`.
2. Add `config.lua` and the language queries in one language folder.
3. Review the grammar's syntax nodes. Select intended declarations in `outline.scm`.
4. Check file-scope names, members, functions, types, and multiple names in one declaration where the language supports them.
5. Check wrappers, such as pointers, arrays, and function declarators. Do not enumerate arbitrary wrapper depth.
6. Exclude usages and unintended local names. Add `locals.scm` or `usages.scm` when Project Usage Search needs them.
7. Test Current Buffer Symbol Search and Project Symbol Search with real source text. Check included and excluded names.
8. Update this review with the new language's selections and known limits.

Use `tests/lua/runtime/treesitter_project_index_contract.lua` for native Project records.
Use `tests/lua/runtime/treesitter_global_symbols.lua` for C and C++ Project cases.
See `tests/lua/runtime/treesitter_javascript_typescript.lua` and `treesitter_markdown_symbols.lua` for Buffer examples.

Keep one query file per grammar when its syntax nodes differ.
Put shared record building in `data/core/treesitter/outline.lua` and `src/treesitter/project_file.c`.
Update both paths when symbol extraction changes.
A query edit needs a Tree-sitter reload and a fresh Project index.
The dev app reads these files through a source-data junction.
