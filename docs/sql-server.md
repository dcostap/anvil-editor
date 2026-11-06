# SQL Server

## First slice

Use **SQL Server: Manage** in Command Search to open the Databases Dialog. Add a connection, enter its server and database, then select Connect. Connect checks access and loads metadata. Select Connect again to refresh it.

New Query opens an Untitled SQL Query in a normal Editor. Use for Query assigns the selected connection to the current Editor. Queries use normal editing, Save As, completion, and symbol navigation. Navigation opens a read-only column summary; Back returns to the same query. The summary is not a CREATE script or complete DDL.

Query execution, result grids, and table editing are outside this slice. The Dialog has no separate database sidebar.

## Connections and persistence

Connection settings belong to the current Project on this PC. Each open query remembers its connection. Workspace restore and Untitled recovery keep that identity. Save As keeps it while the query remains open or saved in the Workspace. Opening a saved SQL file without its Workspace state requires Use for Query again.

Restoring a query does not connect. Select Connect to load metadata again. Explicitly closing an Untitled Query keeps the normal discard confirmation.

Windows uses Microsoft ODBC Driver 18, or Driver 17 when 18 is absent. Windows authentication and SQL login are supported. Passwords are masked and are not saved. Enter a SQL login password again for each connection attempt.

TLS defaults to certificate verification. Trust Certificate keeps encryption but accepts an unverified certificate. No Encryption is an explicit choice for servers such as LocalDB. Anvil never selects it after a failed encrypted connection.

Metadata reads run on a worker. They use fixed SQL Server catalog queries, request read-only access, and close the connection afterward. Ready means that a metadata snapshot is available, not that a session stays connected. Completion reads that snapshot without network access. Disconnect and connection changes discard it. Late results cannot replace a newer connection state.

## Supported SQL context

The native parser supports SELECT scopes, FROM and JOIN sources, aliases, schema-qualified tables, bracketed identifiers, quoted identifiers, comments, and strings. Semicolons and standalone GO lines separate statements. Nested SELECT scopes use their own sources. Completion inserts quoted names when needed and replaces the complete token at the caret.

Unqualified table lookup follows the database user's default schema, then `dbo`. Ambiguous column navigation does not choose a table. Joined-column completion qualifies its inserted names.

CTEs, derived tables, cross-database references, table-valued functions, correlated outer references, and temporary-table metadata are not supported. This is not a complete T-SQL parser or a Tree-sitter SQL grammar. Context reads stop above 256 KiB, 32,768 tokens, 64 nested SELECT scopes, or 64 sources. Metadata reads stop above 50,000 columns.

## Source reference

The reference checkout is `D:/Projects/dbvisualizer`, DbVisualizer 26.2.4.4705. Its recovered Java names are shortened.

The selected completion path has these parts:

- `com/onseven/dbvis/b/c/b/p.java` selects a completion provider from SQL context.
- `com/onseven/dbvis/b/c/eb.java` scans tokens and records the context at the caret.
- `com/onseven/dbvis/b/c/g_.java` keeps nested SQL contexts and visible tables.
- `com/onseven/dbvis/b/c/b/pb.java` supplies table candidates.
- `com/onseven/dbvis/b/c/b/x.java` supplies column candidates.
- `com/onseven/dbvis/b/c/b/gb.java` schedules background work and rejects obsolete results.

Anvil follows this context/provider structure for the supported cases. It does not port Swing, JDBC, or the complete product. Native ODBC and workers replace those platform boundaries. Existing Editors, completion providers, Dialog controls, and navigation supply the UI.

## Tests

Default tests use a fixed schema at `plugins.sql_server.backend.read_schema`. The real Dialog, Editor, persistence, completion, and navigation run unchanged. They need no SQL Server, driver, credentials, or network access.

```sh
meson test -C build-windows-x86_64 anvil:sql-context
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_context.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/sql_server.lua
```

The real-server test is opt-in. It needs an existing LocalDB installation and Microsoft ODBC Driver 18 or 17. It creates a uniquely named instance and a database in a private temporary folder. It checks metadata, escaped identifiers, unchanged table data, and connection-value isolation. It then deletes its instance and files. It never reads user connection settings or connects to another instance.

```sh
ANVIL_SQL_INTEGRATION=1 meson test -C build-windows-x86_64 anvil:sql-server-integration --print-errorlogs
```

Without opt-in or dependencies, the test reports SKIP, not PASS. It installs nothing. LocalDB tests use Windows authentication and explicitly disable TLS because LocalDB does not support it. They do not prove remote TLS or SQL-login behavior.

The `databases-dialog` render scenario uses fixed, disconnected settings on a private desktop. It makes no database connection.

## References

- [SQL editing and completion](https://www.dbvis.com/docs/26.2/working-with-sql/editing-sql-scripts/)
- [Connection, database, and schema selection](https://www.dbvis.com/docs/26.2/working-with-sql/selecting-database-connection-catalog-and-schema/)
- [Tab persistence](https://www.dbvis.com/docs/26.2/getting-the-most-out-of-the-gui/preserving-tabs-between-sessions/)
- [Connection configuration](https://www.dbvis.com/docs/26.2/database-connection-options/create-a-new-database-connection/)
- [Editable result restrictions](https://www.dbvis.com/docs/26.2/working-with-result-sets/editing-a-result-set/)
- [LocalDB encryption limitation](https://github.com/dotnet/SqlClient/issues/1395)
