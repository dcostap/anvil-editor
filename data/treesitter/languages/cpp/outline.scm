; Bundled first-party C++ outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(namespace_definition
  name: (_) @name) @outline.namespace

(class_specifier
  name: (_) @name
  body: (field_declaration_list)) @outline.class

(struct_specifier
  name: (_) @name
  body: (field_declaration_list)) @outline.struct

(union_specifier
  name: (_) @name
  body: (field_declaration_list)) @outline.union

(enum_specifier
  name: (_) @name
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
    (reference_declarator
      (field_identifier) @name)
    (array_declarator
      declarator: (field_identifier) @name)
  ]) @outline.field

(field_declaration
  declarator: (function_declarator
    declarator: (field_identifier) @name
    parameters: (parameter_list) @signature.params)) @outline.method

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @name
    parameters: (parameter_list) @signature.params)) @outline.function

(function_definition
  declarator: (function_declarator
    declarator: (field_identifier) @name
    parameters: (parameter_list) @signature.params)) @outline.method

(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (_) @name)
    parameters: (parameter_list) @signature.params)) @outline.method

(function_definition
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (identifier) @name
      parameters: (parameter_list) @signature.params))) @outline.function

(function_definition
  declarator: (reference_declarator
    (function_declarator
      declarator: (identifier) @name
      parameters: (parameter_list) @signature.params))) @outline.function

(type_definition
  declarator: (type_identifier) @name) @outline.type

(type_definition
  declarator: (qualified_identifier
    name: (_) @name)) @outline.type
