# SQL Server

## Queries

Use **SQL Server: Manage** in Command Search to manage the current Project's connections. The Dialog title shows **Project Databases — <project name>**. The Connections list shows each connection's name, server, database and state. The form below it shows the selected connection: its state with Connect or Reload Schema and Disconnect, its fields, and Remove Connection. Select Add, enter the server and database, then select Connect. Connect checks access and loads metadata. Reload Schema reads the metadata again while the connection stays Ready, so SQL Sessions keep their transactions and temporary tables. A failed reload, also one that cannot read the metadata, keeps the previous metadata. After a run that creates, alters, drops or renames a table, view, procedure, function, trigger, schema, synonym, type or sequence, or that makes a table with `SELECT ... INTO`, the metadata reloads by itself in the background. When that run leaves a transaction open, the reload waits until Commit, Roll Back or a later run ends the transaction, because the transaction's locks would block the read. A session that ends, for example with a lost connection or a closed SQL Query, also starts the reload, because a change that committed before the transaction opened stays. A change or a Reload Schema during a reload reads the metadata once more after it. A cancelled run of such SQL also reloads, because its earlier batches can have made the change. Temporary objects and `OUTPUT ... INTO` an existing table do not count. Dynamic SQL, such as `EXEC (N'CREATE TABLE ...')` or `sp_executesql`, does not start a reload; use Reload Schema after it. DbVisualizer treats its cached metadata as stale after 60 seconds (`MetaDataCacheStaleThreshold` in `dbvis.prefs`) and has a Clear Cache action in its completion list (`DbVisAutoCompletePopupWindow.refresh.all` in `dbvis-texts.properties`). Anvil reloads after the SQL that changes the catalog instead, so an unchanged catalog costs no reads. A change to a field disconnects the connection. An empty Dialog shows only Add Connection. Windows authentication hides the user and password fields.

Open a `.sql` file, select SQL as an Untitled Buffer's Language Mode, or use **SQL Server: New Query**. All three use the normal Editor. Selecting SQL does not connect to a server. Queries use normal editing, Save As, completion, and symbol navigation.

A SQL Editor without its own connection uses the Project's only connection. Completion works as soon as that connection is connected. The first explicit database command, such as Run Selection or Project Symbol Search, connects it if needed and keeps it for the Editor. The Editor keeps it when the Project adds another connection. When the Project has more than one connection, the first explicit command asks which one to use. **SQL Server: Choose Connection** changes an Editor's connection.

The Dialog has no separate database sidebar.

The Status Bar of a SQL Editor shows its connection, and its state when it is not Ready, such as Connecting or Failed. It also shows Auto Commit Off, an open transaction, a timeout and No Row Limit when they apply. A click chooses the connection.

## Database source

Symbol navigation reads the database object's source into a read-only SQL Editor. Back returns to the same Query. The definition inherits its connection and supports completion, navigation, and Run Selection. Table and view definitions include a SELECT example. Definitions are snapshots; reopening one reads it again. They are not saved in the Workspace.

**Project Symbol Search** lists the Project's database objects from any Pane. The Project's code symbols come first. Each connection then has its own group, with the connection's name as its header. A group lists the matching tables, views, procedures and SQL functions; an empty query lists them all. A procedure in a `.sql` file and the same procedure in the database are separate rows: the file and the server's version. Enter on an object opens its actions, with the default action first, so a second Enter runs it. Opening the result in a new Pane opens the object's source. A connection that is not Ready shows one row, Connect. That row connects, and then the search runs again.

**SQL Server: Generate Select**, **Insert**, **Update**, **Delete**, **Create**, and **Alter** act on the database symbol at the caret. Each supported command opens an editable SQL Buffer with the same connection. UPDATE and DELETE templates start with a false predicate. INSERT and UPDATE values require editing. Only a generated SELECT runs at once, so its rows show below it. Set `config.plugins.sql_server.run_generated_select` to false to stop this.

**SQL Server: Symbol Actions** opens a menu of the actions for the symbol at the caret. A SQL Editor's Context Menu shows the same menu under the symbol's name, then Run Selection, Explain Selection and Run Buffer. The first action is the default: Script as SELECT for a table, and Script as ALTER for a view, procedure or function. A keyboard-opened menu selects it, so Enter runs it.

Table scripts include column types, identity settings, computed columns, defaults, keys, checks, foreign keys, and ordinary indexes. They explicitly exclude storage options, triggers, and permissions. They are not complete database deployment scripts. Unsupported table features, disabled indexes, and disabled or untrusted constraints stop scripting instead of producing an incomplete declaration. Table ALTER generation is not available.

Module source comes from SQL Server. CREATE and ALTER generation changes its opening declaration, not its body. Generated scripts use the object's current name, also after a rename. Modules with ANSI_NULLS or QUOTED_IDENTIFIER OFF show their settings but offer no CREATE or ALTER script. Selected execution does not apply those settings automatically. Encrypted source, missing VIEW DEFINITION permission, and source limits produce an error. Source reads are bounded to 512 KiB and use the execution worker's bounded result reader.

## Run SQL

Use **SQL Server: Run Selection** (Ctrl+Enter) in a SQL Query. It runs the primary selection and does nothing when that selection is empty. **SQL Server: Run Buffer** explicitly runs the whole Buffer. Neither selects a statement at the caret. An edit, caret move, or focus change while a connection starts cancels the pending execution request.

A line with only `GO` ends a batch, as in SSMS. `GO 3` runs the batch three times. `GO` in a string, a quoted name or a comment is text. A failed batch does not stop the next batch. A run holds at most 100,000 batches, and a count is at most 1,000.

**SQL can change database data, even when selected from a read-only definition.** Cancellation does not undo committed changes.

## Sessions and transactions

Each SQL Query has its own SQL Session: one server connection that stays open between runs. Temporary tables, `SET` options and open transactions carry into the next run of the same Query. Other Queries do not see them. The first run opens the session. After `USE` moves a session to another database, the Status Bar names that database, and completion, Go to Definition and Expand Star stop in that Query, because the metadata describes only the connection's database. `USE` back, or a new Query, restores them. DbVisualizer instead offers a database selector in its SQL Commander (`SQLCommanderIsCatalogSelectable` in `dbvis.prefs`). In Anvil, each connection names one database. Disconnect, a settings change, a Project change, exit and closing the Query end it. The server then rolls back an open transaction.

Auto Commit is on by default. **SQL Server: Toggle Auto Commit** turns it off for one Query, like SSMS's implicit transactions. A statement that changes data then opens a transaction. A `SELECT` from a table also opens one. **SQL Server: Commit** and **SQL Server: Roll Back** end all open transactions of the Query. They also end a `BEGIN TRANSACTION` while Auto Commit is on. Auto Commit cannot turn on inside a transaction; Anvil asks to commit or roll back first.

Before an action ends a session with an open transaction, Anvil asks: Commit, Roll Back or Cancel. Closing the Query's last View, Disconnect, Remove Connection, Connect again and quitting ask this question. A field change in the Databases Dialog is refused until the transactions end. The open-transaction count comes from `@@TRANCOUNT` after each run. After a cancelled run, the state is unknown, and Anvil asks as if a transaction is open.

A lost connection ends the session. The server rolls back its transaction, and the next run opens a new session. Anvil has at most 64 open sessions.

A firewall or a gateway, such as Azure SQL's, can drop a session that is idle. So a run on a session that was idle for 60 seconds first sends `SELECT 1`, and waits at most 10 seconds for it. Only a connection error means that the session is gone. A slow answer, or no row because of `SET NOEXEC ON`, keeps the session, and the SQL runs on it. Cancel also stops this check. Then no SQL was sent, so the session keeps its transaction state, and its next run checks it again. When the session is gone and had no open transaction, a new session runs the SQL, and the messages tell that its temporary tables and `SET` options are gone. When a transaction was open, or its state is unknown, the run sends nothing and shows that the server rolled the transaction back. Anvil turns off the ODBC driver's own reconnect (`ConnectRetryCount=0`), because that reconnect is silent and would hide a lost session. DbVisualizer validates a connection in the same way: with its validation SQL, `select 1` for Azure SQL, or else the driver's check (`ConnectionValidationSelect` in `dbvis.prefs`, used in `com/onseven/dbvis/db/w_.java`). Its keep-alive is off by default (`ConnectionKeepAliveEnabled`). Anvil has no keep-alive either.

## Explain Plan

**SQL Server: Explain Selection** shows the estimated plan of the selection with `SET SHOWPLAN_ALL`. SQL Server compiles the statements but does not run them. The plan shows in the results View as a table, one row for each operator. The `StmtText` column shows the operator tree.

Results open below the Query without taking focus or moving the caret. Another run replaces that Query's results. The View reuses Tabular Data Preview's selection, copy, sorting, filtering, column sizing, and scrolling. `NULL` is distinct from an empty value. Numbers remain text, so large integers and decimals keep their precision. Binary values show as hexadecimal.

A click on a row number selects that whole row, and a drag or Shift+click over row numbers selects more rows. A click on the corner above the row numbers selects all cells. **Select Row** and **Select Column** select the row or column of the active cell. Home and End go to the ends of the row, Ctrl+Up and Ctrl+Down to the first and last row, Ctrl+Home and Ctrl+End to the corners, and Page Up and Page Down move one page. Shift with each of these extends the selection. DbVisualizer's row header also selects whole rows (`com/onseven/dbvis/bc/yb.java`), and its cell menu has Select Row(s) and Select Column (`select-row-command` and `select-column-command` in `dbvis-actions.xml`).

A column with an active filter shows a filter icon in its header. Other headers show the filter's `▾` button only under the pointer, as DbVisualizer has an active and a mouse-over filter icon (`getFilterIcon` in `com/onseven/dbvis/bc/ib.java`). A right-click on a column name opens its Context Menu: Sort Ascending, Sort Descending, Reset Sorting, Filter, Select Column and Copy Column Name. The cell Context Menu has Copy, **Copy with Column Names** (Ctrl+Shift+C), Copy As Markdown Table or Comma List, Select Row, Select Column, Select All and **Reset Sorting and Filters**, then the SQL commands. Copy with Column Names writes TSV with a first line of names. A Markdown Table escapes `|` and writes line breaks as `<br>`. A Comma List starts a new line for each selected column and leaves out NULL and empty values. A value with a comma, a double quote, a line break or a space at an end is in double quotes, as in CSV, so each value stays one value. DbVisualizer's list does not quote values by default (`QuoteTextData` is `None` in `com/onseven/dbvis/ic/g_.java`). These menus follow DbVisualizer's grid menus (`dataset-grid-column-header-popup` and `dataset-grid-cell-popup` in `dbvis-actions.xml`). Its copy commands are in `com/onseven/dbvis/bc/mb.java`: the comma list goes column by column (`CsvColumnByColumn`), and the Markdown table escapes `|` (`com/onseven/dbvis/bc/n.java`).

Each column fits its name and its longest values when it first shows, up to 480 pixels. The fit reads the first 500 rows and measures the three longest values of each column, so a wide table opens fast. A double-click on a column border, **Fit Column** and **Fit All Columns** fit again. DbVisualizer also fits columns by default, with their headers (`FitTables=true` and `FitTablesConsiderHeader=true` in `dbvis.prefs`; `com/onseven/dbvis/bc/pb.java`). Its default has no width limit (`GridColumnSeparatorWidth=-1`).

`NULL` shows in the dim text color, so it differs from the text `'NULL'`. DbVisualizer also gives NULL cells their own color (`dbvis.grid.nullCellForeground` in `dbvis-themes.xml`). Number columns align at the right, so their digits line up. A value wider than its column shows its start and "…", also a number, so a narrow column never shows only the last digits.

A column of an integer, decimal, money or floating-point type sorts by value. The compare is exact for decimals and large integers. Other columns sort as text, without case, and dates sort in order because the server sends them as ISO text. Use `ORDER BY` for the server's collation. Copy uses tab-separated text, with `NULL` as an empty field.

Use **SQL Server: Next Result** and **Previous Result** for a batch with several tables. The result's Context Menu offers these commands, **View as CSV**, **View as JSON**, **Messages** and **Go to Error**. View as CSV and View as JSON open the rows that the table shows, in its sort order, in a new Untitled Editor. They write no file. Values stay the server's text: CSV writes NULL as an empty field and an empty string as `""`, and JSON writes NULL as `null` and each value as a string. A repeated column name gets a number in JSON, such as `id (2)`. **SQL Server: View Cell** in the Context Menu opens the value of the selected cell in a new Untitled Editor, with its line breaks. A value that starts with `{` or `[` opens as JSON, and a value that starts with `<` opens as XML. The text is not reformatted. A cell keeps at most 32,768 UTF-16 units, and View Cell warns when SQL Server sent more; select a part with `SUBSTRING` to read the rest. DbVisualizer has the same viewers, among others (`Viewer.jsonViewer` and `Viewer.xmlViewer` in `com/onseven/dbvis/bc/i/l.java`). Messages shows the server's messages in order: `PRINT` text, warnings, row counts and errors in SSMS's `Msg` format. Error lines count from the first line of the submitted text. An error inside a called procedure, function or trigger names it and gives its own line, such as `Procedure fail_late, Line 3`, as in SSMS. That line is not a Query line. An error in the batch that creates that procedure keeps its Query line. **SQL Server: Go to Error** moves the caret to the first error's line in the Query. That line moves with later edits, like DbVisualizer's error position marker (`SQLCommanderShowErrorPositionMarkers` in `dbvis.prefs`). Results do not enter the Workspace or modify the Query.

Use **SQL Server: Cancel** from the Query or its results. Closing the results, closing the Buffer, disconnecting, or changing connection settings also requests cancellation. A login can take up to its 15-second timeout before cancellation takes effect. All database calls run off the UI thread.

The results View has a footer with a summary and buttons. The summary shows the rows, the columns and the run time, such as `100 rows · 4 columns · 12 ms`. A column filter adds the count that it shows, such as `37 of 100 rows`. This follows DbVisualizer's rows and columns item (`RowsColsStatusBarItem` in `com/onseven/dbvis/bc/h/j.java`), which shows the filtered count beside the total. The buttons are Cancel while the SQL runs, the Query's row limit, CSV, JSON and Messages. The row limit button chooses 100, 1,000 or 10,000 rows, or No Row Limit, for that Query. **SQL Server: Toggle Row Limit** turns the limit off or back to the default. Without a limit, results stop at 100,000 rows and the limits below. A change does not run the SQL again. The button shows in the warning color when the limit cut a result.

With two or more cells selected, the footer shows their aggregates in the place of the summary: the cell count, the NULL count and, when each other cell is a number, Sum, Avg, Min and Max, such as `5 cells · 1 NULL · Sum 10.64 · Avg 2.66 · Min -2 · Max 12.3400`. Values are the server's text, and pending edits count. A sum of decimal text is exact while it has at most 15 digits. A larger sum, or a value with an exponent, shows `≈`. Min and Max keep the cell's text. A text column with digits in each cell, such as postal codes, also gets a Sum.

The default row limit is 1,000 per table. A run has no timeout by default, as in DbVisualizer. It sets no query timeout; only its calls on the event thread time out (`com/onseven/dbvis/jdbc/b/g.java`). Cancel stops a run. **SQL Server: Set Timeout** sets a timeout in seconds for one Query, and 0 removes it. Set `config.plugins.sql_server.max_rows` from 1 to 100,000, and `config.plugins.sql_server.timeout_seconds` from 0 (none) to 86,400. Metadata reads, Table Design and the result edit check keep their own short timeouts.

The text of one run is limited to 64 MiB, which only guards memory. DbVisualizer also runs very large scripts and only offers to skip its own preprocessing (`ExecutorHandler.RecommendSingleStatementProcessing` in `com/onseven/dbvis/o/c/h.java`); Anvil's only preprocessing is the `GO` split. Completion stops above 256 KiB of text, and SQL History skips a run above 64 KiB. Each run keeps at most 16 results, 262,144 values and 8 MiB of value text. A value holds at most 32,768 UTF-16 units. A longer value keeps its start, and the result says so; it does not say that the row limit stopped the read. Table Design refuses a table with such a value in its definitions. A limit only cuts what the run keeps: the SQL still runs to its end. A result after the 16th shows only a message, and a result past the value limits shows its first rows. A warning marks incomplete results. After the row limit, SQL Server still sends the rest of the result, and Anvil discards it. A very large result over a slow network can take a long time; Cancel stops it.

## Edit results

The values of a result can change before you write them to the table. Use **SQL Server: Edit Cell** (F2, Enter or a double-click), **Set to NULL** and **Delete Rows** (Delete) in the results View or its Context Menu. The first edit asks SQL Server to describe the run's SQL with `sp_describe_first_result_set` in browse mode. That call runs no statement and opens no transaction. It uses the Query's SQL Session, so temporary tables and the current database stay the same.

A result can change when it is the only result of its run and a column comes from a table. The table must have a primary key or a unique key, and the result must include all its key columns. Only columns of that table can change. Computed columns, columns of other joined tables, binary and spatial values, and values with line breaks cannot change here. A value longer than 32,768 characters cannot change here either, because Anvil keeps only its start. Script Rows as INSERT refuses rows with such a value, Script Rows as SELECT leaves it out of its conditions, and View as CSV and View as JSON warn about it.

Changed cells show in the accent color, and deleted rows show in the error color. The footer shows **Script N Changes** and **Discard**. A new run discards the edits. **SQL Server: Script Changes** opens a new SQL Query on the same connection with one `UPDATE` or `DELETE` for each row, in one transaction. Each statement finds its row by the key values that the result showed. Values are Unicode string literals, and SQL Server converts them to the column's type. A statement that does not change exactly one row stops the script, and `XACT_ABORT` rolls back its earlier statements. **The script does not run by itself.** Read it, then run it as other SQL. Anvil does not compare the other columns, so a change that another user made after your run can be overwritten.

**Script Rows as INSERT** and **Script Rows as SELECT** in the Context Menu script the selected rows of the same table, also in a new SQL Query that runs nothing. They need the same describe call and the same kind of result. Script Rows as INSERT writes the rows' shown values, with pending edits, for each column that can change. Identity and computed columns stay out, so the rows get new identity values. It writes at most 1,000 rows in each `INSERT`. Script Rows as SELECT finds the table rows that have the selected cells' values as the server sent them: one condition for each selected row, joined with `OR`.

## SQL History

Each run of a SQL Query goes into the Project's SQL History, with its connection, time, duration and status: OK, Error or Cancelled. The list shows a duration of 1 second or more. Explain Plan runs do not. **SQL Server: SQL History** lists the runs, newest first. Type to search their SQL. The chosen SQL opens in a new SQL Query on its connection, or without a connection when the connection is gone. **It does not run.** A run of the same SQL on the same connection as the newest entry counts in that entry, such as `×3`.

The history belongs to the Project, as its connections do. Scratch has its own. It is saved as text in the user folder, so SQL that holds a secret stays on disk. `config.plugins.sql_server.history_entries` keeps the newest 500 entries; 0 turns the history off. SQL longer than 64 KiB is not kept. **SQL Server: Clear SQL History** deletes the Project's history.

## Format SQL

**SQL Server: Format SQL** formats the lines of the selection, or the whole Buffer when nothing is selected. The Editor's Context Menu also offers it. One undo reverts it. It uses DbVisualizer's default layout:

```sql
SELECT
    c.id,
    count(*) AS orders
FROM
    sales.customers c
LEFT JOIN
    sales.orders o
ON
    o.customer_id = c.id
WHERE
    c.active = 1
AND c.region IN ('north', 'south')
GROUP BY
    c.id
```

Each main keyword starts a line, and its content goes one level deeper. Each list item gets its own line, and each `AND` and `OR` of a `WHERE`, `ON` or `HAVING` starts a line. `CASE` puts each `WHEN` and `ELSE` on its own line. A subquery goes one level deeper than its parenthesis. Reserved keywords become uppercase. Other names keep their case. The indentation is the Buffer's, not DbVisualizer's fixed 4 spaces.

Only `SELECT`, `INSERT`, `UPDATE`, `DELETE` and `WITH` statements change, also inside `CREATE VIEW` and procedures. Other statements, such as `CREATE TABLE`, `DECLARE` and `MERGE`, keep their lines. Strings, quoted names, comments and `GO` lines stay as they are. Text from a comment that holds `FORMAT_OFF` to a comment that holds `FORMAT_ON` keeps its text and case.

Format SQL changes only the whitespace between tokens and the case of reserved keywords. It reads the result again, and a statement whose tokens would change keeps its text. Format SQL runs nothing and needs no connection. It refuses a read-only Buffer and text above 4 MiB.

## Table Design

**SQL Server: Design Table** opens the Table Design Dialog for the table at the caret. The table's Context Menu and **SQL Server: Symbol Actions** also offer it. **SQL Server: New Table** opens an empty design. The Dialog reads the table's columns, primary key, indexes, unique constraints, foreign keys and check constraints from the catalog, with a separate connection. The Query's SQL Session and transaction do not change.

The pages are Table, Columns, Primary Key, Foreign Keys, Indexes and Check Constraints. Each change applies to the design at once. **Open Script** opens a new SQL Query on the same connection with the `CREATE TABLE` or `ALTER TABLE` script. **The script does not run by itself.** Read it, then run it as other SQL. The footer shows the first problem of the design, such as a foreign key without a referenced table; a design with problems opens no script. A closed design stays until the next connect, so the Dialog opens it again with its changes. An opened script ends the design.

An `ALTER` script runs in one transaction with `XACT_ABORT`. It drops the changed foreign keys, checks, indexes, keys, defaults and columns first. It then renames and alters columns, adds columns, and adds the keys, indexes, checks and foreign keys again. It renames the table last. A change to a column's type, collation or nullability rebuilds each key, index and check that uses the column. SQL Server adds a new column at the end, so only a new table orders its columns. The identity of an existing column cannot change.

Some items have options that the Dialog does not show, such as a filtered index, an index with included columns, a disabled constraint or a computed column. They are locked: the script keeps them as they are, or drops them when you remove them. A column that a locked item uses cannot change, because a rebuild would lose those options. Foreign keys in other tables that reference this table's primary key are not part of the design. A script that rebuilds that key fails, and `XACT_ABORT` rolls it back.

## Connections and persistence

Connection settings belong to the current Project on this PC. Scratch has its own saved connections; it does not share them with other Projects. Its Dialog title shows **Project Databases — Scratch**. Each open query remembers its connection. Workspace restore and Untitled recovery keep that identity. Save As keeps it while the query remains open or saved in the Workspace. Opening a saved SQL file without its Workspace state requires choosing its connection again.

A Project connects its connections when it opens, after Workspace restore. A connection with Windows authentication connects at once, also while its Project loads in the background. A connection with a SQL login asks for its password once, when its Project first shows and no other Dialog is open. Close that prompt to stay disconnected; the next database command asks again. A connect that fails at open shows no error. The Status Bar shows Failed, and the next database command tries again. Connecting only loads metadata. It runs no SQL. Set `config.plugins.sql_server.connect_on_open` to false to connect only on a database command or with Connect in the Databases Dialog. Explicitly closing an Untitled Query keeps the normal discard confirmation.

Windows uses Microsoft ODBC Driver 18, or Driver 17 when 18 is absent. Windows authentication and SQL login are supported. Passwords are masked and are not saved. A successful Connect keeps the password in memory for query runs. Disconnect, a connection change, a Project change, or exit clears it. Enter it again for each connection attempt.

TLS defaults to certificate verification. Trust Certificate keeps encryption but accepts an unverified certificate. No Encryption is an explicit choice for servers such as LocalDB. Anvil never selects it after a failed encrypted connection.

Metadata reads run on a worker. They use fixed SQL Server catalog queries, request read-only access, and close the connection afterward. Ready means that the login works and a metadata snapshot is available. Each Query's SQL Session is a separate connection. Completion reads that snapshot without network access. Disconnect and connection changes discard it. Late results cannot replace a newer connection state.

A database with more than 50,000 table and view columns loads only its list of objects. Each table's columns then load the first time completion, star expansion or Table Design needs them, and stay until the next connect. Completion opens again when they arrive, if the caret has not moved. The object list stops at 200,000 objects. The foreign keys load with the objects. A database with more than 50,000 foreign key column pairs, or a failed read of them, gives no join conditions, and the rest of the metadata stays. When the login works but a metadata read fails, for example without permission, the connection is still Ready and SQL runs. The Status Bar then shows No Metadata, and its tooltip gives the reason. Completion and Symbol Search have no objects until Reload Schema succeeds.

## Supported SQL context

The native parser supports SELECT scopes, `UPDATE`, `DELETE`, `INSERT` and `MERGE` statements, FROM, JOIN and USING sources, aliases, schema-qualified tables, bracketed identifiers, quoted identifiers, comments, and strings. Semicolons and standalone GO lines separate statements. Nested SELECT scopes use their own sources. The target of an `UPDATE`, `DELETE`, `INSERT` or `MERGE` is a source of its `SET`, `WHERE`, `ON` and `WHEN` parts, with the sources of its `FROM` or `USING`. `UPDATE c ... FROM sales.customers c` names its target by an alias. An `INSERT` column list offers only the target's columns, also after a table hint such as `WITH (TABLOCK)`, and `VALUES` offers none. In a `MERGE`, `VALUES` offers the columns of the target and the source. An `UPDATE` target names the `FROM` entry with the same exposed name, as in SQL Server: its alias, or else its table name without the schema. So `UPDATE sales.customers ... FROM customers` lists the table once, and `UPDATE customers ... FROM sales.customers c` lists two sources. A `MERGE` table hint, such as `WITH (HOLDLOCK)`, keeps the alias after it. In `OUTPUT ... INTO archive (`, the column list offers only the columns of `archive`. A `FOR SYSTEM_TIME` clause keeps the alias after it. The nearest statement before the caret wins, so a statement needs no semicolon. DbVisualizer has the same contexts (`map.insertIntoTable` and `map.columnList` in `com/onseven/dbvis/b/c/k_.java`). Completion inserts quoted names when needed and replaces the complete token at the caret.

The token before the caret decides whether completion opens:

- After a keyword that starts a list of names, such as `SELECT`, `WHERE`, `AND`, `ON` or `BY`, and after `,`, `(` or `.`, completion opens at once.
- After an operator or a value keyword, such as `=`, `<>`, `LIKE`, `IN (`, `BETWEEN`, `THEN` or `TOP`, you usually type a value. Completion opens when you type a letter, such as `email <> n`, or when you ask for it. In a JOIN's `ON`, a comparison opens at once, because the other side is usually a column.
- After a complete name, value or parenthesized group, no existing name follows, but a keyword can. Completion offers the keywords of the caret's clause when you type a letter, most likely first: `WHERE email l` offers `LIKE`, `ORDER BY name d` offers `DESC`, and `CASE WHEN a = 1 t` offers `THEN`. Where the typed word can be an alias, such as after `FROM sales.customers ` or `SELECT name `, keywords show only when you ask, so an alias types without a list. Keywords that lead to another keyword offer it: `LEFT` offers `JOIN`, `ORDER` offers `BY`, and `IS` offers `NULL` and `NOT NULL`. Keywords take the case of the nearest keyword before the caret, so `select … where email l` offers `like`.
- After `AS`, and in a typed number, completion stays closed.

At the start of a JOIN's `ON`, the list starts with the join conditions from the foreign keys between the joined table and each table before it. In `FROM sales.customers c JOIN dbo.orders o ON ▮`, a key from `orders.customer_id` to `customers.id` offers `c.id = o.customer_id`. The earlier table comes first, whichever end of the key it is. A key with several columns offers one condition, its pairs joined with `AND`. A table that references itself, joined to itself, offers both directions. The key's name is the row's description, and the columns follow. Conditions need no loaded columns, so they also work in a database over the column limit. A local source, such as a CTE or a derived table, has no keys. DbVisualizer builds the same `a = b` conditions from foreign keys (`c` in `com/onseven/dbvis/b/c/b/e.java`) and joins a key's pairs with ` AND ` (`getReplacementText` in `com/onseven/dbvis/b/c/b/db.java`). It uses the keys among all of the statement's tables (`b_11` in the same file); Anvil offers only the keys of the table that the JOIN adds, at the start of the `ON`. Its setting is `SQLCommanderAutoCompleteJoins`, on by default in `dbvis.prefs`.

A typed `@` lists the variables that the batch declares before the caret, in their order, with their types: `DECLARE` lists and the parameters of the `CREATE` or `ALTER` procedure or function. This works in any statement, such as `SET`, `IF`, `PRINT` and `EXEC` arguments. A `GO` line starts a new batch, and a table variable is a source, not a value. While you type a new name in a declaration, no list opens. A typed `@@` lists the common system functions, such as `@@ROWCOUNT`, `@@IDENTITY` and `@@TRANCOUNT`. DbVisualizer has no source model for this: its `@` completion lists its own client-side commands (`ib` in `com/onseven/dbvis/b/c/b/ib.java`).

In the arguments of `EXEC [schema.]procedure`, after the procedure's name or a comma, completion lists the procedure's parameters, in their order, with their types. An `OUTPUT` parameter shows `OUTPUT` after its type. Tab inserts `@id = `. Parameters that earlier arguments set, by position or by name, do not show. A typed `@` filters the list. Positional values, such as `1` or `'x'`, close it. The catalog reads the parameters of procedures and functions from `sys.parameters`, up to 50,000 in a database. Above that limit, or when the object list is cut, the catalog has no parameters, and a typed `@` lists the batch's variables. DbVisualizer has no completion for procedure parameters: its completion kinds (`_b` in `com/onseven/dbvis/b/c/v.java`) are catalogs, schemas, tables, columns, joins, keywords and its client-side commands.

Where an expression goes, such as in `SELECT`, `WHERE`, `ON`, `ORDER BY` or an `UPDATE`'s `SET`, a typed name also offers the built-in functions that start with it, after the matching columns. The row shows the function's arguments, such as `COUNT (expression)`. Tab inserts `COUNT()` with the caret between the parentheses. A function without arguments, such as `GETDATE()`, leaves the caret after them. Functions take the case of the nearest keyword before the caret, as keywords do. The list holds about 80 common aggregate, window, conversion, string, date, math and JSON functions, not every built-in. After a qualifier, such as `c.`, and in a `FROM`, functions do not show. DbVisualizer lists function names as plain words among its keywords: its keyword maps tag them `FUNCTION` (`b_3` in `com/onseven/dbvis/db/r_.java`), and its keyword list `h()` holds all entries.

Tables, objects and columns match the typed text anywhere in their names. The list shows the exact name first, then the names that start with the typed text, then the names that only contain it, each group by name: `WHERE i` offers `id` before `customer_id`. DbVisualizer accepts a name that starts with the typed text (`b_20` in `com/onseven/dbvis/b/c/b/t.java`) or contains it (`b_35` in `com/onseven/dbvis/util/gb_.java`).

A keyword is a word in Microsoft's list of reserved T-SQL keywords, or `APPLY`, `OUTPUT`, `USING` or `TIES`. `END`, `NULL`, `ASC`, `DESC` and similar keywords end a value, as a name does. DbVisualizer chooses the same way from the token before the caret (`g_.q()` in `com/onseven/dbvis/b/c/g_.java`). It also offers keywords after a complete term, but all of them: the generic SQL keywords and the database's own, filtered only by the typed text, not by the clause (`b` in `com/onseven/dbvis/b/c/b/v.java`, which reads `h()` in `com/onseven/dbvis/db/r_.java`). DbVisualizer offers columns after an operator, but by default it opens its list only when you ask (`AutoCompletionAutoPopup=false`).

Object navigation also recognizes EXEC, INSERT INTO, UPDATE, DELETE FROM, REFERENCES, and CREATE or ALTER object declarations. **SQL Server: Expand Star** replaces the projection `*` at the caret with its source columns. It supports an alias-qualified star and qualifies joined columns. It changes no database data. One undo restores the star.

Unqualified table lookup follows the database user's default schema, then `dbo`. Ambiguous column navigation does not choose a table. Joined-column completion qualifies its inserted names.

The Query text also defines Local Sources: CTEs of the caret's statement, derived tables, and the temporary tables and table variables of the whole text. Their columns come from the text: a column list, `CREATE TABLE #name (...)`, `DECLARE @name TABLE (...)`, or the names of a SELECT's columns, also `SELECT ... INTO #name`. A SELECT column has a name when it is a column, `expression AS name`, `expression name` or `name = expression`. Completion offers these columns and the names of CTEs, temporary tables and table variables. Expand Star uses them. A Local Source hides a database table with the same name, and Go to Definition does not open that table. A Local Source with `*` in its SELECT has no column list, so Expand Star refuses it.

A table-valued function, such as `sales.customers_from(1) AS c`, is a source with the function's columns. After `FROM`, `JOIN` and `APPLY`, completion lists the database's table-valued functions with the tables and views. The row shows the parameters, such as `customers_from (@first int)`. Tab inserts `sales.customers_from()` with the caret between the parentheses, or after them for a function without parameters. Scalar functions do not show there. DbVisualizer's table completion (`pb` in `com/onseven/dbvis/b/c/b/pb.java`) reads its metadata cache of tables (`f_2` in `com/onseven/dbvis/t/b/b_.java`).

A source without metadata, such as `OPENJSON` with its `WITH` list, a function with a column list after its alias, a `VALUES` list or a cross-database name, offers no columns. The other sources of the statement keep their columns, and the caret in its arguments is a column position. `CROSS APPLY` and `OUTER APPLY` sources work like joins. Correlated outer references, and temporary tables that another Query or an earlier text made, are not supported. This is not a complete T-SQL parser or a Tree-sitter SQL grammar. Context reads stop above 256 KiB, 32,768 tokens, 64 nested SELECT scopes, 64 sources, 64 Local Sources, or 2,048 Local Source columns.

## Source reference

The reference checkout is `D:/Projects/dbvisualizer`, DbVisualizer 26.2.4.4705. Its recovered Java names are shortened.

The selected completion path has these parts:

- `com/onseven/dbvis/b/c/b/p.java` selects a completion provider from SQL context.
- `com/onseven/dbvis/b/c/eb.java` scans tokens and records the context at the caret.
- `com/onseven/dbvis/b/c/g_.java` keeps nested SQL contexts and visible tables.
- `com/onseven/dbvis/b/c/k_.java` and `com/onseven/dbvis/b/c/ib.java` open a context for a WITH clause.
- `com/onseven/dbvis/b/c/b/pb.java` supplies table candidates.
- `com/onseven/dbvis/b/c/b/x.java` supplies column candidates.
- `com/onseven/dbvis/b/c/b/e.java` supplies join conditions from foreign keys, before the column candidates.
- `com/onseven/dbvis/b/c/b/gb.java` schedules background work and rejects obsolete results.
- `com/onseven/dbvis/t/b/b_.java` (`MetaDataCacheWorker`) loads tables and columns on demand. Anvil reads one table's columns on first use only when a database is over its column limit.

Anvil follows this context/provider structure for the supported cases. It does not port Swing, JDBC, or the complete product. Native ODBC and workers replace those platform boundaries. Existing Editors, completion providers, Dialog controls, and navigation supply the UI.

For execution, `com/onseven/dbvis/o/f/l.java` supplies the reference for multiple results and cancellation from another thread. `com/onseven/dbvis/o/f/z.java` and `com/onseven/dbvis/db/s_.java` supply the row-limit reference. Anvil keeps its own bounded result model and uses its existing table View.

The `GO` delimiter follows `SQLAllowGo` in `com/onseven/dbvis/d/e.java` and `com/onseven/dbvis/lb/i.java`. Auto Commit for each editor follows `com/onseven/dbvis/i/d.java`. The Commit, Roll Back or Cancel question follows `PendingTransactionsProps` in `com/onseven/dbvis/hb/e/b/b/ec.java`. SQL Server explain uses `SET SHOWPLAN_ALL`, as `com/onseven/dbvis/db/vb/c.java` does.

Result editing follows `TableEditableCommitter` in `com/onseven/dbvis/bc/j/b/c.java` and `com/onseven/dbvis/bc/j/b/d.java`: each edit must affect exactly one row, and the key columns identify it (`TableEditableResultDialog.keyColumnChooser` in `com/onseven/dbvis/bc/j/b/s.java`). DbVisualizer commits the edits itself, in batches (`InlineEditorCommitBatchSize` in `com/onseven/dbvis/nb/s.java`). Anvil writes them to a script instead, and the user runs it.

SQL History follows `HistoryGridPanel` in `com/onseven/dbvis/u/b/b.java` and `com/onseven/dbvis/u/c/b.java`: an entry keeps its connection, time, elapsed time and errors, and a run of the newest entry's SQL counts in that entry (`SQLHistoryIgnoreDuplicateEntries`, on by default in `dbvis.prefs`). DbVisualizer loads an entry into its SQL Commander. Anvil opens it in a new SQL Query.

Script Rows follows the grid commands `script-insert-row-copy-command` (INSERT COPY INTO TABLE) and `script-select-star-from-where-command` (SELECT ALL WHERE) in `dbvis-actions.xml`.

The cell aggregates follow DbVisualizer's Aggregates Viewer (`DataSetGridAggregation` texts; the counts in `com/onseven/dbvis/bc/e/l.java` and the metrics in `com/onseven/dbvis/bc/e/j.java`): Cells, Nulls, Sum, Avg, Min and Max for the selected cells. DbVisualizer also counts the cells of each type and shows a median and a standard deviation in a separate panel. Anvil shows the short list in the results footer.

Format SQL follows the default profile of DbVisualizer's formatter (`com/onseven/dbvis/objects/e/q.java`, which uses the SQLinForm library through `com/onseven/dbvis/kb/d.java`). The `Pretty*` keys in `dbvis.prefs` give the rules: `PrettyBreakAfterComma`, `PrettyBreakBeforeAndOr`, the `PrettyBreakAfter*` and `PrettyBreakFor*` clause and `CASE` keys, `PrettyKeywordCase=Keywords Uppercase`, and `PrettyNoFormattingBetween` with `FORMAT_OFF` and `FORMAT_ON`. Anvil's formatter is its own native module (`src/sql_format.c`), not SQLinForm, so its output can differ in details.

Table Design follows the tabs of `TableDetailsPanelBuilder` in `com/onseven/dbvis/objects/e/c/b/b/z.java`: columns (`ab.java`), primary key (`e.java`), foreign keys with their delete and update actions (`fb.java`), indexes and unique constraints (`d.java`), and check constraints (`j.java` and `c.java`). DbVisualizer shows the script in its Dialog and can run it. Anvil opens the script in a SQL Query instead, and the user runs it.

## Tests

Default UI tests replace the database boundary at `plugins.sql_server.backend` with fixed metadata and execution replies. The real Dialog, Editor, persistence, completion, navigation, and result View run unchanged. They need no SQL Server, driver, credentials, or network access. Runtime input tests reject invalid batches before a connection opens.

```sh
meson test -C build-windows-x86_64 anvil:sql-context
meson test -C build-windows-x86_64 anvil:sql-batch
meson test -C build-windows-x86_64 anvil:sql-format
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_context.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_execution.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_definitions.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_table_design.lua
meson test -C build-windows-x86_64 anvil:lua-runtime --test-args runtime/sql_aggregate.lua
meson test -C build-windows-x86_64 anvil:lua-ui --test-args ui/sql_server.lua
```

The real-server test is opt-in. It needs an existing LocalDB installation and Microsoft ODBC Driver 18 or 17. It creates a uniquely named instance and a database in a private temporary folder. It checks metadata, its foreign keys, procedure parameters, the columns of a table-valued function, the column reads of a catalog over its column limit, escaped identifiers, unchanged table data, and connection-value isolation. Execution checks cover multiple results, update counts, exact values, Unicode, embedded NUL, limits, errors, and cancellation. Session checks cover `GO` batches and error lines, a batch with more than 100,000 results, the database after `USE`, errors inside procedures, temporary tables between runs, Auto Commit off, Commit and Roll Back, Explain Plan, a session after a cancelled run, an idle session with `NOEXEC` on, an idle session that the server dropped, and the rollback when a session closes. Result edit checks cover the browse-mode description of a result, a scripted update, and the rollback of a script whose row is gone. The Table Design check reads a table in a transaction, applies its `ALTER` script, and rolls back. It then deletes its instance and files. It never reads user connection settings or connects to another instance.

```sh
ANVIL_SQL_INTEGRATION=1 meson test -C build-windows-x86_64 anvil:sql-server-integration --print-errorlogs
```

Without opt-in or dependencies, the test reports SKIP, not PASS. It installs nothing. LocalDB tests use Windows authentication and explicitly disable TLS because LocalDB does not support it. They do not prove remote TLS or SQL-login behavior.

The `databases-dialog`, `sql-results`, `sql-symbols`, `sql-table-design` and `sql-table-design-foreign` render scenarios use fixed data on a private desktop. They make no database connection.

## References

- [SQL editing and completion](https://www.dbvis.com/docs/26.2/working-with-sql/editing-sql-scripts/)
- [Connection, database, and schema selection](https://www.dbvis.com/docs/26.2/working-with-sql/selecting-database-connection-catalog-and-schema/)
- [Tab persistence](https://www.dbvis.com/docs/26.2/getting-the-most-out-of-the-gui/preserving-tabs-between-sessions/)
- [Connection configuration](https://www.dbvis.com/docs/26.2/database-connection-options/create-a-new-database-connection/)
- [Editable result restrictions](https://www.dbvis.com/docs/26.2/working-with-result-sets/editing-a-result-set/)
- [LocalDB encryption limitation](https://github.com/dotnet/SqlClient/issues/1395)
