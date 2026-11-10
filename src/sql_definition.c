#include "sql_definition.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SOURCE_LIMIT (512 * 1024)
typedef struct { char *text; size_t length, capacity; int failed; } Text;
static void append_n(Text *s, const char *text, size_t n) {
  if (s->failed || !text || n > SOURCE_LIMIT - s->length) { s->failed = 1; return; }
  if (s->length + n + 1 > s->capacity) {
    size_t cap = (s->length + n + 1) * 2;
    char *p = realloc(s->text, cap);
    if (!p) { s->failed = 1; return; }
    s->text = p; s->capacity = cap;
  }
  memcpy(s->text + s->length, text, n); s->length += n; s->text[s->length] = 0;
}
static void add(Text *s, const char *text) { if (text) append_n(s, text, strlen(text)); else s->failed = 1; }
static char *take(Text *s) {
  char *result = s->text;
  if (s->failed) { free(result); result = NULL; }
  memset(s, 0, sizeof(*s)); return result;
}
static void quoted(Text *s, const char *name, int literal) {
  add(s, literal ? "N'" : "[");
  for (const char *p = name; *p; ++p) {
    append_n(s, p, 1);
    if (*p == (literal ? '\'' : ']')) append_n(s, p, 1);
  }
  add(s, literal ? "'" : "]");
}
static size_t skip(const char *s, size_t n, size_t p) {
  for (;;) {
    while (p < n && isspace((unsigned char)s[p])) ++p;
    if (p + 1 < n && s[p] == '-' && s[p + 1] == '-') {
      while (p < n && s[p] != '\n') ++p;
    } else if (p + 1 < n && s[p] == '/' && s[p + 1] == '*') {
      int depth = 1; p += 2;
      while (p + 1 < n && depth) {
        if (s[p] == '/' && s[p + 1] == '*') { ++depth; p += 2; }
        else if (s[p] == '*' && s[p + 1] == '/') { --depth; p += 2; }
        else ++p;
      }
      if (depth) return n;
    } else return p;
  }
}
static int word(const char *s, size_t n, size_t p, const char *w) {
  size_t len = strlen(w);
  if (len > n - p) return 0;
  for (size_t i = 0; i < len; ++i) if (toupper((unsigned char)s[p + i]) != w[i]) return 0;
  return p + len == n || (!isalnum((unsigned char)s[p + len]) && s[p + len] != '_');
}
static int valid_utf8(const char *s, size_t n) {
  for (size_t i = 0; i < n;) {
    unsigned char first = (unsigned char)s[i++];
    if (first < 0x80) continue;
    unsigned count = first >= 0xc2 && first <= 0xdf ? 1 : first >= 0xe0 && first <= 0xef ? 2 : first >= 0xf0 && first <= 0xf4 ? 3 : 0;
    if (!count || count > n-i) return 0;
    unsigned char next = (unsigned char)s[i];
    if ((first==0xe0 && next<0xa0) || (first==0xed && next>=0xa0) || (first==0xf0 && next<0x90) || (first==0xf4 && next>=0x90)) return 0;
    for (unsigned j=0; j<count; ++j) if (((unsigned char)s[i++] & 0xc0) != 0x80) return 0;
  }
  return 1;
}
static size_t identifier_end(const char *s, size_t n, size_t p) {
  if (p==n) return p;
  if (s[p]=='[' || s[p]=='"') {
    char close=s[p++]=='[' ? ']' : '"';
    while (p<n) {
      if (s[p++]!=close) continue;
      if (p<n && s[p]==close) ++p; else return p;
    }
    return 0;
  }
  while (p<n && ((unsigned char)s[p]>=128 || isalnum((unsigned char)s[p]) || s[p]=='_' || s[p]=='#' || s[p]=='@' || s[p]=='$')) ++p;
  return p;
}
static char *module_script(const char *s, size_t n, int alter, const char *schema, const char *name) {
  if (!s || n > SOURCE_LIMIT || memchr(s, 0, n) || !valid_utf8(s,n)) return NULL;
  size_t start = skip(s, n, 0), end;
  if (word(s, n, start, "CREATE")) {
    end = start + 6;
    size_t p = skip(s, n, end);
    if (word(s, n, p, "OR")) {
      p = skip(s, n, p + 2);
      if (!word(s, n, p, "ALTER")) return NULL;
      end = p + 5;
    }
  } else if (word(s, n, start, "ALTER")) end = start + 5;
  else return NULL;
  size_t p = skip(s, n, end);
  if (!word(s, n, p, "VIEW") && !word(s, n, p, "PROC") && !word(s, n, p, "PROCEDURE") &&
      !word(s, n, p, "FUNCTION") && !word(s, n, p, "TRIGGER")) return NULL;
  Text out = {0}; append_n(&out, s, start); add(&out, alter ? "ALTER" : "CREATE");
  if (schema && name) {
    while (p<n && isalpha((unsigned char)s[p])) ++p;
    size_t name_start=skip(s,n,p), name_end=identifier_end(s,n,name_start);
    if (name_end<=name_start) { free(out.text); return NULL; }
    p=skip(s,n,name_end);
    if (p<n && s[p]=='.') {
      p=skip(s,n,p+1); name_end=identifier_end(s,n,p);
      if (name_end<=p) { free(out.text); return NULL; }
      p=skip(s,n,name_end);
      if (p<n && s[p]=='.') { free(out.text); return NULL; }
    }
    append_n(&out,s+end,name_start-end); quoted(&out,schema,0); add(&out,"."); quoted(&out,name,0);
    append_n(&out,s+name_end,n-name_end);
  } else append_n(&out,s+end,n-end);
  return take(&out);
}
char *sql_module_script(const char *s, size_t n, int alter) { return module_script(s,n,alter,NULL,NULL); }
void sql_definition_free(SqlDefinition *out) {
  free(out->source_sql);
  free(out->create_sql); free(out->alter_sql); free(out->select_sql);
  free(out->insert_sql); free(out->update_sql); free(out->delete_sql);
  memset(out, 0, sizeof(*out));
}

/* Each result is plain catalog data. Quoted names are values, never executable identifiers.
 * Module text uses bounded chunks so the normal result cell limit never cuts its source. */
static const char *catalog_query =
  "; SELECT RTRIM(o.type), QUOTENAME(s.name)+'.'+QUOTENAME(o.name), DATALENGTH(m.definition), "
  "m.uses_ansi_nulls, m.uses_quoted_identifier, "
  "CASE WHEN t.temporal_type<>0 OR t.is_memory_optimized=1 OR t.is_filetable=1 OR t.is_node=1 OR t.is_edge=1 OR t.is_external=1 "
  "OR EXISTS(SELECT 1 FROM sys.columns c WHERE c.object_id=@id AND (c.is_filestream=1 OR c.is_sparse=1 OR c.is_column_set=1 "
  "OR c.generated_always_type<>0 OR c.encryption_type IS NOT NULL OR c.is_masked=1 OR c.xml_collection_id<>0 OR c.rule_object_id<>0 "
  "OR (c.default_object_id<>0 AND NOT EXISTS(SELECT 1 FROM sys.default_constraints d WHERE d.object_id=c.default_object_id)))) "
  "OR EXISTS(SELECT 1 FROM sys.indexes i WHERE i.object_id=@id AND (i.type NOT IN(0,1,2) OR i.is_disabled=1 OR i.is_hypothetical=1)) "
  "THEN 1 ELSE 0 END, HAS_PERMS_BY_NAME(QUOTENAME(s.name)+'.'+QUOTENAME(o.name),'OBJECT','VIEW DEFINITION') "
  "FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id LEFT JOIN sys.sql_modules m ON m.object_id=o.object_id "
  "LEFT JOIN sys.tables t ON t.object_id=o.object_id WHERE o.object_id=@id; "
  "WITH n AS (SELECT 0 AS n UNION ALL SELECT n+1 FROM n WHERE n<127) "
  "SELECT SUBSTRING(m.definition COLLATE Latin1_General_100_CI_AS_SC,n.n*4000+1,4000) FROM sys.sql_modules m CROSS JOIN n "
  "WHERE m.object_id=@id AND n.n*4000<DATALENGTH(m.definition)/2 ORDER BY n.n OPTION(MAXRECURSION 128); "
  "SELECT c.name, QUOTENAME(c.name) COLLATE DATABASE_DEFAULT+' '+ CASE WHEN cc.definition IS NOT NULL THEN 'AS '+cc.definition+CASE WHEN cc.is_persisted=1 THEN ' PERSISTED'+CASE WHEN c.is_nullable=0 THEN ' NOT NULL' ELSE '' END ELSE '' END "
  "ELSE CASE WHEN ty.is_user_defined=1 THEN QUOTENAME(SCHEMA_NAME(ty.schema_id))+'.'+QUOTENAME(ty.name) ELSE ty.name+ "
  "CASE WHEN ty.name IN('varchar','char','varbinary','binary','nvarchar','nchar') THEN '('+CASE WHEN c.max_length=-1 THEN 'max' "
  "ELSE CONVERT(varchar(10),CASE WHEN ty.name IN('nvarchar','nchar') THEN c.max_length/2 ELSE c.max_length END) END+')' "
  "WHEN ty.name IN('decimal','numeric') THEN '('+CONVERT(varchar(10),c.precision)+','+CONVERT(varchar(10),c.scale)+')' "
  "WHEN ty.name IN('time','datetime2','datetimeoffset') THEN '('+CONVERT(varchar(10),c.scale)+')' ELSE '' END END "
  "+CASE WHEN c.collation_name IS NOT NULL THEN ' COLLATE '+c.collation_name ELSE '' END "
  "+CASE WHEN ic.column_id IS NOT NULL THEN ' IDENTITY('+CONVERT(varchar(40),ic.seed_value)+','+CONVERT(varchar(40),ic.increment_value)+')' "
  "+CASE WHEN ic.is_not_for_replication=1 THEN ' NOT FOR REPLICATION' ELSE '' END ELSE '' END "
  "+CASE WHEN c.is_rowguidcol=1 THEN ' ROWGUIDCOL' ELSE '' END + CASE WHEN c.is_nullable=1 THEN ' NULL' ELSE ' NOT NULL' END "
  "+CASE WHEN dc.definition IS NOT NULL THEN ' CONSTRAINT '+QUOTENAME(dc.name)+' DEFAULT '+dc.definition ELSE '' END END, "
  "CASE WHEN c.is_identity=0 AND c.is_computed=0 AND c.system_type_id<>189 AND c.generated_always_type=0 THEN 1 ELSE 0 END, "
  "CASE WHEN EXISTS(SELECT 1 FROM sys.indexes i JOIN sys.index_columns k ON k.object_id=i.object_id AND k.index_id=i.index_id "
  "WHERE i.object_id=c.object_id AND i.is_primary_key=1 AND k.column_id=c.column_id) THEN 1 ELSE 0 END "
  "FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id "
  "LEFT JOIN sys.computed_columns cc ON cc.object_id=c.object_id AND cc.column_id=c.column_id "
  "LEFT JOIN sys.identity_columns ic ON ic.object_id=c.object_id AND ic.column_id=c.column_id "
  "LEFT JOIN sys.default_constraints dc ON dc.object_id=c.default_object_id WHERE c.object_id=@id ORDER BY c.column_id; "
  "SELECT definition FROM (SELECT k.name, 'CONSTRAINT '+QUOTENAME(k.name) COLLATE DATABASE_DEFAULT+' '+CASE WHEN k.type='PK' THEN 'PRIMARY KEY ' ELSE 'UNIQUE ' END "
  "+CASE WHEN i.type=1 THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END+' ('+STUFF((SELECT ', '+QUOTENAME(c.name)+CASE WHEN x.is_descending_key=1 THEN ' DESC' ELSE ' ASC' END "
  "FROM sys.index_columns x JOIN sys.columns c ON c.object_id=x.object_id AND c.column_id=x.column_id "
  "WHERE x.object_id=k.parent_object_id AND x.index_id=k.unique_index_id AND x.key_ordinal>0 ORDER BY x.key_ordinal "
  "FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,2,'')+')' AS definition "
  "FROM sys.key_constraints k JOIN sys.indexes i ON i.object_id=k.parent_object_id AND i.index_id=k.unique_index_id WHERE k.parent_object_id=@id "
  "UNION ALL SELECT c.name,'CONSTRAINT '+QUOTENAME(c.name) COLLATE DATABASE_DEFAULT+' CHECK '+CASE WHEN c.is_not_for_replication=1 THEN 'NOT FOR REPLICATION ' ELSE '' END+c.definition "
  "FROM sys.check_constraints c WHERE c.parent_object_id=@id "
  "UNION ALL SELECT f.name,'CONSTRAINT '+QUOTENAME(f.name) COLLATE DATABASE_DEFAULT+' FOREIGN KEY ('+STUFF((SELECT ', '+QUOTENAME(COL_NAME(x.parent_object_id,x.parent_column_id)) "
  "FROM sys.foreign_key_columns x WHERE x.constraint_object_id=f.object_id ORDER BY x.constraint_column_id FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,2,'') +"
  "') REFERENCES '+QUOTENAME(OBJECT_SCHEMA_NAME(f.referenced_object_id))+'.'+QUOTENAME(OBJECT_NAME(f.referenced_object_id))+' ('+ "
  "STUFF((SELECT ', '+QUOTENAME(COL_NAME(x.referenced_object_id,x.referenced_column_id)) FROM sys.foreign_key_columns x WHERE x.constraint_object_id=f.object_id "
  "ORDER BY x.constraint_column_id FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,2,'')+') ON DELETE '+REPLACE(f.delete_referential_action_desc,'_',' ') "
  "+' ON UPDATE '+REPLACE(f.update_referential_action_desc,'_',' ')+CASE WHEN f.is_not_for_replication=1 THEN ' NOT FOR REPLICATION' ELSE '' END "
  "FROM sys.foreign_keys f WHERE f.parent_object_id=@id) AS definitions ORDER BY name; "
  "SELECT 'CREATE '+CASE WHEN i.is_unique=1 THEN 'UNIQUE ' ELSE '' END+CASE WHEN i.type=1 THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END+' INDEX '+QUOTENAME(i.name) COLLATE DATABASE_DEFAULT "
  "+' ON '+QUOTENAME(OBJECT_SCHEMA_NAME(@id))+'.'+QUOTENAME(OBJECT_NAME(@id))+' ('+ "
  "STUFF((SELECT ', '+QUOTENAME(COL_NAME(x.object_id,x.column_id))+CASE WHEN x.is_descending_key=1 THEN ' DESC' ELSE ' ASC' END "
  "FROM sys.index_columns x WHERE x.object_id=i.object_id AND x.index_id=i.index_id AND x.key_ordinal>0 ORDER BY x.key_ordinal "
  "FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,2,'')+')'+ "
  "COALESCE(' INCLUDE ('+STUFF((SELECT ', '+QUOTENAME(COL_NAME(x.object_id,x.column_id)) FROM sys.index_columns x "
  "WHERE x.object_id=i.object_id AND x.index_id=i.index_id AND x.is_included_column=1 ORDER BY x.index_column_id "
  "FOR XML PATH(''),TYPE).value('.','nvarchar(max)'),1,2,'')+')','')+COALESCE(' WHERE '+i.filter_definition,'')+';' "
  "FROM sys.indexes i WHERE i.object_id=@id AND i.type IN(1,2) AND i.is_primary_key=0 AND i.is_unique_constraint=0 ORDER BY i.index_id; "
  "SELECT QUOTENAME(name) FROM sys.check_constraints WHERE parent_object_id=@id AND (is_disabled=1 OR is_not_trusted=1) "
  "UNION ALL SELECT QUOTENAME(name) FROM sys.foreign_keys WHERE parent_object_id=@id AND (is_disabled=1 OR is_not_trusted=1);";

static const char *value(SqlQueryTable *t, size_t row, size_t col) {
  if (row >= t->row_count || col >= t->column_count) return NULL;
  return t->cells[row * t->column_count + col].text;
}
static int is_one(const char *s) { return s && !strcmp(s, "1"); }

int sql_definition_read(const SqlServerOptions *options, const char *schema, const char *name,
                        SqlQueryCancelled cancelled, void *context, SqlDefinition *out) {
  memset(out, 0, sizeof(*out));
  if (!schema || !*schema || !name || !*name || strlen(schema)>512 || strlen(name)>512) {
    snprintf(out->error, sizeof(out->error), "Invalid database object name."); return 0;
  }
  Text query = {0}, source = {0}, select = {0}, insert = {0}, update = {0}, del = {0};
  SqlQueryResult rows = {0};
  add(&query, "DECLARE @id int=(SELECT o.object_id FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE s.name=");
  quoted(&query, schema, 1); add(&query, " AND o.name="); quoted(&query, name, 1); add(&query, ")"); add(&query, catalog_query);
  int ok = !query.failed && sql_query_read(options, query.text, query.length, cancelled, context, &rows);
  if (!ok) { snprintf(out->error, sizeof(out->error), "%s", rows.cancelled ? "Definition read cancelled." : rows.error); goto done; }
  if (rows.count != 6 || rows.limited) { snprintf(out->error, sizeof(out->error), "Incomplete definition metadata."); goto done; }
  for (size_t i=0; i<rows.count; ++i) if (rows.tables[i].truncated) {
    snprintf(out->error, sizeof(out->error), "Definition metadata exceeds its size limit."); goto done;
  }
  for (size_t i=0; i<rows.count; ++i) {
    SqlQueryTable *t=&rows.tables[i];
    for (size_t j=0; j<t->row_count*t->column_count; ++j) {
      SqlQueryCell *cell=&t->cells[j];
      if (cell->text && memchr(cell->text,0,cell->length)) {
        snprintf(out->error,sizeof(out->error),"Definition metadata contains a NUL character."); goto done;
      }
    }
  }
  const char *kind = value(&rows.tables[0],0,0), *qualified = value(&rows.tables[0],0,1);
  if (!kind || !qualified || !is_one(value(&rows.tables[0],0,6))) {
    snprintf(out->error, sizeof(out->error), "Object not found or VIEW DEFINITION permission is missing."); goto done;
  }
  int table = !strcmp(kind,"U"), view = !strcmp(kind,"V");
  if (!table && !view && strcmp(kind,"P") && strcmp(kind,"FN") && strcmp(kind,"IF") && strcmp(kind,"TF")) {
    snprintf(out->error, sizeof(out->error), "This database object has no supported SQL definition."); goto done;
  }
  if (table && is_one(value(&rows.tables[0],0,5))) {
    snprintf(out->error, sizeof(out->error), "This table uses features that Anvil cannot script completely."); goto done;
  }
  SqlQueryTable *columns = &rows.tables[2];
  if ((table || view) && !columns->row_count) {
    snprintf(out->error,sizeof(out->error),"Column metadata is unavailable."); goto done;
  }
  if (table) {
    add(&source, "-- Table schema and indexes. Storage options, triggers and permissions are not included.\nCREATE TABLE ");
    add(&source, qualified); add(&source, " (\n");
    for (size_t i=0; i<columns->row_count; ++i) {
      if (i) add(&source, ",\n");
      add(&source, "  "); add(&source, value(columns,i,1));
    }
    for (size_t i=0; i<rows.tables[3].row_count; ++i) {
      add(&source, ",\n  "); add(&source, value(&rows.tables[3],i,0));
    }
    add(&source, "\n);\n");
    for (size_t i=0; i<rows.tables[4].row_count; ++i) { add(&source, value(&rows.tables[4],i,0)); add(&source, "\n"); }
    /* Disabled/untrusted constraints need more than a CREATE declaration. Refuse rather than change their meaning. */
    if (rows.tables[5].row_count) {
      snprintf(out->error, sizeof(out->error), "This table has disabled or untrusted constraints. Complete scripting is unavailable."); goto done;
    }
    out->create_sql = take(&source);
    add(&source,out->create_sql); out->source_sql=take(&source);
  } else {
    const char *bytes = value(&rows.tables[0],0,2);
    if (!bytes || strtoul(bytes,NULL,10)>SOURCE_LIMIT || !rows.tables[1].row_count) {
      snprintf(out->error, sizeof(out->error), "Module source is encrypted, unavailable, or too large."); goto done;
    }
    for (size_t i=0; i<rows.tables[1].row_count; ++i) add(&source,value(&rows.tables[1],i,0));
    if (source.failed) goto done;
    out->create_sql = module_script(source.text, source.length, 0, schema, name);
    out->alter_sql = module_script(source.text, source.length, 1, schema, name);
    out->source_sql = take(&source);
    /* These flags change parsing. Do not offer a script that would use different settings. */
    if (!is_one(value(&rows.tables[0],0,3)) || !is_one(value(&rows.tables[0],0,4))) {
      free(out->create_sql); out->create_sql=NULL; free(out->alter_sql); out->alter_sql=NULL;
      Text note={0}; add(&note,"-- Module settings: ANSI_NULLS "); add(&note,is_one(value(&rows.tables[0],0,3)) ? "ON" : "OFF");
      add(&note,", QUOTED_IDENTIFIER "); add(&note,is_one(value(&rows.tables[0],0,4)) ? "ON" : "OFF");
      add(&note,". Set these explicitly before executing selected source.\n"); add(&note,out->source_sql);
      free(out->source_sql); out->source_sql=take(&note);
    }
  }
  if (table || view) {
    add(&select,"SELECT ");
    for (size_t i=0; i<columns->row_count; ++i) {
      if (i) add(&select,", ");
      quoted(&select,value(columns,i,0),0);
    }
    add(&select,"\nFROM "); add(&select,qualified); add(&select,";\n"); out->select_sql=take(&select);
  }
  if (table) {
    add(&insert,"-- Replace the NULL values before running.\nINSERT INTO "); add(&insert,qualified);
    size_t writable=0, assignments=0;
    for (size_t i=0; i<columns->row_count; ++i) if (is_one(value(columns,i,2))) {
      add(&insert,writable++ ? ", " : " ("); quoted(&insert,value(columns,i,0),0);
    }
    if (!writable) add(&insert," DEFAULT VALUES;\n");
    else {
      add(&insert,")\nVALUES (");
      for (size_t i=0; i<writable; ++i) add(&insert,i ? ", NULL" : "NULL");
      add(&insert,");\n");
    }
    add(&update,"-- Set the values and replace the false predicate before running.\nUPDATE "); add(&update,qualified);
    for (size_t i=0; i<columns->row_count; ++i) if (is_one(value(columns,i,2)) && !is_one(value(columns,i,3))) {
      add(&update,assignments++ ? ",\n    " : "\nSET "); quoted(&update,value(columns,i,0),0); add(&update," = NULL");
    }
    add(&update,"\nWHERE 1 = 0;\n");
    add(&del,"-- Replace the false predicate before running.\nDELETE FROM "); add(&del,qualified); add(&del,"\nWHERE 1 = 0;\n");
    out->insert_sql=take(&insert); if (assignments) out->update_sql=take(&update); out->delete_sql=take(&del);
  }
  if (!out->source_sql) snprintf(out->error,sizeof(out->error),"Could not produce a complete SQL definition.");
done:
  free(query.text); free(source.text); free(select.text); free(insert.text); free(update.text); free(del.text);
  sql_query_free(&rows);
  if (!out->source_sql && !out->error[0]) snprintf(out->error,sizeof(out->error),"Definition exceeds its size limit.");
  return out->error[0] == 0;
}
