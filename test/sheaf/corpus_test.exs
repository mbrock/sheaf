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
    assert sparql =~ "ORDER BY DESC(?score)"
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

    assert sparql =~ "FILTER(?doc = <https://sheaf.less.rest/DOC123>)"
  end
end
