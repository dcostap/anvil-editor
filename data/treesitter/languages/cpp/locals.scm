; Current-document local syntactic symbol fallback for C++.
; This query intentionally avoids semantic claims about overloads, templates,
; includes, macros, or type resolution. Consumers must treat results as syntactic
; hints only.

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @definition.function))

(function_definition
  declarator: (function_declarator
    declarator: (field_identifier) @definition.method))

(function_definition
  declarator: (function_declarator
    declarator: (qualified_identifier
      name: (_) @definition.method)))

(function_declarator
  declarator: (identifier) @definition.function)

(function_declarator
  declarator: (field_identifier) @definition.method)

(parameter_declaration
  declarator: (identifier) @definition.parameter)

(parameter_declaration
  declarator: (pointer_declarator
    declarator: (identifier) @definition.parameter))

(parameter_declaration
  declarator: (reference_declarator
    (identifier) @definition.parameter))

(declaration
  declarator: (identifier) @definition.var)

(init_declarator
  declarator: (identifier) @definition.var)

(init_declarator
  declarator: (pointer_declarator
    declarator: (identifier) @definition.var))

(type_definition
  declarator: (type_identifier) @definition.type)

(identifier) @reference
(field_identifier) @reference
