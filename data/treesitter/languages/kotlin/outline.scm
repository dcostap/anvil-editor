; Bundled first-party Kotlin outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(class_declaration
  (type_identifier) @name) @outline.class

(object_declaration
  (type_identifier) @name) @outline.class

(companion_object
  (type_identifier) @name) @outline.class

(function_declaration
  (simple_identifier) @name
  (function_value_parameters) @signature.params) @outline.function

(property_declaration
  (variable_declaration
    (simple_identifier) @name)) @outline.variable

(type_alias
  (type_identifier) @name) @outline.type

(enum_entry
  (simple_identifier) @name) @outline.enum
