; Bundled first-party C++ outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Anvil groups captures by Tree-sitter match id.
; The declarator patterns below list shapes, not arbitrary wrapper depth.
; See data/treesitter/languages/README.md before extending them.

(translation_unit
  (declaration
    declarator: [
      (identifier) @name
      (pointer_declarator declarator: (identifier) @name)
      (reference_declarator (identifier) @name)
      (array_declarator declarator: (identifier) @name)
    ]) @outline.variable)

(translation_unit
  (declaration
    declarator: (init_declarator
      declarator: [
        (identifier) @name
        (pointer_declarator declarator: (identifier) @name)
        (reference_declarator (identifier) @name)
        (array_declarator declarator: (identifier) @name)
      ])) @outline.variable)

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
    (pointer_declarator
      declarator: (pointer_declarator
        declarator: (field_identifier) @name))
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
  declarator: (pointer_declarator
    declarator: (function_declarator
      declarator: (qualified_identifier
        name: (_) @name)
      parameters: (parameter_list) @signature.params))) @outline.method

(function_definition
  declarator: (reference_declarator
    (function_declarator
      declarator: (identifier) @name
      parameters: (parameter_list) @signature.params))) @outline.function

(function_definition
  declarator: (reference_declarator
    (function_declarator
      declarator: (qualified_identifier
        name: (_) @name)
      parameters: (parameter_list) @signature.params))) @outline.method

(type_definition
  declarator: (type_identifier) @name) @outline.type

(type_definition
  declarator: (qualified_identifier
    name: (_) @name)) @outline.type
