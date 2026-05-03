defmodule Sheaf.Assistant.QueryResultsTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias Sheaf.Assistant.QueryResults

  @tag :tmp_dir
  test "stores query results as RDF-backed Parquet artifacts and reads pages", %{tmp_dir: tmp_dir} do
    result_iri = RDF.IRI.new!("https://example.com/sheaf/RES111")
    file_iri = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    query_iri = RDF.IRI.new!("https://example.com/sheaf/QUERY1")
    execution_iri = RDF.IRI.new!("https://example.com/sheaf/CALL11")
    session_iri = RDF.IRI.new!("https://example.com/sheaf/CHAT11")
    agent_iri = RDF.IRI.new!("https://example.com/sheaf/AGENT1")
    generated_at = ~U[2026-05-03 12:00:00Z]
    graph_ref = :atomics.new(1, [])
    table = :ets.new(:query_result_graphs, [:set, :public])

    assert {:ok,
            %{
              id: "RES111",
              iri: "https://example.com/sheaf/RES111",
              file_iri: "https://example.com/sheaf/FILE11",
              row_count: 3,
              columns: ["name", "amount"]
            }} =
             QueryResults.create(
               %{
                 sql: "SELECT name, amount FROM example",
                 columns: ["name", "amount"],
                 rows: [
                   %{"name" => "alpha", "amount" => "1"},
                   %{"name" => "beta", "amount" => "2"},
                   %{"name" => "gamma", "amount" => "3"}
                 ]
               },
               blob_root: Path.join(tmp_dir, "blobs"),
               result_iri: result_iri,
               file_iri: file_iri,
               query_iri: query_iri,
               execution_iri: execution_iri,
               session_iri: session_iri,
               agent_iri: agent_iri,
               generated_at: generated_at,
               persist: fn graph ->
                 :atomics.add(graph_ref, 1, 1)
                 :ets.insert(table, {:workspace, graph})
                 :ok
               end
             )

    assert :atomics.get(graph_ref, 1) == 1
    [{:workspace, result_graph}] = :ets.lookup(table, :workspace)
    assert result_graph.name == RDF.iri(Sheaf.Workspace.graph())

    result = Graph.description(result_graph, result_iri)
    query = Graph.description(result_graph, query_iri)
    execution = Graph.description(result_graph, execution_iri)
    file = Graph.description(result_graph, file_iri)

    assert RDF.Description.include?(result, {RDF.type(), Sheaf.NS.DOC.SpreadsheetQueryResult})
    assert RDF.Description.include?(result, {Sheaf.NS.DCAT.distribution(), file_iri})
    assert rdf_value(result, Sheaf.NS.DOC.rowCount()) == 3
    assert rdf_value(result, Sheaf.NS.DOC.columnNameList()) == ~s(["name","amount"])
    assert RDF.Description.include?(query, {RDF.type(), Sheaf.NS.DOC.SpreadsheetQuery})
    assert rdf_value(query, Sheaf.NS.DOC.sourceQuery()) == "SELECT name, amount FROM example"

    assert RDF.Description.include?(
             execution,
             {RDF.type(), Sheaf.NS.DOC.SpreadsheetQueryExecution}
           )

    assert RDF.Description.include?(execution, {Sheaf.NS.PROV.used(), query_iri})
    assert RDF.Description.include?(execution, {Sheaf.NS.PROV.generated(), result_iri})
    assert RDF.Description.include?(file, {RDF.type(), Sheaf.NS.DCAT.Distribution})

    assert {:ok,
            %{
              id: "RES111",
              sql: "SELECT name, amount FROM example",
              row_count: 3,
              offset: 1,
              limit: 2,
              columns: ["name", "amount"],
              rows: [
                %{"name" => "beta", "amount" => "2"},
                %{"name" => "gamma", "amount" => "3"}
              ]
            }} =
             QueryResults.read("https://example.com/sheaf/RES111",
               blob_root: Path.join(tmp_dir, "blobs"),
               workspace_graph: result_graph,
               offset: 1,
               limit: 2
             )
  end

  defp rdf_value(description, property) do
    description
    |> RDF.Description.first(property)
    |> RDF.Term.value()
  end
end
