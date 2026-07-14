; Bundled first-party Odin outline query.
; Each pattern captures one outline item as @outline.<kind> and its display name
; as @name. Lua groups captures by Tree-sitter match id.

(procedure_declaration
  (identifier) @name
  (procedure) @signature) @outline.function

(overloaded_procedure_declaration
  (identifier) @name) @outline.function

(struct_declaration
  (identifier) @name) @outline.struct

(struct_declaration
  (field
    (identifier) @name
    (type) @signature) @outline.field)

(enum_declaration
  (identifier) @name
  "::") @outline.enum

; The Odin grammar exposes enum names and values as direct children of the
; declaration rather than wrapping each entry in a named member node. Capture
; the member identifier itself as the outline item so containment can attach it
; to the enum, and keep an explicit value as its signature/detail.
(enum_declaration
  "{"
  (identifier) @name @outline.enum_member
  .
  "="
  .
  (expression) @signature)

(enum_declaration
  "{"
  (identifier) @name @outline.enum_member
  .
  ["," "}"])

(union_declaration
  (identifier) @name) @outline.union

(bit_field_declaration
  (identifier) @name
  "::") @outline.struct

(bit_field_declaration
  "{"
  (identifier) @name @outline.field
  .
  ":"
  .
  (type) @signature)

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
