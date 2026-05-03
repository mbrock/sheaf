defmodule Sheaf.Spreadsheet.MetadataTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias Sheaf.NS.{CSVW, DCAT, DCTERMS, DOC, PROV}
  alias Sheaf.Spreadsheet.Metadata
  alias Sheaf.XLSXFixture

  @tag :tmp_dir
  test "imports XLSX workbook metadata into the workspace graph", %{tmp_dir: tmp_dir} do
    xlsx_path = Path.join(tmp_dir, "inventory.xlsx")

    XLSXFixture.write_workbook!(xlsx_path, [
      {"Items", [["buyer_type", "amount"], ["agency", "3"], ["municipality", "7"]]},
      {"Notes", [["label"], ["visible"]]}
    ])

    graph_ref = :atomics.new(1, [])
    table = :ets.new(:spreadsheet_metadata_graphs, [:set, :public])

    assert {:ok,
            %{
              title: "inventory.xlsx",
              sheets: [
                %{name: "Items", row_count: 2, col_count: 2},
                %{name: "Notes", row_count: 1, col_count: 1}
              ]
            }} =
             Metadata.import_file(xlsx_path,
               directory: tmp_dir,
               blob_root: Path.join(tmp_dir, "blobs"),
               persist: fn graph ->
                 :atomics.add(graph_ref, 1, 1)
                 :ets.insert(table, {:workspace, graph})
                 :ok
               end
             )

    assert :atomics.get(graph_ref, 1) == 1
    [{:workspace, graph}] = :ets.lookup(table, :workspace)
    assert graph.name == RDF.iri(Sheaf.Workspace.graph())

    workbook =
      graph
      |> RDF.Data.descriptions()
      |> Enum.find(&RDF.Description.include?(&1, {RDF.type(), DOC.SpreadsheetWorkbook}))

    assert workbook
    assert RDF.Description.include?(workbook, {RDF.type(), DCAT.Dataset})
    assert RDF.Description.include?(workbook, {RDF.type(), CSVW.TableGroup})
    assert RDF.Description.include?(workbook, {RDF.type(), PROV.Entity})
    assert rdf_value(workbook, DCTERMS.title()) == "inventory.xlsx"
    assert rdf_value(workbook, DOC.workspacePath()) == "inventory.xlsx"

    [sheet_iri | _] = RDF.Description.get(workbook, CSVW.table())
    sheet = Graph.description(graph, sheet_iri)

    assert RDF.Description.include?(sheet, {RDF.type(), DOC.SpreadsheetSheet})
    assert RDF.Description.include?(sheet, {RDF.type(), CSVW.Table})
    assert rdf_value(sheet, CSVW.name()) == "Items"
    assert rdf_value(sheet, DOC.rowCount()) == 2

    file_iri = RDF.Description.first(workbook, DCAT.distribution())
    file = Graph.description(graph, file_iri)

    assert RDF.Description.include?(file, {RDF.type(), DCAT.Distribution})

    assert rdf_value(file, DCAT.mediaType()) ==
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  end

  defp rdf_value(description, property) do
    description
    |> RDF.Description.first(property)
    |> RDF.Term.value()
  end
end
