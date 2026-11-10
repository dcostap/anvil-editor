# SQL Server

## Queries

Use **SQL Server: Manage** in Command Search to manage the current Project's connections. The Dialog title shows **Project Databases — <project name>**. The Connections list shows each connection's name, server, database and state. The form below it shows the selected connection: its state with Connect or Reload Schema and Disconnect, its fields, and Remove Connection. Select Add, enter the server and database, then select Connect. Connect checks access and loads metadata. Reload Schema loads metadata again. A change to a field disconnects the connection. An empty Dialog shows only Add Connection. Windows authentication hides the user and password fields.

Open a `.sql` file, select SQL as an Untitled Buffer's Language Mode, or use **SQL Server: New Query**. All three use the normal Editor. Selecting SQL does not connect to a server. **SQL Server: Choose Connection** assigns a connection to the Editor. An explicit database command asks for a connection when none is assigned, then connects if needed. Queries use normal editing, Save As, completion, and symbol navigation.

The Dialog has no separate database sidebar. Table editing and transaction controls are not available.

## Database source

Symbol navigation reads the database object's source into a read-only SQL Editor. Back returns to the same Query. The definition inherits its connection and supports completion, navigation, and Run Selection. Table and view definitions include a SELECT example. Definitions are snapshots; reopening one reads it again. They are not saved in the Workspace.

In a SQL Editor, **Project Symbol Search** searches that Buffer's database connection. It lists tables, views, procedures, and SQL functions. An empty query lists objects. Selecting a result opens the same source as symbol navigation. The first search can ask for a connection; opening SQL alone never does.

**SQL Server: Generate Select**, **Insert**, **Update**, **Delete**, **Create**, and **Alter** act on the database symbol at the caret. Each supported command opens an editable SQL Buffer with the same connection. It executes nothing. UPDATE and DELETE templates start with a false predicate. INSERT and UPDATE values require editing.

Table scripts include column types, identity settings, computed columns, defaults, keys, checks, foreign keys, and ordinary indexes. They explicitly exclude storage options, triggers, and permissions. They are not complete database deployment scripts. Unsupported table features, disabled indexes, and disabled or untrusted constraints stop scripting instead of producing an incomplete declaration. Table ALTER generation is not available.

Module source comes from SQL Server. CREATE and ALTER generation changes its opening declaration, not its body. Generated scripts use the object's current name, also after a rename. Modules with ANSI_NULLS or QUOTED_IDENTIFIER OFF show their settings but offer no CREATE or ALTER script. Selected execution does not apply those settings automatically. Encrypted source, missing VIEW DEFINITION permission, and source limits produce an error. Source reads are bounded to 512 KiB and use the execution worker's bounded result reader.

## Run SQL

Use **SQL Server: Run Selection** in a SQL Query. It runs the primary selection and does nothing when that selection is empty. **SQL Server: Run Buffer** explicitly runs the whole Buffer. Both send the text as one batch. Neither splits `GO` lines or selects a statement at the caret. An edit, caret move, or focus change while a connection starts cancels the pending execution request.

**SQL can change database data, even when selected from a read-only definition.** Each run opens a new connection with normal autocommit. Temporary tables, session settings, and transactions do not carry into the next run. Cancellation does not undo committed changes.

Results open below the Query without taking focus or moving the caret. Another run replaces that Query's results. The View reuses Tabular Data Preview's selection, copy, sorting, filtering, column sizing, and scrolling. `NULL` is distinct from an empty value. Numbers remain text, so large integers and decimals keep their precision. Binary values show as hexadecimal.

Sorting compares text. Use `ORDER BY` for the server's typed order. Copy uses tab-separated text, with `NULL` as an empty field.

Use **SQL Server: Next Result** and **Previous Result** for a batch with several tables. The result's Context Menu offers these commands and **Messages**. Messages shows update counts or the error. Results do not enter the Workspace or modify the Query.

Use **SQL Server: Cancel** from the Query or its results. Closing the results, closing the Buffer, disconnecting, or changing connection settings also requests cancellation. A login can take up to its 15-second timeout before cancellation takes effect. All database calls run off the UI thread.

The default row limit is 1,000 per table. The execution timeout is 30 seconds after login. Set `config.plugins.sql_server.max_rows` from 1 to 10,000, and `config.plugins.sql_server.timeout_seconds` from 1 to 300.

Batches are limited to 256 KiB. Each run holds at most 16 result records, 128 columns per table, 262,144 cells, and 8 MiB of value text. A cell holds at most 32,768 UTF-16 units. A warning marks incomplete results. A row limit discards extra rows and continues to later results. A total result limit stops result reading. Later statements can already have run; these limits are not write protection.

## Connections and persistence

Connection settings belong to the current Project on this PC. Scratch has its own saved connections; it does not share them with other Projects. Its Dialog title shows **Project Databases — Scratch**. Each open query remembers its connection. Workspace restore and Untitled recovery keep that identity. Save As keeps it while the query remains open or saved in the Workspace. Opening a saved SQL file without its Workspace state requires choosing its connection again.

Restoring a query does not connect. An explicit execution command connects when needed. Select Connect in the Databases Dialog to load metadata without executing SQL. Explicitly closing an Untitled Query keeps the normal discard confirmation.

Windows uses Microsoft ODBC Driver 18, or Driver 17 when 18 is absent. Windows authentication and SQL login are supported. Passwords are masked and are not saved. A successful Connect keeps the password in memory for query runs. Disconnect, a connection change, a Project change, or exit clears it. Enter it again for each connection attempt.

TLS defaults to certificate verification. Trust Certificate keeps encryption but accepts an unverified certificate. No Encryption is an explicit choice for servers such as LocalDB. Anvil never selects it after a failed encrypted connection.

Metadata reads run on a worker. They use fixed SQL Server catalog queries, request read-only access, and close the connection afterward. Ready means that a metadata snapshot is available, not that a session stays connected. Completion reads that snapshot without network access. Disconnect and connection changes discard it. Late results cannot replace a newer connection state.

## Supported SQL context

The native parser supports SELECT scopes, FROM and JOIN sources, aliases, schema-qualified tables, bracketed identifiers, quoted identifiers, comments, and strings. Semicolons and standalone GO lines separate statements. Nested SELECT scopes use their own sources. Completion inserts quoted names when needed and replaces the complete token at the caret.

Object navigation also recognizes EXEC, INSERT INTO, UPDATE, DELETE FROM, REFERENCES, and CREATE or ALTER object declarations. **SQL Server: Expand Star** replaces the projection `*` at the caret with its source columns. It supports an alias-qualified star and qualifies joined columns. It changes no database data. One undo restores the star.

Unqualified table lookup follows the database user's default schema, then `dbo`. Ambiguous column navigation does not choose a table. Joined-column completion qualifies its inserted names.

CTEs, derived tables, cross-database references, table-valued function sources, correlated outer references, and temporary-table metadata are not supported. This is not a complete T-SQL parser or a Tree-sitter SQL grammar. Context reads stop above 256 KiB, 32,768 tokens, 64 nested SELECT scopes, or 64 sources. Metadata reads stop above 10,000 objects or 50,000 columns.

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

For execution, `com/onseven/dbvis/o/f/l.java` supplies the reference for multiple results and cancellation from another thread. `com/onseven/dbvis/o/f/z.java` and `com/onseven/dbvis/db/s_.java` supply the row-limit reference. Anvil keeps its own bounded result model and uses its existing table View.

## Tests

Default UI tests replace the database boundary at `plugins.sql_server.backend` with fixed metadata and execution replies. The real Dialog, Editor, persistence, completion, navigation, and result View run unchanged. They need no SQL Server, driver, credentials, or network access. Runtime input tests reject invalid batches before a connection opens.

```sh
meson test -C build-windows-x86_64 anvil:sql-context
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_context.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_execution.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_definitions.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/sql_server.lua
```

The real-server test is opt-in. It needs an existing LocalDB installation and Microsoft ODBC Driver 18 or 17. It creates a uniquely named instance and a database in a private temporary folder. It checks metadata, escaped identifiers, unchanged table data, and connection-value isolation. Execution checks cover multiple results, update counts, exact values, Unicode, embedded NUL, limits, errors, and cancellation. It then deletes its instance and files. It never reads user connection settings or connects to another instance.

```sh
ANVIL_SQL_INTEGRATION=1 meson test -C build-windows-x86_64 anvil:sql-server-integration --print-errorlogs
```

Without opt-in or dependencies, the test reports SKIP, not PASS. It installs nothing. LocalDB tests use Windows authentication and explicitly disable TLS because LocalDB does not support it. They do not prove remote TLS or SQL-login behavior.

The `databases-dialog`, `sql-results`, and `sql-symbols` render scenarios use fixed data on a private desktop. They make no database connection.

## References

- [SQL editing and completion](https://www.dbvis.com/docs/26.2/working-with-sql/editing-sql-scripts/)
- [Connection, database, and schema selection](https://www.dbvis.com/docs/26.2/working-with-sql/selecting-database-connection-catalog-and-schema/)
- [Tab persistence](https://www.dbvis.com/docs/26.2/getting-the-most-out-of-the-gui/preserving-tabs-between-sessions/)
- [Connection configuration](https://www.dbvis.com/docs/26.2/database-connection-options/create-a-new-database-connection/)
- [Editable result restrictions](https://www.dbvis.com/docs/26.2/working-with-result-sets/editing-a-result-set/)
- [LocalDB encryption limitation](https://github.com/dotnet/SqlClient/issues/1395)
