defmodule SheafWeb.ReadControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{DCTERMS, DOC, FABIO, FOAF}

  @tag :tmp_dir
  test "renders a static document table of contents", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC777")
    expression = Id.iri("EXPR77")
    author = Id.iri("AUTH77")
    chapter = Id.iri("CHP777")
    section = Id.iri("SEC777")
    document_list = Id.iri("LST777")
    chapter_list = Id.iri("LST778")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDFS.label(), "Local title"},
          {document, DOC.children(), document_list},
          {chapter, RDF.type(), DOC.Section},
          {chapter, RDFS.label(), "Interesting Chapter"},
          {chapter, DOC.children(), chapter_list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), "Section about Tigers"}
        ],
        name: document
      )
      |> then(&RDF.list([chapter], graph: &1, head: document_list).graph)
      |> then(&RDF.list([section], graph: &1, head: chapter_list).graph)

    assert :ok = Sheaf.Repo.assert(graph)

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {document, FABIO.isRepresentationOf(), expression},
                   {expression, RDF.type(), FABIO.Book},
                   {expression, DCTERMS.title(), "Metadata Book"},
                   {expression, DCTERMS.creator(), author},
                   {author, RDF.type(), FOAF.Person},
                   {author, FOAF.name(), "Ada Example"},
                   {expression, FABIO.hasPublicationYear(), "2026"}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    conn = get(conn, "/read/DOC777")

    assert html = response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "text/html; charset=utf-8"
           ]

    assert html =~ "<h1>Metadata Book</h1>"
    assert html =~ "Ada Example"
    assert html =~ ~s(<a href="/read/CHP777">1 Interesting Chapter</a>)
    assert html =~ ~s(<a href="/read/SEC777">1.1 Section about Tigers</a>)
  end

  @tag :tmp_dir
  test "renders a section with block text and subsection links only", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC888")
    section = Id.iri("SEC888")
    paragraph = Id.iri("PAR888")
    paragraph_revision = Id.iri("REV888")
    subsection = Id.iri("SUB888")
    subsection_paragraph = Id.iri("PAR889")
    subsection_revision = Id.iri("REV889")
    document_list = Id.iri("LST888")
    section_list = Id.iri("LST889")
    subsection_list = Id.iri("LST890")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDFS.label(), "Book"},
          {document, DOC.children(), document_list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), "Section about Tigers"},
          {section, DOC.children(), section_list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), paragraph_revision},
          {paragraph_revision, DOC.text(), "Main section paragraph."},
          {subsection, RDF.type(), DOC.Section},
          {subsection, RDFS.label(), "Subsection"},
          {subsection, DOC.children(), subsection_list},
          {subsection_paragraph, RDF.type(), DOC.ParagraphBlock},
          {subsection_paragraph, DOC.paragraph(), subsection_revision},
          {subsection_revision, DOC.text(),
           "Nested paragraph should be linked, not rendered."}
        ],
        name: document
      )
      |> then(&RDF.list([section], graph: &1, head: document_list).graph)
      |> then(
        &RDF.list([paragraph, subsection], graph: &1, head: section_list).graph
      )
      |> then(
        &RDF.list([subsection_paragraph], graph: &1, head: subsection_list).graph
      )

    assert :ok = Sheaf.Repo.assert(graph)

    conn = get(conn, "/read/SEC888")

    assert html = response(conn, 200)
    assert html =~ ~s(<p class="source-label">Source</p>)
    refute html =~ ~s(<a href="/corpus">Corpus</a>)
    assert html =~ "<h2 id=\"section-heading\">Section about Tigers</h2>"
    assert html =~ ~s(<a href="/read/DOC888">Book</a>)
    refute html =~ ~s(<a href="/read/SEC888">Section about Tigers</a>)
    assert html =~ "Main section paragraph."
    assert html =~ ~s(<a href="/read/SUB888">Subsection</a>)
    refute html =~ "Nested paragraph should be linked"
  end
end
