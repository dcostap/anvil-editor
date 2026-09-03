; Bundled first-party JavaScript outline query.

(class_declaration
  name: (type_identifier) @name) @outline.class

(function_declaration
  name: (identifier) @name
  parameters: (formal_parameters) @signature.params) @outline.function

(generator_function_declaration
  name: (identifier) @name
  parameters: (formal_parameters) @signature.params) @outline.function

(method_definition
  name: (property_identifier) @name
  parameters: (formal_parameters) @signature.params) @outline.method

(program
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)])) @outline.function)

(program
  (variable_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)])) @outline.function)

(interface_declaration
  name: (type_identifier) @name) @outline.interface

(type_alias_declaration
  name: (type_identifier) @name) @outline.type

(enum_declaration
  name: (identifier) @name) @outline.enum

(method_signature
  name: (property_identifier) @name) @outline.method

(abstract_method_signature
  name: (property_identifier) @name) @outline.method
