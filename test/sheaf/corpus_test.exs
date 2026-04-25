defmodule Sheaf.CorpusTest do
  use ExUnit.Case, async: true

  alias Sheaf.Corpus

  test "search_text expands multi-word queries into keyword matches" do
    test_pid = self()

    select = fn sparql ->
      send(test_pid, {:sparql, sparql})
      {:ok, %{results: []}}
    end

    assert {:ok, []} = Corpus.search_text("politics economy", select: select)

    assert_receive {:sparql, sparql}

    assert sparql =~ ~s/CONTAINS(?haystack, LCASE("politics economy"))/
    assert sparql =~ ~s/CONTAINS(?haystack, "politics")/
    assert sparql =~ ~s/CONTAINS(?haystack, "economy")/

    assert sparql =~
             "FILTER(?docKind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))"

    assert sparql =~ "FILTER NOT EXISTS"
    assert sparql =~ "ORDER BY DESC(?score)"
    refute sparql =~ "sheaf:Row"
  end

  test "search_text includes spreadsheet rows only when explicitly requested" do
    test_pid = self()

    select = fn sparql ->
      send(test_pid, {:sparql, sparql})

      {:ok,
       %{
         results: [
           %{
             "doc" => RDF.iri("https://sheaf.less.rest/CODED1"),
             "docTitle" => RDF.literal("Coded excerpts"),
             "block" => RDF.iri("https://sheaf.less.rest/ROW123"),
             "kind" => RDF.literal("row"),
             "text" => RDF.literal("S2: Coded marked text."),
             "spreadsheetRow" => RDF.literal(72),
             "spreadsheetSource" => RDF.literal("Agnese Z."),
             "codeCategory" => RDF.literal("RQ1-1"),
             "codeCategoryTitle" => RDF.literal("Consumption work")
           }
         ]
       }}
    end

    assert {:ok,
            [
              %{
                document_id: "CODED1",
                document_title: "Coded excerpts",
                block_id: "ROW123",
                kind: :row,
                text: "S2: Coded marked text.",
                coding: %{
                  row: 72,
                  source: "Agnese Z.",
                  category: "RQ1-1",
                  category_title: "Consumption work"
                }
              }
            ]} = Corpus.search_text("coded", include_spreadsheets: true, select: select)

    assert_receive {:sparql, sparql}
    assert sparql =~ "sheaf:Row"
    assert sparql =~ "sheaf:codeCategoryTitle"
  end

  test "search_text still supports scoped searches" do
    test_pid = self()

    select = fn sparql ->
      send(test_pid, {:sparql, sparql})
      {:ok, %{results: []}}
    end

    assert {:ok, []} =
             Corpus.search_text("practice theory", document_id: "DOC123", select: select)

    assert_receive {:sparql, sparql}

    assert sparql =~ "FILTER(?doc = <#{Sheaf.Id.iri("DOC123")}>)"
  end
end
