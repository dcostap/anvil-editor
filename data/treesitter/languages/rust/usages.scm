; Syntactic names only. This query does not resolve Rust paths or macro expansion.

(identifier) @reference
(type_identifier) @reference
(field_identifier) @reference
(shorthand_field_identifier) @reference

(mod_item name: (identifier) @definition.namespace)
(struct_item name: (type_identifier) @definition.type)
(union_item name: (type_identifier) @definition.type)
(enum_item name: (type_identifier) @definition.type)
(trait_item name: (type_identifier) @definition.type)
(type_item name: (type_identifier) @definition.type)
(associated_type name: (type_identifier) @definition.type)
(type_parameter name: (type_identifier) @definition.type)
(const_parameter name: (identifier) @definition.parameter)
(field_declaration name: (field_identifier) @definition.field)
(enum_variant name: (identifier) @definition.enum)
(const_item name: (identifier) @definition.constant)
(static_item name: (identifier) @definition.var)
(function_item name: (identifier) @definition.function)
(function_signature_item name: (identifier) @definition.function)
(macro_definition name: (identifier) @definition.macro)
(parameter pattern: (identifier) @definition.parameter)
(let_declaration pattern: (identifier) @definition.var)
(use_as_clause alias: (identifier) @definition.var)
