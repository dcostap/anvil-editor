; Bundled first-party TSX outline query.
; Select file variables and class fields. The shared extractor keeps a function
; symbol when a function-valued variable matches both patterns.
; See data/treesitter/languages/README.md for the language review.

(class_declaration
  name: (type_identifier) @name) @outline.class

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

(public_field_definition
  name: (property_identifier) @name) @outline.field

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

(interface_declaration
  name: (type_identifier) @name) @outline.interface

(type_alias_declaration
  name: (type_identifier) @name) @outline.type

(enum_declaration
  name: (identifier) @name) @outline.enum

(enum_body
  name: (property_identifier) @name @outline.enum_member)

(enum_assignment
  name: (property_identifier) @name) @outline.enum_member

(property_signature
  name: (property_identifier) @name) @outline.field

(method_signature
  name: (property_identifier) @name) @outline.method

(abstract_method_signature
  name: (property_identifier) @name) @outline.method
