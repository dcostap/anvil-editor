; Bundled first-party C highlights for Anvil's initial Tree-sitter renderer.

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

[ "." ";" "," ":" ] @delimiter
[ "(" ")" "[" "]" "{" "}" ] @punctuation.bracket

(string_literal) @string
(system_lib_string) @string
(char_literal) @string
(escape_sequence) @escape

(null) @constant.builtin
(number_literal) @number

(field_identifier) @property
(statement_identifier) @label
(struct_specifier
  name: (type_identifier) @type.struct)
(union_specifier
  name: (type_identifier) @type.struct)
(enum_specifier
  name: (type_identifier) @type.enum)
(type_identifier) @type
(primitive_type) @type.builtin
(sized_type_specifier) @type.builtin

(call_expression
  function: (identifier) @function.call)
(call_expression
  function: (field_expression
    field: (field_identifier) @function.method.call))
(function_declarator
  declarator: (identifier) @function.declaration)
(preproc_function_def
  name: (identifier) @function.macro)

(comment) @comment
