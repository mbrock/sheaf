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
    assert RDF.Data.include?(graph, {block, AS.tag(), RDF.iri(DOC.NeedsEvidenceTag)})
    assert RDF.Data.include?(graph, {block, AS.tag(), RDF.iri(DOC.FragmentTag)})
  end

  test "returns tags for reachable paragraph blocks in document order" do
    document = Id.iri("DOC111")
    root_list = Id.iri("LST111")
    section = Id.iri("SEC111")
    section_list = Id.iri("LST222")
    paragraph = Id.iri("PAR111")
    other_paragraph = Id.iri("PAR222")

    graph =
      Graph.new([
        {document, RDF.type(), DOC.Document},
        {document, DOC.children(), root_list},
        {section, RDF.type(), DOC.Section},
        {section, DOC.children(), section_list},
        {paragraph, RDF.type(), DOC.ParagraphBlock},
        {other_paragraph, RDF.type(), DOC.ParagraphBlock}
      ])
      |> then(fn graph -> RDF.list([section], graph: graph, head: root_list).graph end)
      |> then(fn graph -> RDF.list([paragraph], graph: graph, head: section_list).graph end)

    workspace =
      Graph.new(
        [
          {paragraph, AS.tag(), RDF.iri(DOC.NeedsEvidenceTag)},
          {paragraph, AS.tag(), RDF.iri(DOC.FragmentTag)},
          {other_paragraph, AS.tag(), RDF.iri(DOC.NeedsRevisionTag)}
        ],
        name: Sheaf.Workspace.graph()
      )

    assert {:ok,
            %{
              "PAR111" => [
                %{name: "needs_evidence", label: "needs evidence"},
                %{name: "fragment", label: "fragment"}
              ]
            }} = BlockTags.for_document(graph, document, workspace_graph: workspace)
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
