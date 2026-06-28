; Bundled first-party Odin outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(procedure_declaration
  (identifier) @name) @outline.function

(overloaded_procedure_declaration
  (identifier) @name) @outline.function

(struct_declaration
  (identifier) @name) @outline.struct

(enum_declaration
  (identifier) @name) @outline.enum

(union_declaration
  (identifier) @name) @outline.union

(bit_field_declaration
  (identifier) @name) @outline.struct

(const_type_declaration
  (identifier) @name) @outline.type

(const_declaration
  (identifier) @name) @outline.constant

(variable_declaration
  (identifier) @name) @outline.variable

(package_declaration
  (identifier) @name) @outline.module

(foreign_block
  (identifier) @name) @outline.namespace
