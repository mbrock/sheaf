defmodule Sheaf.CorpusTest do
  use ExUnit.Case, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Corpus
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "find_document prefers the containing document graph over workspace metadata",
       %{
         tmp_dir: tmp_dir
       } do
    path = Path.join(tmp_dir, "repo.sqlite3")
    document = Sheaf.Id.iri("DOC001")
    section = Sheaf.Id.iri("SEC001")
    workspace_graph = RDF.iri(Sheaf.Repo.workspace_graph())
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    workspace =
      RDF.Graph.new(
        [
          {section, RDFS.label(), RDF.literal("Workspace-side section label")}
        ],
        name: workspace_graph
      )

    metadata =
      RDF.Graph.new(
        [
          {document, RDFS.label(),
           RDF.literal("Metadata-side document label")}
        ],
        name: metadata_graph
      )

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

    assert Corpus.find_document("DOC001") == "DOC001"
    assert Corpus.find_document("SEC001") == "DOC001"
  end
end
