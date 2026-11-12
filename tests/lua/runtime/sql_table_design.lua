local test = require "core.test"
local design_model = require "plugins.sql_server.table_design"

-- A catalog reply as SQL Server gave it for this table:
--   CREATE TABLE sales.probe (id int IDENTITY(7,3) NOT NULL, parent_id int NOT NULL,
--     amount decimal(19,4) CONSTRAINT DF_amount DEFAULT 0, label nvarchar(40) COLLATE Latin1_General_CI_AS NULL,
--     doubled AS amount*2 PERSISTED, CONSTRAINT PK_probe PRIMARY KEY(id,parent_id),
--     CONSTRAINT FK_parent FOREIGN KEY(parent_id) REFERENCES sales.parent(id) ON DELETE CASCADE,
--     CONSTRAINT CK_amount CHECK(amount>=0), CONSTRAINT UQ_label UNIQUE(label));
--   CREATE UNIQUE INDEX IX_probe ON sales.probe(parent_id) INCLUDE(amount) WHERE amount>0;
--   CREATE INDEX IX_plain ON sales.probe(amount, label);
local function result(headers, rows)
  local out = { headers = headers, rows = {} }
  for i, cells in ipairs(rows) do out.rows[i] = { cells = cells } end
  return out
end
local N = false
local function reply()
  return { results = {
    result({ "object_id" }, { { "900" } }),
    result({ "column_id", "name", "type", "collation_name", "is_nullable", "is_identity", "seed", "increment",
      "default_name", "default_definition", "computed", "is_persisted", "locked" }, {
      { "1", "id", "int", N, "0", "1", "7", "3", N, N, N, N, "0" },
      { "2", "parent_id", "int", N, "0", "0", N, N, N, N, N, N, "0" },
      { "3", "amount", "decimal(19,4)", N, "1", "0", N, N, "DF_amount", "((0))", N, N, "0" },
      { "4", "label", "nvarchar(40)", "Latin1_General_CI_AS", "1", "0", N, N, N, N, N, N, "0" },
      { "5", "doubled", "decimal(21,4)", N, "1", "0", N, N, N, N, "([amount]*(2))", "1", "0" },
    }),
    result({ "index_id", "name", "kind", "is_unique", "type", "column_id", "locked" }, {
      { "1", "PK_probe", "primary", "1", "1", "1", "0" }, { "1", "PK_probe", "primary", "1", "1", "2", "0" },
      { "2", "UQ_label", "unique", "1", "2", "4", "0" },
      { "3", "IX_probe", "index", "1", "2", "2", "1" },
      { "4", "IX_plain", "index", "0", "2", "3", "0" }, { "4", "IX_plain", "index", "0", "2", "4", "0" },
    }),
    result({ "object_id", "name", "ref_schema", "ref_table", "parent_column_id", "ref_column", "on_delete", "on_update",
      "locked" }, { { "901", "FK_parent", "sales", "parent", "2", "id", "CASCADE", "NO_ACTION", "0" } }),
    result({ "object_id", "name", "definition", "locked" }, { { "902", "CK_amount", "([amount]>=(0))", "0" } }),
    result({ "object_id", "minor_id", "column_id" }, { { "900", "5", "3" }, { "902", "0", "3" }, { "900", "3", "3" } }),
  } }
end
local function read() return test.not_nil(design_model.from_results("sales", "probe", reply())) end
local function named(list, name)
  for _, item in ipairs(list) do if item.name == name then return item end end
end

test.describe("SQL Table Design", function()
  test.it("reads the table's columns, keys, indexes, foreign keys and checks from the catalog", function()
    local design = read()
    test.equal(#design.columns, 5)
    local id, amount, doubled = design.columns[1], design.columns[3], design.columns[5]
    test.ok(id.identity and not id.nullable)
    test.equal(id.seed, "7")
    test.equal(amount.default, "((0))")
    test.equal(design.columns[4].collation, "Latin1_General_CI_AS")
    test.ok(doubled.locked)
    test.same(doubled.uses, { amount.key })
    test.equal(design.primary_key.name, "PK_probe")
    test.same(design.primary_key.columns, { id.key, design.columns[2].key })
    test.equal(named(design.indexes, "UQ_label").kind, "constraint")
    test.ok(named(design.indexes, "IX_probe").locked)
    local fk = design.foreign_keys[1]
    test.equal(fk.on_delete, "CASCADE")
    test.equal(fk.on_update, "NO ACTION")
    test.same(fk.ref_columns, { "id" })
    test.same(design.checks[1].uses, { amount.key })
    test.equal(design_model.alter_script(design), nil)

    local missing = reply()
    missing.results[1].rows[1].cells[1] = false
    local none, reason = design_model.from_results("sales", "probe", missing)
    test.equal(none, nil)
    test.equal(reason, "Table [sales].[probe] does not exist.")

    local long = reply()
    long.results[5].rows[1].cut = { [3] = true }
    none, reason = design_model.from_results("sales", "probe", long)
    test.equal(none, nil)
    test.equal(reason, "A definition in this table is longer than 32,768 characters.")
  end)

  test.it("alters only what changed, and rebuilds what uses an altered column", function()
    local design = read()
    local label = named(design.columns, "label")
    label.name = "title"
    label.type = "nvarchar(80)"
    local parent = named(design.columns, "parent_id")
    parent.default = "0"
    design.columns[#design.columns + 1] = { key = design_model.new_key(design), name = "note", type = "nvarchar(200)",
      collation = "", nullable = true, default = "N''" }
    design_model.remove(design, design.indexes, named(design.indexes, "IX_probe"), "index")
    named(design.indexes, "UQ_label").name = "UQ_title"
    design.checks[1].name = "CK_positive"
    design.foreign_keys[1].on_update = "CASCADE"
    design.name = "probe_renamed"
    test.same(design_model.problems(design), {})
    test.equal(design_model.script(design), table.concat({
      "SET XACT_ABORT ON;",
      "BEGIN TRANSACTION;",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [FK_parent];",
      "DROP INDEX [IX_probe] ON [sales].[probe];",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [UQ_label];",
      "DROP INDEX [IX_plain] ON [sales].[probe];",
      "EXEC sp_rename N'[sales].[probe].[label]', N'title', N'COLUMN';",
      "ALTER TABLE [sales].[probe] ALTER COLUMN [title] nvarchar(80) COLLATE Latin1_General_CI_AS NULL;",
      "ALTER TABLE [sales].[probe] ADD CONSTRAINT [DF_probe_renamed_parent_id] DEFAULT (0) FOR [parent_id];",
      "ALTER TABLE [sales].[probe] ADD [note] nvarchar(200) NULL CONSTRAINT [DF_probe_renamed_note] DEFAULT (N'');",
      "ALTER TABLE [sales].[probe] ADD CONSTRAINT [UQ_title] UNIQUE NONCLUSTERED ([title]);",
      "CREATE INDEX [IX_plain] ON [sales].[probe] ([amount], [title]);",
      "EXEC sp_rename N'[sales].[CK_amount]', N'CK_positive', N'OBJECT';",
      "ALTER TABLE [sales].[probe] ADD CONSTRAINT [FK_parent] FOREIGN KEY ([parent_id]) REFERENCES [sales].[parent] ([id]) "
        .. "ON DELETE CASCADE ON UPDATE CASCADE;",
      "EXEC sp_rename N'[sales].[probe]', N'probe_renamed';",
      "COMMIT TRANSACTION;",
      "",
    }, "\n"))
  end)

  test.it("drops a removed column after what uses it, and refuses a change that a computed column blocks", function()
    local design = read()
    local amount = named(design.columns, "amount")
    amount.type = "decimal(20,4)"
    test.same(design_model.problems(design), { "Computed column [doubled] uses [amount], so [amount] cannot change." })
    local script, problems = design_model.script(design)
    test.equal(script, nil)
    test.equal(#problems, 1)

    -- IX_probe has a filter and an included column, which a rebuild would lose.
    design = read()
    named(design.columns, "parent_id").type = "bigint"
    test.same(design_model.problems(design),
      { "[IX_probe] has options that Table Design does not show, so [parent_id] cannot change." })

    design = read()
    design_model.remove(design, design.columns, named(design.columns, "doubled"), "column")
    design_model.remove(design, design.checks, design.checks[1], "check")
    design_model.remove(design, design.columns, named(design.columns, "amount"), "column")
    design_model.remove(design, design.columns, named(design.columns, "parent_id"), "column")
    test.equal(#design.foreign_keys, 0)
    test.same(design_model.problems(design), {})
    test.equal(design_model.script(design), table.concat({
      "SET XACT_ABORT ON;",
      "BEGIN TRANSACTION;",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [FK_parent];",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [CK_amount];",
      "DROP INDEX [IX_probe] ON [sales].[probe];",
      "DROP INDEX [IX_plain] ON [sales].[probe];",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [PK_probe];",
      "ALTER TABLE [sales].[probe] DROP CONSTRAINT [DF_amount];",
      "ALTER TABLE [sales].[probe] DROP COLUMN [doubled];",
      "ALTER TABLE [sales].[probe] DROP COLUMN [amount];",
      "ALTER TABLE [sales].[probe] DROP COLUMN [parent_id];",
      "ALTER TABLE [sales].[probe] ADD CONSTRAINT [PK_probe] PRIMARY KEY CLUSTERED ([id]);",
      "CREATE INDEX [IX_plain] ON [sales].[probe] ([label]);",
      "COMMIT TRANSACTION;",
      "",
    }, "\n"))
  end)

  test.it("creates a new table with its keys, checks, foreign keys and indexes", function()
    local design = design_model.new_table("sales", "invoices")
    local customer = { key = design_model.new_key(design), name = "customer_id", type = "int", collation = "",
      nullable = false, default = "" }
    local total = { key = design_model.new_key(design), name = "total", type = "money", collation = "", nullable = false,
      default = "0" }
    design.columns[2], design.columns[3] = customer, total
    design.foreign_keys[1] = { key = design_model.new_key(design), name = "FK_invoices_customers", columns = { customer.key },
      ref_schema = "sales", ref_table = "customers", ref_columns = { "id" }, on_delete = "NO ACTION", on_update = "NO ACTION" }
    design.checks[1] = { key = design_model.new_key(design), name = "CK_total", condition = "total >= 0" }
    design.indexes[1] = { key = design_model.new_key(design), name = "IX_customer", kind = "index", unique = false,
      columns = { customer.key } }
    test.equal(design_model.script(design), table.concat({
      "CREATE TABLE [sales].[invoices] (",
      "    [id] int IDENTITY(1,1) NOT NULL,",
      "    [customer_id] int NOT NULL,",
      "    [total] money NOT NULL CONSTRAINT [DF_invoices_total] DEFAULT (0),",
      "    CONSTRAINT [PK_invoices] PRIMARY KEY ([id]),",
      "    CONSTRAINT [CK_total] CHECK (total >= 0),",
      "    CONSTRAINT [FK_invoices_customers] FOREIGN KEY ([customer_id]) REFERENCES [sales].[customers] ([id])",
      ");",
      "CREATE INDEX [IX_customer] ON [sales].[invoices] ([customer_id]);",
      "",
    }, "\n"))
    customer.name, customer.nullable = "ID", true
    design.primary_key.columns = { customer.key }
    test.same(design_model.problems(design), {
      "Two columns are named [ID].",
      "Primary key column [ID] cannot be nullable.",
    })
  end)
end)
