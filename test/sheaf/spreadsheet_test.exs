defmodule Sheaf.SpreadsheetTest do
  use ExUnit.Case, async: true

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.NS.DOC

  test "builds a spreadsheet document grouped by source sections" do
    document = RDF.IRI.new!("https://example.com/sheaf/SPREADSHEET")
    minted = minted_iris()

    rows = [
      %{
        line: 2,
        source: "Agnese Z.",
        category: "RQ1-1",
        category_title: "Consumption work",
        marked_text: "First marked text."
      },
      %{
        line: 3,
        source: "Agnese Z.",
        category: "RQ1-2",
        category_title: "Other work",
        marked_text: "Second marked text."
      },
      %{
        line: 4,
        source: "Līga",
        category: "RQ1-1",
        category_title: "Consumption work",
        marked_text: "Third marked text."
      }
    ]

    result =
      Sheaf.Spreadsheet.build_graph(rows,
        document: document,
        source_path: "priv/ieva_data/coded.csv",
        mint: fn ->
          Agent.get_and_update(minted, fn [iri | rest] -> {iri, rest} end)
        end
      )

    assert result.document == document
    assert result.rows == 3
    assert result.sources == 2

    graph = result.graph
    agnese_section = RDF.IRI.new!("https://example.com/sheaf/M1")
    liga_section = RDF.IRI.new!("https://example.com/sheaf/M5")
    first_row = RDF.IRI.new!("https://example.com/sheaf/M2")
    second_row = RDF.IRI.new!("https://example.com/sheaf/M3")

    assert rdf_value(Graph.description(graph, document), RDFS.label()) ==
             "IEVA coded excerpts"

    assert Description.include?(
             Graph.description(graph, document),
             {RDF.type(), DOC.Spreadsheet}
           )

    assert [^agnese_section, ^liga_section] =
             Sheaf.Document.children(graph, document)

    assert rdf_value(Graph.description(graph, agnese_section), RDFS.label()) ==
             "Agnese Z."

    assert [^first_row, ^second_row] =
             Sheaf.Document.children(graph, agnese_section)

    first_row_description = Graph.description(graph, first_row)

    assert Description.include?(first_row_description, {RDF.type(), DOC.Row})

    assert rdf_value(first_row_description, DOC.text()) ==
             "First marked text."

    assert rdf_value(first_row_description, DOC.spreadsheetRow()) == 2

    assert rdf_value(first_row_description, DOC.spreadsheetSource()) ==
             "Agnese Z."

    assert rdf_value(first_row_description, DOC.codeCategory()) == "RQ1-1"

    assert rdf_value(first_row_description, DOC.sourceKey()) ==
             "priv/ieva_data/coded.csv#row=2"
  end

  defp minted_iris do
    {:ok, agent} =
      Agent.start_link(fn ->
        Enum.map(1..10, &RDF.IRI.new!("https://example.com/sheaf/M#{&1}"))
      end)

    agent
  end

  defp rdf_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> RDF.Term.value()
  end
end
