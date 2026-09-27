; Bundled first-party C outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Anvil groups captures by Tree-sitter match id.
; @name.declarator follows the C declarator to its name in the shared extractor.
; See data/treesitter/languages/README.md.

(translation_unit
  (declaration
    declarator: (_) @name.declarator) @outline.variable)

(translation_unit
  (declaration
    declarator: (function_declarator
      declarator: (identifier) @name
      parameters: (parameter_list) @signature.params)) @outline.function)

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name
    parameters: (parameter_list) @signature.params)) @outline.function

(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name
      parameters: (parameter_list) @signature.params))) @outline.function

(preproc_function_def
  name: (identifier) @name) @outline.macro

(preproc_def
  name: (identifier) @name) @outline.macro

(struct_specifier
  name: (type_identifier) @name
  body: (field_declaration_list)) @outline.struct

(union_specifier
  name: (type_identifier) @name
  body: (field_declaration_list)) @outline.union

(enum_specifier
  name: (type_identifier) @name
  body: (enumerator_list)) @outline.enum

(enumerator
  name: (identifier) @name
  value: (expression)? @signature) @outline.enum_member

(field_declaration
  type: (_) @signature
  declarator: (_) @name.declarator) @outline.field

(type_definition
  declarator: (_) @name.declarator) @outline.type
