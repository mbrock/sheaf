defmodule Sheaf.SpreadsheetsTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Sheaf.Spreadsheets

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-spreadsheets-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> "-shm")
      File.rm(path <> "-wal")
    end)

    {:ok, db_path: path}
  end

  test "lists and queries imported spreadsheet tables", %{db_path: db_path} do
    {:ok, conn} = Spreadsheets.open(db_path: db_path)

    try do
      :ok =
        Sqlite3.execute(
          conn,
          """
          INSERT INTO spreadsheets
            (id, title, path, basename, file_size, file_mtime, sha256, imported_at)
          VALUES
            ('xl_test', 'Test workbook', '/tmp/test.xlsx', 'test.xlsx', 123, '2026-01-01T00:00:00', 'abc', '2026-01-01T00:00:00Z')
          """
        )

      :ok =
        Sqlite3.execute(
          conn,
          """
          CREATE TABLE ss_xl_test_1 (
            __row_number INTEGER NOT NULL,
            __text TEXT NOT NULL,
            buyer_type TEXT,
            bidder_count TEXT
          )
          """
        )

      :ok =
        Sqlite3.execute(
          conn,
          """
          INSERT INTO ss_xl_test_1 (__row_number, __text, buyer_type, bidder_count)
          VALUES
            (2, 'agency | 3', 'agency', '3'),
            (3, 'municipality | 1', 'municipality', '1')
          """
        )

      headers = Jason.encode!([%{name: "buyer_type", header: "buyer_type"}])

      :ok =
        Sqlite3.execute(
          conn,
          """
          INSERT INTO spreadsheet_sheets
            (spreadsheet_id, sheet_index, name, table_name, row_count, col_count, headers_json, imported_at)
          VALUES
            ('xl_test', 1, 'Sheet1', 'ss_xl_test_1', 2, 2, '#{headers}', '2026-01-01T00:00:00Z')
          """
        )
    after
      Spreadsheets.close(conn)
    end

    assert {:ok, [%{id: "xl_test", sheets: [%{table_name: "ss_xl_test_1"}]}]} =
             Spreadsheets.list(db_path: db_path)

    assert {:ok, %{rows: [%{"buyer_type" => "agency", "n" => 1}]}} =
             Spreadsheets.query(
               "select buyer_type, count(*) as n from ss_xl_test_1 where buyer_type = 'agency' group by buyer_type",
               db_path: db_path
             )

    assert {:ok, [%{row_number: 3, row: %{"buyer_type" => "municipality"}}]} =
             Spreadsheets.search("municipality", db_path: db_path)
  end

  test "query rejects writes", %{db_path: db_path} do
    assert {:error, :only_select_queries_allowed} =
             Spreadsheets.query("delete from spreadsheets", db_path: db_path)
  end
end
