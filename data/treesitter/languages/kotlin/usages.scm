; Bundled first-party Kotlin project usage query.
; Non-declaration occurrences are captured as @usage. Declaration/name sites
; keep @definition.* so callers can exclude declarations for reference-like UI.

; Usages

(simple_identifier) @usage
(type_identifier) @usage

; Declarations

(package_header (identifier) @definition.namespace)

(import_header
  (identifier) @definition.namespace)

(class_declaration
  (type_identifier) @definition.type)

(object_declaration
  (type_identifier) @definition.type)

(companion_object
  (type_identifier) @definition.type)

(function_declaration
  (simple_identifier) @definition.function)

(property_declaration
  (variable_declaration
    (simple_identifier) @definition.var))

(variable_declaration
  (simple_identifier) @definition.var)

(parameter
  (simple_identifier) @definition.parameter)

(parameter_with_optional_type
  (simple_identifier) @definition.parameter)

(class_parameter
  (simple_identifier) @definition.parameter)

(lambda_literal
  (lambda_parameters
    (variable_declaration
      (simple_identifier) @definition.parameter)))

(type_alias
  (type_identifier) @definition.type)

(enum_entry
  (simple_identifier) @definition.enum)
