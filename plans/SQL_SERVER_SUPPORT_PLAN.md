# SQL Server support research and implementation plan

## Status

This document records research and an implementation plan.

It does not change Anvil behavior.

The research used these revisions:

- Anvil commit `0a7e55729ac76f7f21472e1ce46bf730249f5bc8`
- `microsoft/vscode-mssql` `main` tree `59c8ea50c21e968d8ecb10ba3a14b96bfd471adf`
- `microsoft/sqltoolsservice` `main` tree `890bbef6fa481cbb99e1ed1df085ba0e2ec1ca0a`

Both Microsoft repositories change often. Recheck their contracts before implementation.

## Terminology

T-SQL is a language dialect. It is not a database type.

The first target is the SQL Server family:

- Microsoft SQL Server
- Azure SQL Database
- Azure SQL Managed Instance
- SQL Database in Microsoft Fabric, where the service supports it

PostgreSQL uses a different protocol, driver, metadata model, and SQL dialect.

This plan keeps the first implementation specific to SQL Server.

The following working names need confirmation before addition to `CONTEXT.md`:

- **SQL Connection Profile**: Saved non-secret connection settings.
- **Selected SQL Connection**: The profile selected for one Project.
- **SQL Results View**: A View that shows query results and messages.
- **SQL Explorer**: A View that browses server and database objects.
- **SQL Table Data View**: A View that stages and commits table row changes.

Use **SQL Results View**, not “output buffer.”

An output tool is a View in Anvil. It is not necessarily a Buffer.

## Decision summary

Use Microsoft SQL Tools Service as the SQL Server backend.

Build the user interface in native Anvil Lua.

Do not port the VS Code extension or its React webviews.

Use one SQL Tools Service process for the Anvil process.

Use its existing JSON-RPC protocol for these features:

- connections
- T-SQL completion and diagnostics
- go-to-definition
- query execution and cancellation
- lazy result retrieval
- Object Explorer
- table data editing

Keep arbitrary query results read-only.

Allow edits only through a table-scoped SQL Table Data View.

Start with these authentication methods:

- Windows integrated authentication
- SQL login with a session-only password

Do not save passwords in Anvil's current storage system.

Download SQL Tools Service only after an explicit user action.

Pin the package version and SHA-256 digest.

Do not commit the service binary into this repository.

Use the classic SQL Tools Service query protocol first.

Do not target the new STS2 query protocol in the first version.

This design gives the requested value without copying VS Code architecture.

## The 90 percent product

The useful first product has five connected workflows.

### 1. Add and select a connection

A user creates a SQL Connection Profile.

The first form contains only these fields:

- profile name
- server
- database
- authentication type
- user name for SQL login
- encryption mode
- trust server certificate
- connection timeout

The password stays in memory for the current Anvil process.

One Project has one Selected SQL Connection in the first version.

All SQL Buffers in that Project inherit the selection.

The Status Bar shows the selected server and database for a SQL Editor.

### 2. Edit and run T-SQL

The existing SQL Language Mode continues to highlight `.sql` and `.psql` files.

A command executes the current selection when it is not empty.

The same command executes the complete Buffer when the selection is empty.

A second command always executes the complete Buffer.

SQL Tools Service handles `GO` batch separators.

A cancellation command stops the active query.

### 3. View results

The command opens one SQL Results View for the Project.

The View contains these result areas:

- one grid for each result set
- one Messages Text View
- running, elapsed, row-count, error, and cancellation state

The first version keeps only the newest run.

A new run disposes the previous service result data.

The grid requests only visible row pages.

The grid draws only visible rows and columns.

### 4. Navigate database objects

The SQL Explorer browses objects lazily.

The first useful hierarchy is:

```text
server
  databases
    schemas
      tables
        columns
      views
        columns
      stored procedures
      functions
```

SQL Object Search uses the Fuzzy Searcher.

Connected completion suggests database objects and columns.

Go-to-definition asks SQL Tools Service to script the selected database object.

### 5. Edit table data

A user starts editing from a table in SQL Explorer.

The SQL Table Data View loads a bounded set of rows.

The user can stage these changes:

- update a cell
- set a cell to `NULL`
- insert a row
- delete a row
- revert a cell
- revert a row
- revert all changes

Commit is a separate explicit command.

Close prompts when staged changes exist.

A command shows the generated change script before commit.

## Important product boundary: query results are not table data

An arbitrary query result cannot be edited safely in the general case.

A result can contain these forms:

- joins
- aggregates
- expressions
- aliases
- duplicate column names
- columns from several databases
- rows without stable keys
- stored procedure output

SQL Server Management Studio separates these workflows.

Its “Edit Top N Rows” action is table-scoped.

The VS Code MSSQL extension follows the same model.

Its query result grid is read-only.

Its Table Explorer uses a separate `edit/*` service session.

Anvil should keep the same boundary.

A query result may offer an **Edit Table Data** action later.

That action must open the source table in a separate SQL Table Data View.

Do not add direct edits to arbitrary query results.

## What the VS Code MSSQL extension contains

The current repository is a multi-extension TypeScript monorepo.

The primary extension is under `extensions/mssql`.

It includes much more than the requested product:

- connection dialogs and groups
- Object Explorer
- query execution
- result grids
- query history
- execution plans
- query profiling
- schema design
- table design
- schema comparison
- DACPAC and BACPAC operations
- SQL projects
- notebooks
- Azure and Fabric browsing
- local SQL Server containers
- Copilot tools
- Data API Builder
- telemetry

Most of this scope does not belong in the first Anvil version.

### VS Code client structure

Important client files include:

| Concern | VS Code path |
| --- | --- |
| Service client | `extensions/mssql/src/languageservice/serviceclient.ts` |
| Service download | `extensions/mssql/src/languageservice/serviceDownloadProvider.ts` |
| Service package config | `extensions/mssql/src/configurations/config.ts` |
| Connection manager | `extensions/mssql/src/controllers/connectionManager.ts` |
| Connection profile store | `extensions/mssql/src/models/connectionStore.ts` |
| Secret store adapter | `extensions/mssql/src/credentialstore/credentialstore.ts` |
| Query runner | `extensions/mssql/src/controllers/queryRunner.ts` |
| Query event routing | `extensions/mssql/src/controllers/queryNotificationHandler.ts` |
| Query state | `extensions/mssql/src/models/sqlOutputContentProvider.ts` |
| Query contracts | `extensions/mssql/src/models/contracts/queryExecute.ts` |
| Query result controller | `extensions/mssql/src/queryResult/queryResultWebViewController.ts` |
| Query result model | `extensions/mssql/src/sharedInterfaces/queryResult.ts` |
| Result grid | `extensions/mssql/src/webviews/common/FluentResultGrid` |
| Query result page | `extensions/mssql/src/webviews/pages/QueryResult` |
| Object Explorer service | `extensions/mssql/src/objectExplorer/objectExplorerService.ts` |
| Object Explorer provider | `extensions/mssql/src/objectExplorer/objectExplorerProvider.ts` |
| Metadata service | `extensions/mssql/src/services/metadataService.ts` |
| Table edit service | `extensions/mssql/src/services/tableExplorerService.ts` |
| Table edit controller | `extensions/mssql/src/tableExplorer/tableExplorerWebViewController.ts` |
| Table edit contracts | `extensions/mssql/src/sharedInterfaces/tableExplorer.ts` |
| Table query composition | `extensions/mssql/src/tableExplorer/tableQueryComposer.ts` |

The extension process owns service communication and state.

React webviews own large grid and form interfaces.

SQL Tools Service owns SQL Server connections and database operations.

### Query execution flow in VS Code

`QueryRunner` assigns one owner URI to each query session.

The owner URI also identifies its SQL Server connection.

The client sends one of these requests:

- `query/executeDocumentSelection`
- `query/executedocumentstatement`
- `query/executeString`

Notifications report progress:

- `query/batchStart`
- `query/resultSetAvailable`
- `query/resultSetUpdated`
- `query/resultSetComplete`
- `query/batchComplete`
- `query/message`
- `query/complete`

The client does not receive all rows in these notifications.

It requests row ranges with `query/subset`.

The VS Code client requests rows in chunks of 500.

The service can retain large results outside client memory.

The client cancels with `query/cancel`.

It releases result resources with `query/dispose`.

A query can return several batches and result sets.

Each result set has column metadata and a current row count.

Each cell has at least these fields:

```text
displayValue
isNull
rowId, when available
```

### Table editing flow in VS Code

Table editing uses a separate service session.

The protocol methods are:

- `edit/initialize`
- `edit/subset`
- `edit/createRow`
- `edit/updateCell`
- `edit/deleteRow`
- `edit/revertCell`
- `edit/revertRow`
- `edit/script`
- `edit/commit`
- `edit/dispose`

The service sends `edit/sessionReady` after initialization.

The client stages changes inside the service session.

The client can request generated SQL before commit.

The VS Code controller tracks these user states:

- new rows
- deleted rows
- changed cells
- original cell values
- failed cells
- generated scripts
- dirty close state

This is a useful behavior model for Anvil.

Do not copy the controller structure or React state system.

## SQL Tools Service findings

SQL Tools Service is a .NET service from Microsoft.

Its repository is `microsoft/sqltoolsservice`.

It uses JSON-RPC messages over standard input and output.

It provides these main parts:

- connection management
- T-SQL language services
- query execution
- result storage
- Object Explorer
- metadata
- SMO scripting
- table data editing

The service uses Microsoft SQL Server client and management libraries.

Relevant backend paths include:

| Concern | SQL Tools Service path |
| --- | --- |
| Connection service | `src/Microsoft.SqlTools.ServiceLayer/Connection` |
| Connection contracts | `src/Microsoft.SqlTools.ServiceLayer/Connection/Contracts` |
| Query service | `src/Microsoft.SqlTools.ServiceLayer/QueryExecution` |
| Query contracts | `src/Microsoft.SqlTools.ServiceLayer/QueryExecution/Contracts` |
| Result storage | `src/Microsoft.SqlTools.ServiceLayer/QueryExecution/DataStorage` |
| Object Explorer | `src/Microsoft.SqlTools.ServiceLayer/ObjectExplorer` |
| Metadata | `src/Microsoft.SqlTools.ServiceLayer/Metadata` |
| Table editing | `src/Microsoft.SqlTools.ServiceLayer/EditData` |
| Language service | `src/Microsoft.SqlTools.LanguageService/LanguageServices` |
| T-SQL scripting | `src/Microsoft.SqlTools.LanguageService/Scripting` |
| Protocol host | `src/Microsoft.SqlTools.Hosting/Hosting/Protocol` |

### Wire protocol

The service uses LSP-style framing:

```text
Content-Length: <UTF-8 byte count>\r\n
\r\n
<JSON body>
```

The body normally uses JSON-RPC 2.0.

Requests contain `jsonrpc`, `id`, `method`, and optional `params`.

Notifications omit `id`.

Responses contain `id` and either `result` or `error`.

The framing matches Anvil's current LSP framing.

SQL Tools Service also documents an older custom envelope.

The current VS Code extension uses standard JSON-RPC through `vscode-languageclient`.

### Local protocol proof

This machine has SQL Tools Service `4.0.1.1` inside Azure Data Studio.

A direct framed `initialize` request succeeded over standard input and output.

The service returned LSP capabilities for completion, hover, formatting, and definition.

It returned response ID `"1"` after receiving numeric ID `1`.

Anvil's request tracker currently distinguishes numeric and string table keys.

A direct reuse therefore needs string request IDs or ID normalization.

The old service also closed during `shutdown` without a normal shutdown response.

The SQL client should accept that clean close behavior.

These are small compatibility changes. They do not require another transport.

### Connection protocol

The main methods are:

- `connection/connect`
- `connection/cancelconnect`
- `connection/disconnect`
- `connection/listdatabases`
- `connection/getconnectionstring`
- `connection/parseConnectionString`
- `connection/clearpooledconnections`

`connection/connect` starts an asynchronous connection attempt.

The final result arrives through `connection/complete`.

Important completion fields include:

- owner URI
- connection ID
- server information
- server name
- database name
- user name
- error number
- error message
- service messages

A connection uses a `ConnectionDetails` option map.

Useful first-version keys are:

- `server`
- `database`
- `user`
- `password`
- `authenticationType`
- `encrypt`
- `trustServerCertificate`
- `connectTimeout`
- `applicationName`

A complete connection string overrides the other settings.

Do not save a connection string that can contain a password.

### Language service behavior

The service supports standard LSP document synchronization.

The useful methods include:

- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`
- `textDocument/completion`
- `completionItem/resolve`
- `textDocument/hover`
- `textDocument/signatureHelp`
- `textDocument/definition`
- `textDocument/formatting`
- `textDocument/publishDiagnostics`

Connected parsing binds T-SQL names against database metadata.

Completion can therefore suggest tables, columns, functions, and procedures.

Go-to-definition requires a live connection for database objects.

It uses SMO to generate an object script.

Supported scripted objects include these types:

- tables
- views
- stored procedures
- functions
- schemas
- synonyms
- user-defined types

The service writes generated definitions into a temporary `.sql` file.

It returns a normal file URI through the LSP `Location` result.

The current Anvil language navigation can open file URI locations.

The generated file should become a read-only Text View after loading.

Column navigation needs a focused acceptance test.

The service may resolve a column to its containing table script.

The inspected source does not guarantee a precise column range.

Connected database references are not a complete feature.

The old service advertised `referencesProvider = false`.

Current source adds references mainly for SQL project files.

Do not promise database-wide “find references” in the first version.

### Object Explorer protocol

Object Explorer is session-based and lazy.

The important methods and notifications are:

- `objectexplorer/getsessionid`
- `objectexplorer/createsession`
- `objectexplorer/sessioncreated`
- `objectexplorer/expand`
- `objectexplorer/expandCompleted`
- `objectexplorer/refresh`
- `objectexplorer/closesession`

Each `NodeInfo` can contain:

- unique node path
- parent node path
- node type
- node subtype
- object type
- label
- status
- leaf state
- scripting metadata
- error message
- filter properties

The client expands only visible or requested nodes.

This model maps well to an Anvil tree View.

### Metadata protocol

`metadata/list` returns database objects for one owner URI.

Object metadata includes these useful fields:

- metadata type
- metadata type name
- schema
- name
- parent name
- parent type name
- URN

Separate requests return table and view columns.

Column metadata includes these useful fields:

- escaped name
- ordinal
- default value
- computed state
- identity state
- key state
- uniqueness trust state

Use `metadata/list` for SQL Object Search.

Use Object Explorer for the complete lazy hierarchy.

### Table editing safety facts

The backend restricts each edit session to one result set.

It validates that columns come from one requested table or view.

It rejects several unsafe result shapes.

Examples include these shapes:

- several source tables
- several catalogs or schemas
- duplicate column names
- a different source table

Each column reports whether it is editable.

Identity, computed, and other non-updatable columns are calculated fields.

New rows omit unset nullable or defaulted fields.

SQL Server then supplies `NULL`, defaults, identities, and computed values.

Updates use only changed and updatable columns in the `SET` clause.

The row `WHERE` clause uses service-selected key columns.

The service prefers explicit key columns.

It can fall back to trustworthy unique columns.

It does not fall back to every original column.

The inspected code has two important limits.

First, commit is not transactional.

The service executes staged row operations in sequence.

An earlier operation can commit before a later operation fails.

Second, concurrency checks use key values only.

They do not compare every original non-key value.

A concurrent non-key change can be overwritten.

The service rejects a key predicate that matches several rows.

A zero-row match does not have a clear conflict error in the inspected code.

The UI must not claim full optimistic concurrency protection.

Show these limits in the commit confirmation and documentation.

## STS2 findings

The current extension has a new SQL Data Plane abstraction.

Its local provider uses an STS2 protocol inside SQL Tools Service.

STS2 adds these query features:

- streamed row pages
- explicit backpressure
- acknowledgements
- structured completion state
- typed and truncated cell forms
- stricter protocol validation
- query deadlines

Its methods use a `v2/` domain.

Important operations include:

- initialize
- connection open, cancel, and close
- query execute, acknowledge, cancel, and dispose
- result-set, row, message, complete, and fatal notifications

STS2 is capability-gated and still maturing.

It does not replace the classic language, Object Explorer, and edit protocols.

The first Anvil version needs those classic protocols anyway.

Use the classic query protocol for one coherent implementation.

Keep method names and result decoding in one module.

Add STS2 only after a measured need or classic protocol deprecation.

## License and distribution findings

The `vscode-mssql` source repository uses the MIT License.

The `sqltoolsservice` source repository also uses the MIT License.

SlickGrid uses the MIT License.

The packaged Microsoft service contains components under extra terms.

The SQL Tools Service Layer SDK EULA permits distribution inside a larger application.

It requires significant primary application functionality and protective user terms.

It prohibits standalone redistribution and several modification forms.

The T-SQL Language Service has separate proprietary terms.

Its distributable object code has additional conditions.

The extension's third-party notices also contain old pre-release notices.

This document is not legal advice.

Before public distribution, review the exact package notices and terms again.

The safest first approach is an explicit first-use download.

Do not vendor the service archive inside Anvil releases initially.

Keep required notices beside the installed service.

Record the accepted service version in machine-local state.

## Service package facts

At the inspected revision, VS Code pins SQL Tools Service `6.0.20260827.1`.

Its Windows x64 package is:

```text
microsoft.sqltools.servicelayer-win-x64-net10.0.zip
```

The package URL pattern is:

```text
https://github.com/Microsoft/sqltoolsservice/releases/download/{version}/
  microsoft.sqltools.servicelayer-{fileName}
```

The Windows x64 archive size is `91,257,645` bytes.

Its published digest is:

```text
sha256:4b0e53ddaacbcc110b9d91f2c5bb14cdbdb0f1f483c71715bc83a5712f699d99
```

The service executable is:

```text
MicrosoftSqlToolsServiceLayer.exe
```

The package also contains `SqlToolsResourceProviderService.exe`.

The first Anvil scope does not need the Resource Provider service.

Pinning this exact future package is not a permanent decision.

Select a stable release again when implementation starts.

## Anvil codebase findings

### Existing SQL support

`data/plugins/language_sql.lua` supplies regex-based SQL syntax highlighting.

It supports `.sql` and `.psql` files.

It contains SQL Server and PostgreSQL keywords together.

It is not a Tree-sitter integration.

Anvil currently bundles Tree-sitter grammars only for these languages:

- C
- C++
- Odin
- Kotlin

Therefore, SQL currently has no Tree-sitter outline or project symbol index.

This differs from the requested database-aware navigation.

A parser grammar would only understand source text.

It would not know a live database schema.

SQL Tools Service is the correct source for database-aware names.

A SQL Tree-sitter grammar can remain a separate later task.

### Existing LSP and JSON-RPC support

Anvil already has these useful modules:

- `data/core/lsp/json.lua`
- `data/core/lsp/jsonrpc.lua`
- `data/core/lsp/transport.lua`
- `data/core/lsp/process.lua`
- `data/core/lsp/client.lua`
- `data/core/lsp/documents.lua`
- `data/core/lsp/provider.lua`
- `data/core/lsp/completion.lua`
- `data/core/lsp/diagnostics.lua`
- `data/core/lsp/hover.lua`
- `data/core/lsp/signature_help.lua`

The framing already matches SQL Tools Service.

The client already supports arbitrary requests and notification handlers.

The document layer already sends incremental Buffer changes.

The provider already connects definitions to Anvil navigation commands.

Do not write a second JSON parser or process transport.

Add only the SQL Tools Service compatibility options.

### Existing process support

`data/core/process.lua` provides non-blocking process pipes.

`data/core/lsp/process.lua` provides bounded stdio writes and stderr draining.

Use those modules to start SQL Tools Service.

Do not start the service through a shell command.

Pass an argument array directly to `process.start`.

### Existing result View reference

`data/plugins/command_slots.lua` provides two useful patterns:

- a Project-owned singleton compound View
- read-only generated output Text Views

The SQL Results View should follow its placement and lifecycle concepts.

Do not subclass the Command Output View.

SQL results have structured rows, columns, batches, and messages.

### Existing table View plan

`TABULAR_DATA_PREVIEW_PLAN.md` already defines a simple custom table View.

Its useful rendering rules also apply here:

- fixed-height rows
- fixed headers
- visible-row drawing
- visible-column drawing
- independent column widths
- one custom View
- no widget object per cell

Do not create a general table framework before implementation.

SQL results and SQL table editing need two grids immediately.

A small private `sql_server/grid.lua` module is therefore justified.

Do not move that module into `core` initially.

Extract shared table code only after another implemented feature needs it.

### Existing tree and generated text seams

A SQL Explorer can extend `core.textview` like other tree tools.

A generated definition can use `TextView.from_text(...)`.

That helper creates a read-only Buffer and Text View.

`data/core/panes.lua` can place and present all new Views.

The Fuzzy Searcher can provide connection and object selection.

### Existing storage is not a secret store

`data/core/storage.lua` writes serialized Lua data under `USERDIR`.

It does not encrypt values.

Do not put passwords, access tokens, or secret connection strings there.

The widget library already supports masked password entry.

`data/widget/textbox.lua` has a password mode.

Use masked entry and memory-only retention first.

## Options considered

### Option A: port the VS Code extension

Do not use this option.

The extension depends on VS Code APIs, Node, React, and webviews.

Its result grid alone has many controllers, state types, and UI files.

The port would import architecture that Anvil does not need.

### Option B: execute `sqlcmd`

This is useful for a small command runner only.

It is not suitable for the requested product.

Text output loses reliable type, `NULL`, binary, and result-set boundaries.

It does not supply editable rows or database-aware language services.

### Option C: add direct ODBC or TDS access

This can execute typed queries with a smaller runtime.

It still requires substantial new work:

- connection and authentication handling
- batch parsing
- result paging
- metadata queries
- object scripting
- safe row editing
- language services

It duplicates mature SQL Tools Service behavior.

### Option D: use SQL Tools Service

This is the recommended option.

It provides nearly all required backend behavior.

The cost is a large downloaded service and Microsoft component terms.

That trade is favorable for this personal SQL Server workflow.

## Proposed architecture

```text
SQL Editor Buffer
  | didOpen / didChange / didClose
  | execute selected or complete text
  v
Anvil sql_server plugin
  | profiles and Project selection
  | query state
  | SQL Results View
  | SQL Explorer
  | SQL Table Data View
  v
core.lsp.client with SQL compatibility options
  | Content-Length framed JSON-RPC over stdio
  v
MicrosoftSqlToolsServiceLayer.exe
  | Microsoft.Data.SqlClient, SMO, T-SQL language service
  v
SQL Server-family database
```

### Process ownership

Use one service process for Anvil.

Start it lazily after one explicit SQL action.

Keep it alive while SQL owners or Views exist.

Pump it from one `core.add_background_thread()` loop.

That loop also flushes attached SQL document changes.

Stop it during Anvil shutdown.

Do not start one service process per Project or Buffer.

### Owner URI model

SQL Tools Service keys connections and query sessions by owner URI.

Use the SQL Buffer file URI as its owner URI.

This gives one connected language context for each SQL Buffer.

The Selected SQL Connection supplies credentials for each owner.

Connecting another SQL Buffer can reuse the same profile settings.

The service still receives a separate `connection/connect` request per owner URI.

Use synthetic URIs for service-only operations when no Buffer exists.

Examples include SQL Explorer and table edit sessions.

Prefix synthetic URIs clearly:

```text
anvil-sql://project/<project-id>/explorer
anvil-sql://project/<project-id>/edit/<session-id>
```

Do not use filesystem paths for synthetic owners.

### Project model

The first version has one Selected SQL Connection per Project.

This keeps command behavior obvious.

A SQL Buffer inherits the Project selection.

Changing the Project selection reconnects its attached SQL Buffers.

Do not add per-folder, per-query, and per-language connection rules initially.

Add a temporary per-Buffer override only after a real need appears.

### Backend boundary for PostgreSQL

Do not build a driver registry now.

Keep SQL Server calls behind one small service object.

The Views consume these normalized operations:

```text
connect
disconnect
execute
cancel
fetch_rows
list_objects
expand_object
open_table_edit
```

The first object is `sql_server.service`.

A future PostgreSQL plugin can implement equivalent View-facing operations.

Do not force SQL Server protocol types into the grid model.

Do not generalize authentication or metadata before PostgreSQL work starts.

## Proposed modules

Create these first-party plugin files:

```text
data/plugins/sql_server/init.lua
data/plugins/sql_server/service.lua
data/plugins/sql_server/connections.lua
data/plugins/sql_server/query.lua
data/plugins/sql_server/grid.lua
data/plugins/sql_server/results_view.lua
data/plugins/sql_server/explorer_view.lua
data/plugins/sql_server/table_data_view.lua
```

Add focused tests:

```text
tests/lua/runtime/sql_server_service.lua
tests/lua/runtime/sql_server_connections.lua
tests/lua/runtime/sql_server_query.lua
tests/lua/ui/sql_server_results_view.lua
tests/lua/ui/sql_server_explorer.lua
tests/lua/ui/sql_server_table_data.lua
```

Update these existing files:

```text
data/core/lsp/jsonrpc.lua
data/core/lsp/client.lua
data/plugins/anvil_defaults.lua
data/colors/default.lua, only if existing colors are insufficient
```

A later secret store would add native files.

Do not include that native change in the first query slice.

### Module responsibilities

#### `init.lua`

Own command registration and first-party integration.

Track one Project state object per loaded Project.

Start the service only when required.

Attach SQL Buffers after a Project selects a connection.

#### `service.lua`

Own the SQL Tools Service process and JSON-RPC client.

Register all SQL notification handlers in one place.

Normalize service responses before other modules receive them.

Own installation discovery and service version checks.

Redact secrets from all logs.

#### `connections.lua`

Store non-secret profiles.

Store the Selected SQL Connection per Project.

Keep SQL login passwords only in memory.

Track owner URI connection states.

Resolve connect completion and disconnection.

Use `core.storage` with the normalized Project path as the selection key.

#### `query.lua`

Own one query session and its finite state.

Map query notifications into batches and result sets.

Request and cache row pages.

Cancel and dispose sessions.

#### `grid.lua`

Draw one virtualized grid.

Own cell selection, scrolling, column widths, and copy behavior.

Request missing rows through a caller callback.

Expose edit callbacks without knowing SQL Tools Service contracts.

Keep this module private to `sql_server`.

#### `results_view.lua`

Own one Project's current run presentation.

Present result-set grids and the Messages Text View.

Map query errors back to source lines where possible.

#### `explorer_view.lua`

Own one Object Explorer session.

Render the lazy node tree through a read-only Text View.

Open definitions, table results, and table editing commands.

#### `table_data_view.lua`

Own one `edit/*` session.

Track dirty cells and row states.

Provide commit, revert, script, and close behavior.

## Required small core changes

### String request IDs

Add a request tracker option that emits string IDs.

Keep numeric IDs as the LSP default.

Example option:

```lua
request_id_type = "string"
```

The SQL Tools Service client enables this option.

Do not normalize every response ID globally without tests.

A server can legally use both number and string IDs.

### Optional shutdown response

Allow a client option for clean EOF during shutdown.

Example option:

```lua
shutdown_response_optional = true
```

Do not weaken normal LSP process failure detection.

### Client log label

A small `log_label` option would prevent misleading “LSP” logs.

This is useful but not required for the first vertical slice.

Do not refactor all LSP modules only for naming.

## Service installation design

### First-use behavior

The first SQL command checks for the pinned executable.

When absent, show these choices:

- Install SQL Tools Service
- Select an existing executable
- Cancel

The install action shows package size and license links.

It requires explicit confirmation.

### Install location

Use a machine-local path under `USERDIR`:

```text
USERDIR/tools/sqltoolsservice/<version>/<platform>/
```

Keep downloads and temporary extraction outside the final directory.

Rename the complete extracted directory into place atomically.

### Download and verification

Use `core.http.download` for HTTPS transfer.

Verify the pinned SHA-256 digest before extraction.

On Windows, a first version can call `certutil.exe -hashfile`.

Use PowerShell `Expand-Archive` or another known archive tool for extraction.

Pass PowerShell scripts through the repository's safe quoting rules.

Never use an insecure TLS option.

Delete partial archives after failure.

Do not run any downloaded executable before digest verification.

### Service start arguments

Use an argument array.

The initial set should include only required values:

```text
--application-name Anvil
--data-path <USERDIR SQL service data>
--log-file <USERDIR SQL service log>
--tracing-level Warning
--locale en
```

Add parallel processing flags only after compatibility tests.

Do not enable STS2 initially.

Do not start the Resource Provider service.

## Connection profile design

Use this small persistent shape:

```lua
{
  id = "stable-generated-id",
  name = "Local SQL Server",
  server = "localhost",
  database = "master",
  authentication = "Integrated",
  user = nil,
  encrypt = "Mandatory",
  trust_server_certificate = false,
  connect_timeout = 15,
}
```

A SQL login profile adds `user`.

It never adds `password` to persistent data.

### Connection form

Use one small modal form built from existing widgets.

Use `TextBox` fields and one authentication selector.

Enable password mode on the password field.

Show advanced TLS fields only when requested.

Do not copy the VS Code connection webview.

### TLS behavior

Do not silently set `trustServerCertificate = true`.

Attempt a verified encrypted connection first.

If certificate trust fails, explain the failure.

Offer a session retry that trusts the certificate.

Saving the trust choice requires a separate explicit action.

### Authentication scope

Implement these modes first:

1. `Integrated`
2. `SqlLogin`

Defer these modes:

- Microsoft Entra MFA
- Entra default credentials
- service principals
- access tokens
- Azure account browsing
- Azure firewall rule creation
- Kerberos help flows outside normal integrated behavior

These flows create most of the VS Code connection complexity.

## Query model

Use an explicit state machine:

```text
idle
submitting
running
cancelling
complete
failed
cancelled
disposed
```

A query session contains:

```lua
{
  owner_uri = "file:///.../query.sql",
  source = {
    path = "...",
    selection_line = 1,
    selection_col = 1,
    text = "SELECT ...",
  },
  state = "running",
  started_at = 0,
  completed_at = nil,
  batches = {},
  messages = {},
  has_error = false,
}
```

Each batch contains ordered result sets.

Each result set contains metadata and a page cache.

### Execute selected or complete text

Read query text directly from the Buffer.

Use `query/executeString` for both paths.

This avoids document-selection coordinate ambiguity.

It also makes the exact executed text explicit.

Store the source selection start for error-line mapping.

Flush pending LSP document changes before execution.

### Notification ordering

Route every notification by owner URI.

Ignore notifications for disposed generations.

Use a generation number for each new run.

Throttle visual updates to one update per short frame interval.

Do not throttle final completion.

### Row paging

Start with a page size of 200 rows.

Request a page when drawing needs one of its rows.

Cache pages by batch, result set, and page start.

Use a small least-recently-used cache.

A practical start is 16 pages per visible result set.

Do not request all rows for sorting or display.

### Large cells

The current JSON-RPC parser defaults to a 16 MiB body limit.

Set a bounded SQL client body limit with an explicit reason.

Also configure SQL Tools Service to truncate very large display values.

A single large cell must not terminate the complete service client.

Show a clear truncation marker in the grid.

Provide full-value retrieval only after a real need appears.

### Cancellation and disposal

`query/cancel` changes the state to `cancelling`.

The View remains open and shows partial completed results.

`query/complete` selects `cancelled`, `failed`, or `complete`.

Before a new run, send `query/dispose` for the old owner.

Also dispose when the SQL Results View closes.

## SQL Results View design

Use one Project-owned compound View.

Follow the Quick Command Output View placement pattern.

The initial execution replaces the SQL Editor in its current Pane.

Navigation Back returns to the source Editor.

A later command can open results to the side.

### Internal surfaces

Use permanent internal tabs for:

- Results
- Messages

Inside Results, select one result set at a time.

A small result selector shows batch and result numbers.

Do not build nested webview-style tabs.

### Messages

Use one generated read-only Text View.

Append these items in order:

- server messages
- SQL errors
- rows affected
- batch completion times
- cancellation state
- total elapsed time

Make source locations Points of Interest when reliable line data exists.

Selection execution must add its starting line offset.

### Grid presentation

Draw these fixed areas:

- column header
- row number column
- status footer

Use single-line cells in the first version.

Replace embedded newlines only for display.

Copy the complete service display value.

Show `NULL` differently from an empty string.

Use existing style colors first.

### Grid input

Support these durable interactions:

- click selects one cell
- drag selects a rectangle
- Shift extends selection
- arrow commands move the active cell
- copy writes tab-separated rows
- copy with headers is a separate command
- column dividers resize columns
- wheel input scrolls rows and columns

Do not implement formula, fill, reorder, or spreadsheet behavior.

Do not test exact key bindings.

## SQL Explorer design

Use one SQL Explorer View per Project.

Create its service session only after the View opens.

Cache expanded children by node path.

Discard the cache when the connection generation changes.

### Node actions

Provide only these first actions:

| Node | Primary action |
| --- | --- |
| Database | Select database for a new profile copy or reconnect action |
| Schema | Expand |
| Table | Expand |
| Table column | Copy or insert escaped name |
| View | Open generated definition |
| Stored procedure | Open generated definition |
| Function | Open generated definition |

Table commands include:

- Open Top Rows
- Edit Table Data
- Open Definition
- Copy Escaped Name

Do not add create, drop, backup, restore, or designer actions initially.

### SQL Object Search

Register a dedicated Fuzzy Searcher mode.

Do not add database objects to Project Symbol Search.

Project symbols are source code symbols.

Database objects are external live metadata.

Index `metadata/list` results by these fields:

- schema
- name
- object type
- parent name

Fetch columns only after a table or view becomes relevant.

Activation opens the generated definition.

A secondary action inserts the escaped identifier into the current SQL Editor.

## Language integration design

Start SQL Tools Service before attaching SQL Buffers.

Register the service client with these existing modules:

- LSP documents
- diagnostics
- provider

Completion, hover, and signature help discover attached document clients automatically.

Set `language_id = "sql"` unless service tests require `"SQL"`.

### Connection timing

Attach the Buffer with `textDocument/didOpen` first.

Then send `connection/connect` for the same file URI.

Wait for `connection/complete` before database-aware commands.

Completion can return syntax-only items while connection metadata builds.

Handle `textDocument/intelliSenseReady` as a quiet state transition.

### Definitions

Reuse Anvil's existing `editor:go_to_definition` command.

Do not create a second SQL-only definition command.

Intercept generated service files only to make them read-only.

Copy their text into `TextView.from_text` if service file lifetime is uncertain.

### Diagnostics

Reuse existing diagnostic underlines and hints.

Do not add a second SQL error marker system.

Query execution errors remain in the SQL Results View.

Language diagnostics and execution errors have different lifecycles.

### Tree-sitter

Do not block SQL Server support on a SQL Tree-sitter grammar.

Connected metadata navigation gives more immediate value.

Consider Tree-sitter later for these source-only features:

- Current Buffer Symbol Search
- source outline
- folds
- local `CREATE` object navigation
- source-level usages

A grammar must support T-SQL constructs and `GO` batches well.

Do not use a generic SQL grammar without corpus tests.

## SQL Table Data View design

Open the View only for one known table.

Initialize with a practical row limit.

Start with 200 rows to match the familiar “Edit Top 200 Rows” workflow.

The limit is a preference, not a correctness contract.

### View state

Track this normalized state:

```lua
{
  owner_uri = "anvil-sql://...",
  table = { database = "db", schema = "dbo", name = "Users" },
  columns = {},
  rows = {},
  row_count = 0,
  new_rows = {},
  deleted_rows = {},
  changed_cells = {},
  failed_cells = {},
  state = "loaded",
}
```

Keep service row IDs separate from visible row positions.

Sorting and paging can change visible positions.

### Editing one value

Select one editable cell.

Press the edit command or double-click.

Open a small scoped value prompt.

Show the column name and data type when available.

An empty prompt value means an empty string.

Use a separate **Set NULL** command.

Send `edit/updateCell` after prompt acceptance.

Mark successful staged changes visibly.

Mark failed changes with the returned error.

### Row operations

**Add Row** sends `edit/createRow`.

The service returns defaults and a new row ID.

**Delete Row** sends `edit/deleteRow`.

Keep the row visible with a deleted state until commit.

Deleting a new uncommitted row removes that pending row.

**Revert** calls the matching service method.

Do not emulate backend edit rules only in Lua.

### Commit

Before commit, show counts for inserts, updates, and deletes.

State that commit is not atomic.

State that key-only matching can overwrite concurrent non-key changes.

Offer these actions:

- Commit
- Show Script
- Cancel

`Show Script` uses `edit/script` and a read-only Text View.

A commit failure keeps remaining staged state visible.

Do not report complete success after a partial backend failure.

Reload table data after a successful commit.

### Close

A clean View closes immediately.

A dirty View offers Save, Discard, and Cancel.

Save calls commit.

Discard disposes the edit session without database changes.

Cancel leaves the View open.

Do not persist staged row changes into Workspace state.

## Security and privacy rules

Never log passwords, tokens, or complete connection strings.

Do not log complete query text by default.

Log query byte count and operation state instead.

Do not persist result values or query history in the first version.

Do not persist staged table values.

Clear in-memory passwords on disconnect and process exit.

Use encrypted transport by default.

Do not auto-accept server certificates.

Keep profiles in machine-local `USERDIR` state.

Do not read executable paths from untrusted Project files.

Do not execute SQL automatically when a Buffer opens.

An explicit execute command is enough confirmation for arbitrary SQL.

Do not add unreliable SQL text classification as a safety gate.

Table delete commit still needs a clear change summary.

## Performance rules

Start SQL Tools Service lazily.

Use one service process.

Draw visible grid rows only.

Draw visible grid columns only.

Use fixed row heights.

Do not create one widget per cell.

Use lazy row pages and a bounded cache.

Dispose old result sessions.

Throttle progress redraws.

Cache Object Explorer children by session generation.

Do not fetch all table columns for all database objects initially.

Do not sort million-row query results in Lua.

Do not copy all result data into one Buffer.

Measure service startup, first completion, and first row latency.

Add complexity only after a measured problem.

## Logging and diagnostics

Use `core.log_quiet(...)` for these events:

- service discovery
- install start and completion
- digest verification
- process start and exit
- protocol initialization
- connection state changes
- IntelliSense readiness
- query submission
- batch and result-set transitions
- row page requests and cache evictions
- cancellation
- result disposal
- Object Explorer session changes
- edit session state changes
- commit summary and failures

Redact profile secrets before every log call.

Use visible errors only when the user must act.

SQL Tools Service logs belong under `USERDIR/logs`.

Include the service version in startup diagnostics.

## Implementation sequence

Use red-green development for every durable behavior slice.

Run only focused tests during each slice.

### Slice 0: protocol compatibility spike

Add a fake framed server fixture.

Write a failing test for string response IDs.

Add the request ID option to the existing JSON-RPC client.

Write a failing test for clean EOF during optional shutdown.

Add the narrow shutdown option.

Confirm ordinary LSP tests still pass where touched.

Acceptance:

- SQL client initializes with string IDs.
- Existing LSP clients keep numeric IDs.
- Clean SQL service shutdown does not show a crash.

### Slice 1: service discovery and lifecycle

Add `service.lua` with an injected executable path.

Do not build the downloader first.

Start the service and complete `initialize` through a fake process.

Register handlers before the first pump.

Add clean stop and crash state.

Acceptance:

- One service starts.
- Repeated ensure calls reuse it.
- Process failure reaches one visible state.
- Shutdown releases pipes and pending requests.

### Slice 2: profiles and connection

Add non-secret profile storage.

Add Project selection.

Add the connection form for Integrated and SQL login modes.

Drive connection through `connection/connect` and `connection/complete`.

Keep SQL login passwords in memory.

Acceptance:

- A profile can be added, selected, edited, and deleted.
- No password appears in storage or logs.
- One SQL Buffer connects and disconnects.
- Status Bar state is correct.

### Slice 3: execute and messages

Add one query model test first.

Execute Buffer text through `query/executeString`.

Handle batches, result summaries, messages, completion, cancellation, and disposal.

Open a SQL Results View with Messages only.

Acceptance:

- Selection and complete Buffer execution send exact text.
- `GO` batches remain service-owned.
- Errors and row counts appear in order.
- Cancel reaches a final state.
- A new run disposes the old run.

### Slice 4: paged result grid

Add a failing View test for visible page requests.

Implement the private grid and page cache.

Add multiple result-set selection.

Add copy and column resize.

Acceptance:

- Large row counts do not allocate all rows in Lua.
- Only visible rows and columns draw.
- `NULL` differs from an empty value.
- Rectangular copy is tab-separated.
- Multiple batches and result sets stay ordered.

### Slice 5: connected language features

Attach SQL Buffers to the service client.

Register diagnostics and the existing LSP provider.

Test completion, diagnostics, and definition with a fake service.

Run one manual connected definition test.

Acceptance:

- Completion includes database metadata after connection readiness.
- Diagnostics use existing Anvil presentation.
- Go-to-definition opens a read-only generated definition.
- SQL service state does not depend on global LSP enablement.

### Slice 6: SQL Explorer and object search

Add one lazy expansion test.

Implement Object Explorer session lifecycle.

Render a read-only tree View.

Add SQL Object Search from `metadata/list`.

Acceptance:

- The tree requests children only after expansion.
- Refresh invalidates one branch correctly.
- Connection changes close stale sessions.
- Object Search opens a definition.
- Table and column names can be copied or inserted.

### Slice 7: table data editing

Add a fake edit service and a dirty-close UI test.

Implement table-only `edit/initialize` and `edit/subset`.

Add cell, null, row, revert, script, commit, and dispose actions.

Acceptance:

- Query result grids remain read-only.
- Table cells stage changes through service methods.
- `NULL` and empty strings remain different.
- Insert and delete states remain visible.
- Show Script uses backend SQL.
- Dirty close offers Save, Discard, and Cancel.
- Partial failure does not report complete success.

### Slice 8: service installer

Pin one stable package and digest.

Add explicit first-use consent.

Download, verify, extract, and atomically install.

Test installer state with fake download and hash functions.

Acceptance:

- No service runs before digest verification.
- Partial installs are not selected.
- Failed installs leave one actionable error.
- Existing configured executables remain usable.

### Slice 9: finish and document

Add first-party defaults and plugin registration.

Add required license notices.

Add user documentation for connection and table edit limits.

Run syntax checks for all changed Lua files.

Run only the focused SQL test files.

Run broader LSP tests only when core LSP code changes.

## Test plan

### Fake service boundary

Use a fake SQL Tools Service at the process boundary.

Do not mock internal query or View helpers.

The fake service must use real Content-Length framing.

It should support scripted request and notification sequences.

Test these protocol cases:

1. string response IDs
2. response errors
3. unknown notifications
4. malformed frames
5. service EOF
6. delayed connection completion
7. query notifications before request completion
8. cancellation races
9. stale owner notifications
10. several result sets
11. row subset responses
12. edit session partial failure

### Runtime tests

`sql_server_service.lua` verifies process and protocol lifecycle.

`sql_server_connections.lua` verifies profile and owner state.

`sql_server_query.lua` verifies observable query model behavior.

Do not test private helper call counts.

### UI tests

Drive commands and View input through stable seams.

`sql_server_results_view.lua` should test:

- selection-or-Buffer command behavior
- View placement and Navigation Back
- result-set switching
- lazy visible page loading
- rectangular selection and copy
- cancellation status
- error Point of Interest activation

`sql_server_explorer.lua` should test:

- lazy expansion
- refresh
- object activation
- connection generation invalidation
- Fuzzy Searcher object results

`sql_server_table_data.lua` should test:

- staged update
- explicit `NULL`
- insert
- delete
- revert
- script View
- commit result
- partial failure
- dirty close

Do not test exact keyboard shortcuts.

Do not test cosmetic pixel values.

### Optional integration test

Add one opt-in integration script after the fake tests pass.

Use an environment-provided SQL Server connection.

Never require a live database for normal Meson tests.

The integration script should create a temporary database or schema.

It must clean up after success and failure.

Test these real service scenarios:

- Integrated or SQL login connection
- one scalar query
- several result sets
- `GO` batches
- cancellation with `WAITFOR`
- table metadata
- table update, insert, and delete
- no-key table behavior
- generated object definition

## Manual validation scenarios

### Query scenarios

1. Run a complete file with one result set.
2. Run a selection in the middle of a Buffer.
3. Run two batches separated by `GO`.
4. Return several result sets from one batch.
5. Return 100,000 rows and scroll quickly.
6. Return 500 columns and scroll horizontally.
7. Return `NULL`, empty text, Unicode, binary, XML, and long text.
8. Raise a syntax error inside a selection.
9. Cancel `WAITFOR DELAY`.
10. Disconnect during execution.
11. Stop the service during execution.

### Navigation scenarios

1. Complete a table after `FROM`.
2. Complete columns after an alias and dot.
3. Hover a known object.
4. Go to a table definition.
5. Go to a view definition.
6. Test definition behavior on a column.
7. Browse a database with many schemas.
8. Search objects with duplicate names in different schemas.
9. Refresh after creating a table externally.

### Edit scenarios

1. Update a nullable text cell.
2. Set the cell to an empty string.
3. Set the same cell to `NULL`.
4. Insert a row with defaults and identity.
5. Delete one existing row.
6. Revert one cell.
7. Revert all changes.
8. Show generated SQL.
9. Commit several changes.
10. Force one later operation to fail.
11. Change the row from another client before commit.
12. Try a table without a primary key.
13. Try identity, computed, and rowversion columns.
14. Close with dirty changes.

## Suggested command identifiers

Use command names that match Anvil conventions:

```text
sql_server:add_connection
sql_server:edit_connection
sql_server:select_connection
sql_server:connect
sql_server:disconnect
sql_server:execute_selection_or_buffer
sql_server:execute_buffer
sql_server:cancel_query
sql_server:open_results
sql_server:open_explorer
sql_server:search_objects
sql_server:install_service

sql_results:show_results
sql_results:show_messages
sql_results:copy
sql_results:copy_with_headers

sql_explorer:refresh
sql_explorer:open_definition
sql_explorer:open_top_rows
sql_explorer:edit_table_data
sql_explorer:copy_name

sql_table_data:edit_cell
sql_table_data:set_null
sql_table_data:add_row
sql_table_data:delete_row
sql_table_data:revert_cell
sql_table_data:revert_row
sql_table_data:revert_all
sql_table_data:show_script
sql_table_data:commit
```

Do not define default shortcuts during the first implementation slice.

Commands are the durable behavior seam.

## First-party defaults

Register `sql_server` as a first-party core plugin.

Put behavior defaults in `data/plugins/anvil_defaults.lua`.

Do not put fallback defaults inside implementation modules.

Initial defaults should remain small:

```lua
plugin_defaults("sql_server", {
  service_path = nil,
  service_version = "<pinned-version>",
  result_page_size = 200,
  result_page_cache = 16,
  edit_row_limit = 200,
})
```

The pinned URL and digest can remain implementation constants.

They are service integrity data, not user preferences.

Do not expose every grid constant as configuration.

## Risks and controls

| Risk | Control |
| --- | --- |
| Microsoft changes protocol behavior | Centralize methods and add fake contract tests. |
| Large service download | Download on first use only. |
| Extra Microsoft license terms | Do not vendor initially. Review terms before public distribution. |
| Password exposure | Keep passwords in memory only. Redact logs. |
| Insecure TLS retry | Require explicit trust action. |
| Huge query memory | Use service subsets and bounded page caches. |
| Huge JSON cell | Configure truncation and parser limits. |
| Stale notifications | Route by owner URI and generation. |
| Service crash | Fail pending work once and offer restart. |
| Edit partial commit | Warn before commit and preserve accurate remaining state. |
| Concurrent table update | State key-only matching limit. Reload after commit. |
| No stable table key | Keep the session read-only or show commit failure clearly. |
| UI scope growth | Exclude plans, designers, Azure browsers, and notebooks. |
| PostgreSQL pressure | Keep View-facing operations normalized. Add no driver framework yet. |

## Explicit non-goals

Do not include these features in the first implementation:

- PostgreSQL connectivity
- MySQL or SQLite connectivity
- SQL notebooks
- query history persistence
- execution plans
- query profiling
- schema designer
- table designer
- schema comparison
- DACPAC or BACPAC operations
- SQL projects
- database create, backup, restore, or drop tools
- Azure account browsing
- Fabric browsing
- container management
- firewall rule management
- Copilot tools
- Data API Builder
- Entra MFA
- saved passwords
- arbitrary query result editing
- multi-column grid sorting
- client-side filtering of complete large results
- spreadsheet formulas
- a generic core table widget
- a SQL Tree-sitter grammar
- STS2 query transport

Each item can follow a real workflow need.

## Acceptance checklist

The first SQL Server release is complete when all items are true:

- [ ] SQL Tools Service installs or resolves through an explicit action.
- [ ] The downloaded package is verified before execution.
- [ ] Integrated authentication connects.
- [ ] SQL login connects with a session-only password.
- [ ] No secret enters storage or logs.
- [ ] One Selected SQL Connection exists per Project.
- [ ] SQL Buffers receive connected completion and diagnostics.
- [ ] Go-to-definition opens a generated read-only definition.
- [ ] Selection execution sends exact selected text.
- [ ] Empty-selection execution sends the complete Buffer.
- [ ] `GO` batches execute through SQL Tools Service.
- [ ] Several batches and result sets remain ordered.
- [ ] Query cancellation works.
- [ ] Old query resources are disposed.
- [ ] The SQL Results View draws visible rows and columns only.
- [ ] Large results use lazy subset requests.
- [ ] `NULL` and empty text remain distinct.
- [ ] Grid copy works for a rectangular selection.
- [ ] SQL Explorer expands objects lazily.
- [ ] SQL Object Search finds schema-qualified objects.
- [ ] Table editing opens only from a known table target.
- [ ] Cell update, `NULL`, insert, delete, and revert work.
- [ ] Show Script uses SQL Tools Service output.
- [ ] Commit explains non-atomic and concurrency limits.
- [ ] Dirty close offers Save, Discard, and Cancel.
- [ ] Service crashes leave Anvil responsive.
- [ ] Focused runtime and UI tests pass.
- [ ] Session logs contain useful redacted diagnostics.

## Recommended first implementation milestone

Do not implement every section at once.

The first milestone should end after Slice 4.

That milestone gives this complete path:

1. Select an existing SQL Tools Service executable.
2. Add an Integrated or SQL login profile.
3. Connect the current SQL Buffer.
4. Execute selected or complete T-SQL.
5. Cancel a running query.
6. View messages and paged result grids.

This milestone delivers the central daily workflow.

Then add language integration, SQL Explorer, and table editing in separate slices.

The service installer should come after the executable-path workflow proves value.

## Sources

Primary repositories and documentation:

- <https://github.com/microsoft/vscode-mssql>
- <https://github.com/microsoft/sqltoolsservice>
- <https://microsoft.github.io/sqltoolssdk/>
- <https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/mssql/mssql-extension-visual-studio-code>

Key VS Code source files:

- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/languageservice/serviceclient.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/configurations/config.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/controllers/connectionManager.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/controllers/queryRunner.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/models/contracts/queryExecute.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/models/sqlOutputContentProvider.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/objectExplorer/objectExplorerService.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/services/metadataService.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/services/tableExplorerService.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/tableExplorer/tableExplorerWebViewController.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/sharedInterfaces/tableExplorer.ts>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/src/services/sts2/sts2Backend.ts>

Key SQL Tools Service source files:

- <https://github.com/microsoft/sqltoolsservice/blob/main/docs/guide/jsonrpc_protocol.md>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.ServiceLayer/EditData/EditSession.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.ServiceLayer/EditData/UpdateManagement/RowEditBase.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.ServiceLayer/EditData/UpdateManagement/RowUpdate.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.ServiceLayer/EditData/UpdateManagement/RowDelete.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.LanguageService/LanguageServices/TSqlLanguageService.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.LanguageService/Scripting/ScripterCore.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/src/Microsoft.SqlTools.ServiceLayer/ObjectExplorer/Contracts/NodeInfo.cs>
- <https://github.com/microsoft/sqltoolsservice/blob/main/license.txt>
- <https://github.com/microsoft/sqltoolsservice/blob/main/Notice.txt>

Legal references:

- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/LICENSE.txt>
- <https://github.com/microsoft/vscode-mssql/blob/main/extensions/mssql/ThirdPartyNotices.txt>
- <https://github.com/microsoft/sqltoolsservice/blob/main/docs/eulas/SQL%20SERVER%202016%20TSQL%20Language%20Service%20EULA.RTF>
- <https://github.com/microsoft/sqltoolsservice/blob/main/packages/license/Microsoft%20SQL%20Tools%20Service%20Layer%20SDK%20EULA_1%2026%202021.docx>
