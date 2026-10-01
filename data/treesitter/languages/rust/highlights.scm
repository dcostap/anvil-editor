; Rust syntax colors. Node names follow tree-sitter-rust 0.24.2.

(identifier) @variable
(type_identifier) @type
(primitive_type) @type.builtin
(field_identifier) @variable.field
(shorthand_field_identifier) @variable.field
(self) @variable.builtin
(lifetime (identifier) @function.label
  (#set! priority 1))

(mod_item name: (identifier) @type.namespace)
(const_item name: (identifier) @constant)
(static_item name: (identifier) @variable)
(enum_variant name: (identifier) @constructor)
(parameter pattern: (identifier) @variable.parameter)

(function_item name: (identifier) @function)
(function_signature_item name: (identifier) @function)
(impl_item body: (declaration_list
  (function_item name: (identifier) @function.method)))
(trait_item body: (declaration_list [
  (function_item name: (identifier) @function.method)
  (function_signature_item name: (identifier) @function.method)
]))

(call_expression function: (identifier) @function)
(call_expression function: (scoped_identifier name: (identifier) @function))
(call_expression function: (field_expression field: (field_identifier) @function.method))
(generic_function function: (identifier) @function)
(generic_function function: (scoped_identifier name: (identifier) @function))
(generic_function function: (field_expression field: (field_identifier) @function.method))
(macro_definition name: (identifier) @function.macro)
(macro_invocation macro: (identifier) @function.macro)
(macro_invocation macro: (scoped_identifier name: (identifier) @function.macro))
(metavariable) @variable.parameter

[(line_comment) (block_comment)] @comment
[(string_literal) (raw_string_literal) (char_literal)] @string
(escape_sequence) @string.escape
[(integer_literal) (float_literal)] @number
(boolean_literal) @constant.builtin
[(attribute_item) (inner_attribute_item)] @annotation

[
  "as" "async" "await" "break" "const" "continue" "default" "dyn" "else"
  "enum" "extern" "fn" "for" "gen" "if" "impl" "in" "let" "loop"
  "macro_rules!" "match" "mod" "move" "pub" "raw" "ref" "return" "static"
  "struct" "trait" "type" "union" "unsafe" "use" "where" "while" "yield"
  (crate) (super) (mutable_specifier)
] @keyword

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["::" ":" "." "," ";"] @punctuation.delimiter
[
  "+" "-" "*" "/" "%" "&" "|" "^" "!" "=" "==" "!=" "<" ">"
  "<=" ">=" "&&" "||" "<<" ">>" "+=" "-=" "*=" "/=" "%=" "&=" "|="
  "^=" "<<=" ">>=" "->" "=>" "?" ".." "..="
] @operator
