defmodule Sheaf.Assistant.SpreadsheetSessionTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.SpreadsheetSession
  alias Sheaf.XLSXFixture

  @tag :tmp_dir
  test "loads xlsx files into an in-memory DuckDB session", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")

    XLSXFixture.write_xlsx!(xlsx_path, [
      ["buyer_type", "amount"],
      ["agency", "3"],
      ["municipality", "7"]
    ])

    id = "spreadsheet-test-#{System.unique_integer([:positive])}"
    session = start_supervised!({SpreadsheetSession, id: id, directory: tmp_dir})

    assert {:ok, [%{sheets: [%{table_name: table, row_count: 2, col_count: 2}]}]} =
             SpreadsheetSession.list(session)

    assert {:ok, %{rows: [%{"buyer_type" => "agency", "amount" => "3"}]}} =
             SpreadsheetSession.query(
               session,
               """
               CREATE TEMP VIEW agency_rows AS
               SELECT buyer_type, amount FROM "#{table}" WHERE buyer_type = 'agency';

               SELECT * FROM agency_rows;
               """
             )

    assert {:ok, [%{row_number: 2, row: %{"buyer_type" => "municipality"}}]} =
             SpreadsheetSession.search(session, "municipality")
  end

  @tag :tmp_dir
  test "locks filesystem and extension access after preload", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")
    XLSXFixture.write_xlsx!(xlsx_path, [["name"], ["visible"]])

    id = "spreadsheet-lock-test-#{System.unique_integer([:positive])}"
    session = start_supervised!({SpreadsheetSession, id: id, directory: tmp_dir})

    assert {:error, read_reason} =
             SpreadsheetSession.query(session, "SELECT * FROM read_csv('/etc/passwd') LIMIT 1")

    assert read_reason =~ "file system operations are disabled"

    assert {:error, load_reason} = SpreadsheetSession.query(session, "LOAD httpfs")
    assert load_reason =~ "Loading external extensions is disabled"

    assert {:error, config_reason} =
             SpreadsheetSession.query(session, "SET enable_external_access = true")

    assert config_reason =~ "configuration has been locked"
  end
end
