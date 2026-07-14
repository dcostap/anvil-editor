; Bundled first-party Kotlin outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(class_declaration
  (type_identifier) @name) @outline.class

(object_declaration
  (type_identifier) @name) @outline.class

(companion_object
  (type_identifier) @name) @outline.class

(source_file
  (function_declaration
    (simple_identifier) @name
    (function_value_parameters) @signature.params) @outline.function)

(class_body
  (function_declaration
    (simple_identifier) @name
    (function_value_parameters) @signature.params) @outline.method)

(source_file
  (property_declaration
    (variable_declaration
      (simple_identifier) @name)) @outline.variable)

(class_body
  (property_declaration
    (variable_declaration
      (simple_identifier) @name)) @outline.property)

(class_declaration
  (primary_constructor
    (class_parameter
      (binding_pattern_kind)
      (simple_identifier) @name
      (_) @signature) @outline.property))

(type_alias
  (type_identifier) @name) @outline.type

(enum_entry
  (simple_identifier) @name) @outline.enum_member
