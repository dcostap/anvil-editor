; Current-document local syntactic symbol fallback for C.
; This query is intentionally conservative: it identifies local declarations,
; parameters, function declarators, and identifier references. Consumers must treat
; results as syntactic hints, not semantic C truth.

(function_definition
  declarator: (function_declarator
    declarator: (identifier) @definition.function))

(function_declarator
  declarator: (identifier) @definition.function)

(parameter_declaration
  declarator: (identifier) @definition.parameter)

(parameter_declaration
  declarator: (pointer_declarator
    declarator: (identifier) @definition.parameter))

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
