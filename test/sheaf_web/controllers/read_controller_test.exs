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

    markdown_conn =
      conn
      |> recycle()
      |> put_req_header("accept", "text/markdown")
      |> get("/read/DOC777")

    assert get_resp_header(markdown_conn, "content-type") == [
             "text/markdown; charset=utf-8"
           ]

    assert markdown = response(markdown_conn, 200)
    assert markdown =~ "# Metadata Book"
    assert markdown =~ "Book · Ada Example · 2026"

    assert markdown =~
             "[1 Interesting Chapter](#{read_url("CHP777")})"

    assert markdown =~
             "[1.1 Section about Tigers](#{read_url("SEC777")})"
  end

  @tag :tmp_dir
  test "exports a complete document with Markdown structure and LaTeX math",
       %{
         conn: conn,
         tmp_dir: tmp_dir
       } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOCMD1")
    section = Id.iri("SECMD1")
    paragraph = Id.iri("PARMD1")
    revision = Id.iri("REVMD1")
    equation = Id.iri("EQNMD1")
    list = Id.iri("LSTMD1")
    table = Id.iri("TBLMD1")
    footnote = Id.iri("FTNMD1")
    extracted_reference = Id.iri("REFMD1")
    extracted_footnote = Id.iri("FTNMD2")
    diagram = Id.iri("DIAMD1")
    document_list = Id.iri("RDFMD1")
    section_list = Id.iri("RDFMD2")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDFS.label(), "Markdown Paper"},
          {document, DOC.children(), document_list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), "Method"},
          {section, DOC.children(), section_list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), revision},
          {paragraph, DOC.markup(),
           ~s(The complete paragraph.<sup data-footnote="1">1</sup>)},
          {revision, DOC.text(), "The complete paragraph."},
          {equation, RDF.type(), DOC.ExtractedBlock},
          {equation, DOC.sourceBlockType(), "Equation"},
          {equation, DOC.sourceHtml(),
           ~s(<p><math display="block">\\frac{x}{y} &amp;= 2</math></p>)},
          {list, RDF.type(), DOC.ExtractedBlock},
          {list, DOC.sourceBlockType(), "ListGroup"},
          {list, DOC.sourceHtml(),
           ~s(<ul><li>First <math>x</math></li><li>Second</li></ul>)},
          {table, RDF.type(), DOC.ExtractedBlock},
          {table, DOC.sourceBlockType(), "Table"},
          {table, DOC.sourceHtml(),
           ~s(<table><tr><th rowspan="2">Name</th><th colspan="2">Values</th></tr><tr><th>Left</th><th>Right</th></tr><tr><td>alpha</td><td><math>a</math></td><td><math>b</math></td></tr></table>)},
          {footnote, RDF.type(), DOC.ExtractedBlock},
          {footnote, DOC.sourceBlockType(), "Footnote"},
          {footnote, DOC.sourceHtml(), "<p><sup>1</sup>A useful note.</p>"},
          {extracted_reference, RDF.type(), DOC.ExtractedBlock},
          {extracted_reference, DOC.sourceBlockType(), "Text"},
          {extracted_reference, DOC.sourcePage(), 1},
          {extracted_reference, DOC.sourceHtml(),
           "<p>An extracted reference.<sup>2</sup></p>"},
          {extracted_footnote, RDF.type(), DOC.ExtractedBlock},
          {extracted_footnote, DOC.sourceBlockType(), "Footnote"},
          {extracted_footnote, DOC.sourcePage(), 1},
          {extracted_footnote, DOC.sourceHtml(),
           "<p><sup>2</sup>An extracted note.</p>"},
          {diagram, RDF.type(), DOC.ExtractedBlock},
          {diagram, DOC.sourceBlockType(), "Text"},
          {diagram, DOC.sourcePage(), 1},
          {diagram, DOC.sourceHtml(),
           "<pre>1 ←<sup>2</sup>→= func(...)</pre>"}
        ],
        name: document
      )
      |> then(&RDF.list([section], graph: &1, head: document_list).graph)
      |> then(
        &RDF.list(
          [
            paragraph,
            equation,
            list,
            table,
            footnote,
            extracted_reference,
            extracted_footnote,
            diagram
          ],
          graph: &1,
          head: section_list
        ).graph
      )

    assert :ok = Sheaf.Repo.assert(graph)

    conn = get(conn, "/DOCMD1.md")

    assert get_resp_header(conn, "content-type") == [
             "text/markdown; charset=utf-8"
           ]

    assert markdown = response(conn, 200)
    assert markdown =~ "# Markdown Paper"
    assert markdown =~ "## Method"
    assert markdown =~ "The complete paragraph.[^1]"
    assert markdown =~ "$$\n\\frac{x}{y} &= 2\n$$"
    assert markdown =~ "- First $x$\n- Second"
    assert markdown =~ "| Name | Values<br>Left | Values<br>Right |"
    assert markdown =~ "| alpha | $a$ | $b$ |"
    assert markdown =~ "[^1]: A useful note."
    assert markdown =~ "An extracted reference.[^2]"
    assert markdown =~ "[^2]: An extracted note."
    assert markdown =~ "1 ← 2 →= func(...)"
    refute markdown =~ "1 ←[^2]→= func(...)"
  end

  @tag :tmp_dir
  test "returns not found for a non-document Markdown export", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    conn = get(conn, "/NOTDOC.md")

    assert response(conn, 404) == "Not found\n"

    assert get_resp_header(conn, "content-type") == [
             "text/plain; charset=utf-8"
           ]
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

    markdown_conn =
      conn
      |> recycle()
      |> put_req_header("accept", "text/markdown")
      |> get("/read/SEC888")

    assert markdown = response(markdown_conn, 200)
    assert markdown =~ "# Book"
    assert markdown =~ "[Book](#{read_url("DOC888")})"
    assert markdown =~ "## Section about Tigers"
    assert markdown =~ "Main section paragraph."
    assert markdown =~ "### [Subsection](#{read_url("SUB888")})"
    refute markdown =~ "Nested paragraph should be linked"
  end

  defp read_url(id) do
    URI.merge(Id.base_iri(), "/read/#{id}") |> URI.to_string()
  end
end
