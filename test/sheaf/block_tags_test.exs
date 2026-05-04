defmodule Sheaf.BlockTagsTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias Sheaf.BlockTags
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC}

  test "attaches writing tags to paragraph blocks in the workspace graph" do
    test_pid = self()
    document = Id.iri("DOC111")
    block = Id.iri("PAR111")

    document_graph =
      Graph.new([
        {document, RDF.type(), DOC.Document},
        {block, RDF.type(), DOC.ParagraphBlock}
      ])

    persist = fn graph ->
      send(test_pid, {:persist, graph})
      :ok
    end

    assert {:ok, result} =
             BlockTags.attach(["PAR111"], ["needs evidence", "fragment"],
               document_resolver: fn "PAR111" -> "DOC111" end,
               graph_fetcher: fn "DOC111" -> {:ok, document_graph} end,
               persist: persist
             )

    assert result.block_ids == ["PAR111"]
    assert result.tags == ["needs_evidence", "fragment"]
    assert result.statement_count == 2

    assert_receive {:persist, graph}
    assert graph.name == RDF.iri(Sheaf.Workspace.graph())
    assert RDF.Data.include?(graph, {block, AS.tag(), DOC.NeedsEvidenceTag})
    assert RDF.Data.include?(graph, {block, AS.tag(), DOC.FragmentTag})
  end

  test "rejects non-paragraph blocks" do
    document = Id.iri("DOC111")
    section = Id.iri("SEC111")

    document_graph =
      Graph.new([
        {document, RDF.type(), DOC.Document},
        {section, RDF.type(), DOC.Section}
      ])

    assert {:error, "block SEC111 is a section, not a paragraph"} =
             BlockTags.attach(["SEC111"], ["needs_revision"],
               document_resolver: fn "SEC111" -> "DOC111" end,
               graph_fetcher: fn "DOC111" -> {:ok, document_graph} end,
               persist: fn _graph -> :ok end
             )
  end

  test "rejects unknown writing tags" do
    assert {:error, "unknown writing tag(s): urgent"} =
             BlockTags.attach(["PAR111"], ["urgent"], persist: fn _graph -> :ok end)
  end
end
