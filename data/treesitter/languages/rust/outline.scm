; Select file and declaration-list items, not block-local declarations.
; Impl items group methods under the target type name.

(source_file [
  (mod_item name: (identifier) @name) @outline.module
  (struct_item name: (type_identifier) @name) @outline.struct
  (union_item name: (type_identifier) @name) @outline.union
  (enum_item name: (type_identifier) @name) @outline.enum
  (trait_item name: (type_identifier) @name) @outline.interface
  (type_item name: (type_identifier) @name) @outline.type
  (const_item name: (identifier) @name type: (_) @signature) @outline.constant
  (static_item name: (identifier) @name type: (_) @signature) @outline.variable
  (macro_definition name: (identifier) @name) @outline.macro
  (function_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.function
])

(declaration_list [
  (mod_item name: (identifier) @name) @outline.module
  (struct_item name: (type_identifier) @name) @outline.struct
  (union_item name: (type_identifier) @name) @outline.union
  (enum_item name: (type_identifier) @name) @outline.enum
  (trait_item name: (type_identifier) @name) @outline.interface
  (type_item name: (type_identifier) @name) @outline.type
  (associated_type name: (type_identifier) @name) @outline.type
  (const_item name: (identifier) @name type: (_) @signature) @outline.constant
  (static_item name: (identifier) @name type: (_) @signature) @outline.variable
  (macro_definition name: (identifier) @name) @outline.macro
])

(mod_item body: (declaration_list
  (function_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.function))

(foreign_mod_item body: (declaration_list
  (function_signature_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.function))

(impl_item type: [
  (type_identifier) @name
  (scoped_type_identifier name: (type_identifier) @name)
  (generic_type type: [
    (type_identifier) @name
    (scoped_type_identifier name: (type_identifier) @name)
  ])
]) @outline.impl

(impl_item body: (declaration_list
  (function_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.method))

(trait_item body: (declaration_list [
  (function_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.method
  (function_signature_item name: (identifier) @name
    parameters: (parameters) @signature.params
    return_type: (_)? @signature.return) @outline.method
]))

(field_declaration name: (field_identifier) @name type: (_) @signature) @outline.field
(enum_variant name: (identifier) @name) @outline.enum_member
