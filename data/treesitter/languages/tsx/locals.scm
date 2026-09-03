; Scopes

[
  (program)
  (statement_block)
  (function_expression)
  (arrow_function)
  (function_declaration)
  (generator_function)
  (generator_function_declaration)
  (method_definition)
] @scope

; References

(identifier) @reference

; Definitions

(function_declaration name: (identifier) @definition.function)
(generator_function_declaration name: (identifier) @definition.function)
(class_declaration name: (type_identifier) @definition.type)
(variable_declarator name: (identifier) @definition.var)
(required_parameter (identifier) @definition.parameter)
(optional_parameter (identifier) @definition.parameter)
(interface_declaration name: (type_identifier) @definition.type)
(type_alias_declaration name: (type_identifier) @definition.type)
(enum_declaration name: (identifier) @definition.type)
(type_identifier) @reference
