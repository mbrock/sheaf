defmodule Sheaf.ResourceResolverTest do
  use ExUnit.Case, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.NS.{AS, DOC}
  alias Sheaf.ResourceResolver

  @tag :tmp_dir
  test "resolves documents, assistant conversations, and blocks", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "repo.sqlite3")
    document = Sheaf.Id.iri("DOC001")
    section = Sheaf.Id.iri("SEC001")
    conversation = Sheaf.Id.iri("CHAT01")
    note = Sheaf.Id.iri("NOTE01")
    query_result = Sheaf.Id.iri("RES111")
    workspace_graph = RDF.iri(Sheaf.Repo.workspace_graph())
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    workspace =
      RDF.Graph.new(
        [
          {conversation, RDF.type(), DOC.AssistantConversation},
          {conversation, RDF.type(), AS.OrderedCollection},
          {conversation, RDFS.label(), RDF.literal("Assistant conversation CHAT01")},
          {note, RDF.type(), DOC.ResearchNote},
          {note, RDF.type(), AS.Note},
          {note, AS.content(), RDF.literal("A durable note.")},
          {query_result, RDF.type(), DOC.SpreadsheetQueryResult},
          {query_result, RDFS.label(), RDF.literal("Spreadsheet query result")}
        ],
        name: workspace_graph
      )

    metadata = RDF.Graph.new([], name: metadata_graph)

    document_graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDFS.label(), RDF.literal("Example document")},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Example section")}
        ],
        name: document
      )

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-workspace", workspace)
    assert :ok = Quadlog.assert(log, "tx-metadata", metadata)
    assert :ok = Quadlog.assert(log, "tx-document", document_graph)
    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert {:ok, %{kind: :document, id: "DOC001"}} = ResourceResolver.resolve("DOC001")

    assert {:ok, %{kind: :assistant_conversation, id: "CHAT01"}} =
             ResourceResolver.resolve("CHAT01")

    assert {:ok, %{kind: :block, id: "SEC001", document_id: "DOC001"}} =
             ResourceResolver.resolve("SEC001")

    assert {:ok, %{kind: :spreadsheet_query_result, id: "RES111"}} =
             ResourceResolver.resolve("RES111")

    assert {:ok, %{kind: :research_note, id: "NOTE01"}} =
             ResourceResolver.resolve("NOTE01")

    assert {:error, :not_found} = ResourceResolver.resolve("MISSING")
  end
end
