defmodule Sheaf.DocumentMetadataTitleTest do
  use ExUnit.Case, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Document
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "reads document root title from the metadata graph", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "repo.sqlite3")
    document = Sheaf.Id.iri("DOC001")
    list = Sheaf.Id.iri("LST001")

    document_graph =
      RDF.Graph.new(
        [
          {document, DOC.children(), list}
        ],
        name: document
      )

    metadata_graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDF.type(), DOC.Thesis},
          {document, RDFS.label(), "Metadata title"}
        ],
        name: Sheaf.Repo.metadata_graph()
      )

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-document", document_graph)
    assert :ok = Quadlog.assert(log, "tx-metadata", metadata_graph)
    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert Document.title(document_graph, document) == "Metadata title"
    assert Document.kind(document_graph, document) == :thesis
  end
end
