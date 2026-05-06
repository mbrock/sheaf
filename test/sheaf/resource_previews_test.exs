defmodule Sheaf.ResourcePreviewsTest do
  use ExUnit.Case, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.NS.{BIBO, DCTERMS, DOC, FABIO, FOAF}
  alias Sheaf.ResourcePreviews

  @tag :tmp_dir
  test "builds document previews from the document graph and metadata", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "repo.sqlite3")
    document = Sheaf.Id.iri("DOC111")
    root_list = Sheaf.Id.iri("LST111")
    section = Sheaf.Id.iri("SEC111")
    paragraph = Sheaf.Id.iri("PAR111")
    paragraph_revision = Sheaf.Id.iri("PRV111")
    expression = Sheaf.Id.iri("EXP111")
    author = Sheaf.Id.iri("AUT111")
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    document_graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDFS.label(), RDF.literal("Example document")},
          {document, BIBO.numPages(), RDF.literal(12)},
          {document, DOC.children(), root_list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Introduction")},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), paragraph_revision},
          {paragraph_revision, RDF.type(), DOC.Paragraph},
          {paragraph_revision, DOC.text(),
           RDF.literal("Opening paragraph for the preview.")}
        ],
        name: document
      )
      |> then(fn graph ->
        RDF.list([section, paragraph], graph: graph, head: root_list).graph
      end)

    metadata =
      RDF.Graph.new(
        [
          {document, FABIO.isRepresentationOf(), expression},
          {expression, DCTERMS.creator(), author},
          {author, FOAF.name(), RDF.literal("Ieva Lange")},
          {expression, FABIO.hasPublicationYear(), RDF.literal("2026")}
        ],
        name: metadata_graph
      )

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-document", document_graph)
    assert :ok = Quadlog.assert(log, "tx-metadata", metadata)
    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert %{
             type: :document,
             document_id: "DOC111",
             document_title: "Example document",
             document_authors: ["Ieva Lange"],
             document_year: "2026",
             path: "/DOC111",
             text: nil,
             toc: [%{id: "SEC111", number: "1", title: "Introduction"}],
             document: %{metadata: %{page_count: 12}}
           } = ResourcePreviews.get("DOC111")
  end
end
