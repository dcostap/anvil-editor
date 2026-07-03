# Tree-sitter dependency notes

## Pinned revisions

- Tree-sitter runtime: `tree-sitter/tree-sitter` commit `519d511488497f6af43698d4c856f4b3f1f0b80c`, version `0.27.0`.
- Tree-sitter C grammar: `tree-sitter/tree-sitter-c` commit `b780e47fc780ddc8da13afa35a3f4ed5c157823d`, version `0.24.2`.
- Tree-sitter C++ grammar: `tree-sitter/tree-sitter-cpp` commit `f41e1a044c8a84ea9fa8577fdd2eab92ec96de02`, version `0.23.4`.
- Tree-sitter Odin grammar: `tree-sitter-grammars/tree-sitter-odin` commit `d2ca8efb4487e156a60d5bd6db2598b872629403`, version `1.3.0`.
- Tree-sitter Kotlin grammar: `fwcd/tree-sitter-kotlin` commit `c8ac3d2627240160b999a2c100de3babbdb8f419`, version `0.4.0`.

The build uses tracked Meson wraps plus tracked packagefile Meson build definitions:

- `subprojects/tree-sitter.wrap`
- `subprojects/tree-sitter-c.wrap`
- `subprojects/tree-sitter-cpp.wrap`
- `subprojects/tree-sitter-odin.wrap`
- `subprojects/tree-sitter-kotlin.wrap`
- `subprojects/packagefiles/tree-sitter/meson.build`
- `subprojects/packagefiles/tree-sitter-c/meson.build`
- `subprojects/packagefiles/tree-sitter-cpp/meson.build`
- `subprojects/packagefiles/tree-sitter-odin/meson.build`
- `subprojects/packagefiles/tree-sitter-kotlin/meson.build`

## API notes

Runtime `0.27.0` provides the APIs assumed by `TREE_SITTER_PLAN.md` for Phase 1:

- `ts_parser_parse_with_options` and `TSParseOptions.progress_callback` for parse cancellation.
- `ts_query_cursor_exec_with_options` and `TSQueryCursorOptions.progress_callback` for query progress/cancellation.
- `ts_language_abi_version` and `ts_language_metadata` for grammar compatibility/version checks.

Runtime ABI version: `15`.
Minimum compatible grammar ABI version: `13`.
Tree-sitter C grammar ABI version: `15`.
Tree-sitter C++ grammar ABI version: `14`.
Tree-sitter Odin grammar ABI version: `14`.
Tree-sitter Kotlin grammar ABI version: `14`.

## Licenses

Tree-sitter dependencies listed here are MIT licensed. The bundled Kotlin highlight query is based on nvim-treesitter's Apache-licensed Kotlin query, as noted in `data/treesitter/languages/kotlin/highlights.scm`.

### Tree-sitter runtime

Copyright (c) 2018 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Tree-sitter C grammar

Copyright (c) 2014 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Tree-sitter C++ grammar

Copyright (c) 2014 Max Brunsfeld

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Tree-sitter Odin grammar

Copyright (c) 2023 Amaan Qureshi <amaanq12@gmail.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

### Tree-sitter Kotlin grammar

Copyright (c) 2019 fwcd

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
