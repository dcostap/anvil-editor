; Bundled first-party C outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

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
  declarator: [
    (field_identifier) @name
    (pointer_declarator
      declarator: (field_identifier) @name)
    (array_declarator
      declarator: (field_identifier) @name)
  ]) @outline.field

(type_definition
  declarator: (type_identifier) @name) @outline.type

(type_definition
  declarator: (pointer_declarator
    declarator: (type_identifier) @name)) @outline.type
