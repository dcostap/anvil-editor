-- mod-version:3
local syntax = require "core.syntax"

-- SQL identifiers are case-insensitive. The explicit case-insensitive keyword
-- patterns also cover mixed-case spellings; the symbols table keeps keyword
-- completion and the ordinary lower/upper-case tokenizer path useful.
local keywords = {
  "ADD", "ALL", "ALTER", "AND", "ANY", "APPLY", "AS", "ASC", "BACKUP",
  "BEGIN", "BETWEEN", "BREAK", "BROWSE", "BULK", "BY", "CASCADE", "CASE",
  "CHECK", "CHECKPOINT", "CLOSE", "CLUSTERED", "COALESCE", "COLLATE",
  "COLUMN", "COMMIT", "CONSTRAINT", "CONTINUE", "CREATE", "CROSS",
  "CURRENT", "DATABASE", "DECLARE", "DEFAULT", "DELETE", "DESC", "DISTINCT",
  "DISTRIBUTED", "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXEC",
  "EXECUTE", "EXISTS", "EXTERNAL", "FETCH", "FIRST", "FOLLOWING", "FOR",
  "FOREIGN", "FROM", "FULL", "FUNCTION", "GO", "GRANT", "GROUP", "HAVING",
  "IDENTITY", "IF", "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO",
  "IS", "JOIN", "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "LOOP",
  "MERGE", "NATURAL", "NOCOUNT", "NONCLUSTERED", "NOT", "NULLS", "OFFSET",
  "ON", "ONLY", "OPEN", "OPTION", "OR", "ORDER", "OUTER", "OUTPUT", "OVER",
  "PARTITION", "PIVOT", "PRECEDING", "PRIMARY", "PROCEDURE", "RAISERROR",
  "RECURSIVE", "REFERENCES", "RESTORE", "RETURN", "RETURNING", "RETURNS",
  "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SAVE", "SCHEMA", "SELECT",
  "SET", "SETOF", "SOME", "TABLE", "THEN", "TO", "TOP", "TRANSACTION",
  "TRIGGER", "TRUNCATE", "TRY", "UNBOUNDED", "UNION", "UNIQUE", "UNNEST",
  "UNPIVOT", "UPDATE", "USE", "USING", "VALUES", "VIEW", "WHEN", "WHERE",
  "WHILE", "WITH",
}

local types = {
  "BIGINT", "BINARY", "BIT", "BLOB", "BOOLEAN", "CHAR", "CHARACTER", "CLOB",
  "DATE", "DATETIME", "DATETIME2", "DATETIMEOFFSET", "DECIMAL", "DOUBLE",
  "FLOAT", "IMAGE", "INT", "INT2", "INT4", "INT8", "INTEGER", "INTERVAL",
  "JSON", "JSONB", "MONEY", "NCHAR", "NTEXT", "NUMERIC", "NVARCHAR", "REAL",
  "ROWVERSION", "SERIAL", "SERIAL2", "SERIAL4", "SERIAL8", "SMALLDATETIME",
  "SMALLINT", "SMALLMONEY", "SQL_VARIANT", "TEXT", "TIME", "TIMESTAMP",
  "TINYINT", "UNIQUEIDENTIFIER", "UUID", "VARBINARY", "VARCHAR", "XML",
}

local literals = {
  "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "FALSE", "LOCALTIME",
  "LOCALTIMESTAMP", "NULL", "TRUE", "UNKNOWN",
}

local function alternation(items)
  return table.concat(items, "|")
end

local symbols = {}
for _, keyword in ipairs(keywords) do
  symbols[keyword] = "keyword"
  symbols[keyword:lower()] = "keyword"
end
for _, value_type in ipairs(types) do
  symbols[value_type] = "keyword2"
  symbols[value_type:lower()] = "keyword2"
end
for _, literal in ipairs(literals) do
  symbols[literal] = "literal"
  symbols[literal:lower()] = "literal"
end

syntax.add {
  name = "SQL",
  files = { "%.sql$", "%.psql$" },
  comment = "--",
  block_comment = { "/*", "*/" },
  patterns = {
    { pattern = "%-%-.*", type = "comment" },
    { pattern = { "/%*", "%*/" }, type = "comment" },

    -- Consume doubled SQL quote escapes before falling back to the multiline
    -- pair rule for dialects that permit strings to cross line boundaries.
    { regex = [['(?:''|[^'\n])*']], type = "string" },
    { pattern = { "'", "'" }, type = "string" },
    { regex = [["(?:""|[^"\n])*"]], type = "string" },
    { pattern = "%b[]", type = "string" },

    { regex = "(?i:\\b(?:" .. alternation(literals) .. ")\\b)", type = "literal" },
    { regex = "(?i:\\b(?:" .. alternation(types) .. ")\\b)", type = "keyword2" },
    { regex = "(?i:\\b(?:" .. alternation(keywords) .. ")\\b)", type = "keyword" },

    { regex = [[-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?]], type = "number" },
    { pattern = "[%+%-=/%*%%<>!~|&@%?$#]", type = "operator" },
    { regex = [[\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()]], type = "function" },
    { pattern = "[%a_][%w_]*", type = "symbol" },
  },
  symbols = symbols,
}
