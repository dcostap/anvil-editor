; Bundled first-party JavaScript outline query.

(class_declaration
  name: (identifier) @name) @outline.class

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
