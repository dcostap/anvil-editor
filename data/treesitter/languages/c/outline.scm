; Bundled first-party C outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name)) @outline.function

(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name))) @outline.function

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

(type_definition
  declarator: (type_identifier) @name) @outline.type

(type_definition
  declarator: (pointer_declarator
    declarator: (type_identifier) @name)) @outline.type
