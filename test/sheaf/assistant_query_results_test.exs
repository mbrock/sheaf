defmodule Sheaf.Assistant.QueryResultsTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias Sheaf.Assistant.QueryResults

  @tag :tmp_dir
  test "stores query results as RDF-backed Parquet artifacts and reads pages", %{tmp_dir: tmp_dir} do
    result_iri = RDF.IRI.new!("https://example.com/sheaf/RES111")
    file_iri = RDF.IRI.new!("https://example.com/sheaf/FILE11")
    tool_call_iri = RDF.IRI.new!("https://example.com/sheaf/CALL11")
    session_iri = RDF.IRI.new!("https://example.com/sheaf/CHAT11")
    agent_iri = RDF.IRI.new!("https://example.com/sheaf/AGENT1")
    generated_at = ~U[2026-05-03 12:00:00Z]
    test_pid = self()

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
               tool_call_iri: tool_call_iri,
               session_iri: session_iri,
               agent_iri: agent_iri,
               generated_at: generated_at,
               put_graph: fn graph_name, graph ->
                 send(test_pid, {:put_graph, graph_name, graph})
                 :ok
               end
             )

    assert_receive {:put_graph, ^file_iri, file_graph}
    assert_receive {:put_graph, ^result_iri, result_graph}

    result = Graph.description(result_graph, result_iri)
    tool_call = Graph.description(result_graph, tool_call_iri)

    assert RDF.Description.include?(result, {RDF.type(), Sheaf.NS.DOC.QueryResult})
    assert RDF.Description.include?(result, {Sheaf.NS.DOC.resultFile(), file_iri})
    assert rdf_value(result, Sheaf.NS.DOC.sourceQuery()) == "SELECT name, amount FROM example"
    assert rdf_value(result, Sheaf.NS.DOC.rowCount()) == 3
    assert rdf_value(result, Sheaf.NS.DOC.columnNameList()) == ~s(["name","amount"])
    assert RDF.Description.include?(tool_call, {RDF.type(), Sheaf.NS.DOC.ToolCall})
    assert RDF.Description.include?(tool_call, {Sheaf.NS.PROV.generated(), result_iri})

    fetch_graph = fn
      ^result_iri -> {:ok, result_graph}
      ^file_iri -> {:ok, file_graph}
    end

    assert {:ok,
            %{
              id: "RES111",
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
               fetch_graph: fetch_graph,
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
