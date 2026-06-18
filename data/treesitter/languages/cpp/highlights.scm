; Bundled first-party C++ highlights for Anvil's initial Tree-sitter renderer.
; This intentionally mirrors the C query where node names are shared, then adds
; C++-specific constructs from tree-sitter-cpp.

(identifier) @variable

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z\\d_]*$")
 (#set! priority 1))

[
  "break"
  "case"
  "const"
  "continue"
  "default"
  "do"
  "else"
  "enum"
  "extern"
  "for"
  "if"
  "inline"
  "return"
  "sizeof"
  "static"
  "struct"
  "switch"
  "typedef"
  "union"
  "volatile"
  "while"
  "catch"
  "class"
  "co_await"
  "co_return"
  "co_yield"
  "constexpr"
  "consteval"
  "constinit"
  "concept"
  "delete"
  "explicit"
  "final"
  "friend"
  "mutable"
  "namespace"
  "new"
  "noexcept"
  "override"
  "private"
  "protected"
  "public"
  "requires"
  "template"
  "throw"
  "try"
  "typename"
  "using"
  "virtual"
] @keyword

[
  "#define"
  "#elif"
  "#else"
  "#endif"
  "#if"
  "#ifdef"
  "#ifndef"
  "#include"
] @keyword

(preproc_directive) @keyword

[
  "--"
  "-"
  "-="
  "->"
  "="
  "!="
  "*"
  "&"
  "&&"
  "+"
  "++"
  "+="
  "<"
  "=="
  ">"
  "||"
] @operator

[ "." ";" "," ":" "::" ] @delimiter
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket

(string_literal) @string
(raw_string_literal) @string
(system_lib_string) @string
(char_literal) @string
(escape_sequence) @escape

(null) @constant.builtin
(number_literal) @number
(this) @variable.builtin
(auto) @type.builtin

(field_identifier) @property
(statement_identifier) @label
(type_identifier) @type
(primitive_type) @type.builtin
(sized_type_specifier) @type.builtin
(namespace_identifier) @namespace
((namespace_identifier) @type
 (#match? @type "^[A-Z]"))
(call_expression
  function: (identifier) @function.call)
(call_expression
  function: (qualified_identifier
    name: (identifier) @function.call))
(call_expression
  function: (field_expression
    field: (field_identifier) @function.method.call))
(template_function
  name: (identifier) @function.call)
(template_method
  name: (field_identifier) @function.method.call)
(function_declarator
  declarator: (identifier) @function)
(function_declarator
  declarator: (qualified_identifier
    name: (identifier) @function))
(function_declarator
  declarator: (field_identifier) @function.method)
(preproc_function_def
  name: (identifier) @function.special)

(comment) @comment
