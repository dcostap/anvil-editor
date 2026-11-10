param([Parameter(Mandatory=$true)][string]$Probe, [string]$Editor)
$ErrorActionPreference = 'Stop'
if ($env:ANVIL_SQL_INTEGRATION -ne '1') {
    Write-Output 'SKIP: Set ANVIL_SQL_INTEGRATION=1 to test an isolated LocalDB instance.'
    exit 77
}
$localdb = Get-Command SqlLocalDB.exe -ErrorAction SilentlyContinue
if (!$localdb) {
    $localdb = Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Filter SqlLocalDB.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (!$localdb) { Write-Output 'SKIP: SQL Server LocalDB is not installed.'; exit 77 }
$localdbPath = if ($localdb.Source) { $localdb.Source } else { $localdb.FullName }
$drivers = (Get-Item 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Drivers' -ErrorAction SilentlyContinue).Property
if (!($drivers -contains 'ODBC Driver 18 for SQL Server') -and !($drivers -contains 'ODBC Driver 17 for SQL Server')) {
    Write-Output 'SKIP: Microsoft ODBC Driver 18 or 17 is not installed.'
    exit 77
}
$name = 'AnvilTest_' + [Guid]::NewGuid().ToString('N')
$folder = Join-Path ([System.IO.Path]::GetTempPath()) $name
[void](New-Item -ItemType Directory -Path $folder)
$created = $false
$connection = $null
$result = 1
try {
    & $localdbPath create $name
    if ($LASTEXITCODE -ne 0) { throw 'LocalDB instance creation failed.' }
    $created = $true
    & $localdbPath start $name
    if ($LASTEXITCODE -ne 0) { throw 'LocalDB instance startup failed.' }
    $connection = New-Object System.Data.SqlClient.SqlConnection("Server=(localdb)\$name;Database=master;Integrated Security=true;Connect Timeout=30")
    $connection.Open()
    $command = $connection.CreateCommand()
    $data = (Join-Path $folder 'data.mdf').Replace("'", "''")
    $log = (Join-Path $folder 'log.ldf').Replace("'", "''")
    $command.CommandText = "CREATE DATABASE AnvilTest ON (NAME=AnvilTest, FILENAME=N'$data') LOG ON (NAME=AnvilTestLog, FILENAME=N'$log')"
    [void]$command.ExecuteNonQuery()
    $connection.ChangeDatabase('AnvilTest')
    $command.CommandText = 'CREATE SCHEMA sales'
    [void]$command.ExecuteNonQuery()
    $command.CommandText = 'CREATE TABLE sales.customers (id int IDENTITY PRIMARY KEY, [na]]me] nvarchar(80) NULL); INSERT sales.customers ([na]]me]) VALUES (N''Example'')'
    [void]$command.ExecuteNonQuery()
    & $Probe "(localdb)\$name"
    $result = $LASTEXITCODE
    if ($result -eq 0 -and $Editor) {
        $command.CommandText = 'CREATE SCHEMA roundtrip'
        [void]$command.ExecuteNonQuery()
        $command.CommandText = 'CREATE TABLE sales.parent (id int PRIMARY KEY); CREATE TABLE sales.child (id int IDENTITY(7,3) NOT NULL, parent_id int NOT NULL, amount decimal(19,4) CONSTRAINT DF_amount DEFAULT 0, doubled AS amount*2 PERSISTED, CONSTRAINT PK_child PRIMARY KEY(id,parent_id), CONSTRAINT FK_parent FOREIGN KEY(parent_id) REFERENCES sales.parent(id) ON DELETE CASCADE, CONSTRAINT CK_amount CHECK(amount>=0)); CREATE UNIQUE INDEX IX_child ON sales.child(parent_id) INCLUDE(amount) WHERE amount>0;'
        [void]$command.ExecuteNonQuery()
        $command.CommandText = 'CREATE VIEW sales.customer_names AS SELECT [na]]me] FROM sales.customers'
        [void]$command.ExecuteNonQuery()
        $command.CommandText = "EXEC sp_rename 'sales.customer_names', 'renamed_names'"
        [void]$command.ExecuteNonQuery()
        $command.CommandText = 'CREATE TABLE sales.periods (id int PRIMARY KEY, start_at datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL, end_at datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL, PERIOD FOR SYSTEM_TIME(start_at,end_at))'
        [void]$command.ExecuteNonQuery()
        $command.CommandText = 'CREATE PROCEDURE sales.list_customers AS SELECT * FROM sales.customers'
        [void]$command.ExecuteNonQuery()
        $prefix = "CREATE PROCEDURE sales.long_text AS SELECT N'"
        $command.CommandText = $prefix + ('x' * (3999 - $prefix.Length)) + [char]0xd83d + [char]0xde42 + "'"
        [void]$command.ExecuteNonQuery()
        $editorPath = (Resolve-Path $Editor).Path.Replace('\', '/')
        $build = (Split-Path (Split-Path $editorPath -Parent) -Parent).Replace('\', '/')
        $repo = (Split-Path $PSScriptRoot -Parent).Replace('\', '/')
        $env:ANVIL_SQL_TEST_SERVER = "(localdb)\$name"
        # The isolated editor has a private USERPROFILE. Use this instance's pipe,
        # because LocalDB name lookup reads the real user's instance directory.
        $pipe = (& $localdbPath info $name | Select-String 'np:\\\\.+').Matches.Value
        if (!$pipe) { throw 'The test instance did not report its pipe.' }
        $env:ANVIL_SQL_TEST_PIPE = $pipe.Trim()
        & (Get-Command bash.exe).Source "$repo/tests/run-lua-tests.sh" $build $repo $editorPath 'tests/lua/runtime' 'sql-integration' 'runtime/sql_execution.lua'
        $result = $LASTEXITCODE
    }
    $command.CommandText = 'SELECT COUNT(*) FROM sales.customers'
    if ($command.ExecuteScalar() -ne 1) { throw 'The checks changed table data.' }
    $command.Dispose()
} finally {
    if ($connection) { $connection.Dispose() }
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    if ($created) {
        & $localdbPath stop $name -k
        if ($LASTEXITCODE -ne 0) { throw "Could not stop test instance $name" }
        & $localdbPath delete $name
        if ($LASTEXITCODE -ne 0) { throw "Could not remove test instance $name" }
    }
    Remove-Item -LiteralPath $folder -Recurse -Force
}
exit $result
