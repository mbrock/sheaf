defmodule Sheaf.Assistant.SpreadsheetSessionTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.SpreadsheetSession
  alias Sheaf.Spreadsheet.Metadata
  alias Sheaf.XLSXFixture

  @tag :tmp_dir
  test "loads xlsx files into an in-memory DuckDB session", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")

    XLSXFixture.write_xlsx!(xlsx_path, [
      ["buyer_type", "amount"],
      ["agency", "3"],
      ["municipality", "7"]
    ])

    {session, _graph, _result} =
      start_materialized_session(tmp_dir, xlsx_path, "spreadsheet-test")

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
  test "loads content after blank spacer rows without retaining empty rows", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "spacer.xlsx")

    XLSXFixture.write_xlsx!(xlsx_path, [
      ["label", "amount"],
      ["before spacer", "1"],
      [],
      ["after spacer", "2"]
    ])

    {session, _graph, _result} =
      start_materialized_session(tmp_dir, xlsx_path, "spreadsheet-spacer-test")

    assert {:ok, [%{sheets: [%{table_name: table, row_count: 2, col_count: 2}]}]} =
             SpreadsheetSession.list(session)

    assert {:ok,
            %{
              rows: [
                %{"__row_number" => 1, "label" => "before spacer"},
                %{"__row_number" => 3, "label" => "after spacer"}
              ]
            }} =
             SpreadsheetSession.query(
               session,
               ~s(SELECT __row_number, label FROM "#{table}" ORDER BY __row_number)
             )

    assert {:ok, [%{row_number: 3, row: %{"label" => "after spacer"}}]} =
             SpreadsheetSession.search(session, "after spacer")
  end

  @tag :tmp_dir
  test "persists query results for later paging", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")

    XLSXFixture.write_xlsx!(xlsx_path, [
      ["buyer_type", "amount"],
      ["agency", "3"],
      ["municipality", "7"],
      ["state", "11"]
    ])

    result_iri = RDF.IRI.new!("https://example.com/sheaf/RES111")
    file_iri = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    tool_call_iri = RDF.IRI.new!("https://example.com/sheaf/CALL11")
    test_pid = self()

    {session, _graph, _result} =
      start_materialized_session(tmp_dir, xlsx_path, "spreadsheet-query-result-test")

    assert {:ok, [%{sheets: [%{table_name: table}]}]} = SpreadsheetSession.list(session)

    assert {:ok,
            %{
              result_id: "RES111",
              result_iri: "https://example.com/sheaf/RES111",
              result_file_iri: "https://example.com/sheaf/FILE11",
              row_count: 3,
              rows: [%{"buyer_type" => "agency", "amount" => "3"}]
            }} =
             SpreadsheetSession.query(
               session,
               ~s(SELECT buyer_type, amount FROM "#{table}" ORDER BY buyer_type),
               limit: 1,
               query_result_opts: [
                 blob_root: Path.join(tmp_dir, "blobs"),
                 result_iri: result_iri,
                 file_iri: file_iri,
                 execution_iri: tool_call_iri,
                 persist: fn graph ->
                   send(test_pid, {:workspace_graph, graph})
                   :ok
                 end
               ]
             )

    assert_receive {:workspace_graph, workspace_graph}

    assert {:ok,
            %{
              offset: 1,
              rows: [
                %{"buyer_type" => "municipality", "amount" => "7"},
                %{"buyer_type" => "state", "amount" => "11"}
              ]
            }} =
             Sheaf.Assistant.QueryResults.read("https://example.com/sheaf/RES111",
               blob_root: Path.join(tmp_dir, "blobs"),
               workspace_graph: workspace_graph,
               offset: 1,
               limit: 2
             )
  end

  @tag :tmp_dir
  test "skips unreadable empty sheets without dropping the workbook", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "multi.xlsx")

    XLSXFixture.write_workbook!(xlsx_path, [
      {"Data", [["name"], ["visible"]]},
      {"Empty", []}
    ])

    {session, _graph, import_result} =
      start_materialized_session(tmp_dir, xlsx_path, "spreadsheet-empty-sheet-test")

    assert [%{sheet: "Empty", error: error}] = import_result.sheet_errors
    assert error =~ "No rows found"

    assert {:ok, [%{sheets: [%{name: "Data", row_count: 1}], sheet_errors: []}]} =
             SpreadsheetSession.list(session)
  end

  @tag :tmp_dir
  test "locks filesystem and extension access after preload", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")
    XLSXFixture.write_xlsx!(xlsx_path, [["name"], ["visible"]])

    {session, _graph, _result} =
      start_materialized_session(tmp_dir, xlsx_path, "spreadsheet-lock-test")

    assert {:error, read_reason} =
             SpreadsheetSession.query(session, "SELECT * FROM read_csv('/etc/passwd') LIMIT 1")

    assert read_reason =~ "file system operations are disabled"

    assert {:error, load_reason} = SpreadsheetSession.query(session, "LOAD httpfs")
    assert load_reason =~ "Loading external extensions is disabled"

    assert {:error, config_reason} =
             SpreadsheetSession.query(session, "SET enable_external_access = true")

    assert config_reason =~ "configuration has been locked"
  end

  defp start_materialized_session(tmp_dir, xlsx_path, id_prefix) do
    blob_root = Path.join(tmp_dir, "blobs")
    test_pid = self()

    assert {:ok, result} =
             Metadata.import_file(xlsx_path,
               directory: tmp_dir,
               blob_root: blob_root,
               persist: fn graph ->
                 send(test_pid, {:spreadsheet_workspace_graph, graph})
                 :ok
               end
             )

    assert_receive {:spreadsheet_workspace_graph, graph}

    id = "#{id_prefix}-#{System.unique_integer([:positive])}"

    session =
      start_supervised!(
        {SpreadsheetSession,
         id: id, directory: tmp_dir, workspace_graph: graph, blob_root: blob_root}
      )

    {session, graph, result}
  end
end
