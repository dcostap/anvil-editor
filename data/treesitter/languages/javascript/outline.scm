; Bundled first-party JavaScript outline query.
; Select file variables and class fields. Function-valued variables also match
; the function pattern; the shared extractor keeps the function symbol.

(class_declaration
  name: (identifier) @name) @outline.class

(program
  (function_declaration
    name: (identifier) @name
    parameters: (formal_parameters) @signature.params) @outline.function)

(export_statement
  declaration: (function_declaration
    name: (identifier) @name
    parameters: (formal_parameters) @signature.params) @outline.function)

(program
  (generator_function_declaration
    name: (identifier) @name
    parameters: (formal_parameters) @signature.params) @outline.function)

(export_statement
  declaration: (generator_function_declaration
    name: (identifier) @name
    parameters: (formal_parameters) @signature.params) @outline.function)

(method_definition
  name: (property_identifier) @name
  parameters: (formal_parameters) @signature.params) @outline.method

(field_definition
  property: (property_identifier) @name) @outline.field

(program
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name) @outline.variable))

(program
  (variable_declaration
    (variable_declarator
      name: (identifier) @name) @outline.variable))

(export_statement
  declaration: (lexical_declaration
    (variable_declarator
      name: (identifier) @name) @outline.variable))

(export_statement
  declaration: (variable_declaration
    (variable_declarator
      name: (identifier) @name) @outline.variable))

(program
  (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]) @outline.function))

(program
  (variable_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]) @outline.function))

(export_statement
  declaration: (lexical_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]) @outline.function))

(export_statement
  declaration: (variable_declaration
    (variable_declarator
      name: (identifier) @name
      value: [(arrow_function) (function_expression)]) @outline.function))
