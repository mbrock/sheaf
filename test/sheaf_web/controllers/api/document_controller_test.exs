defmodule SheafWeb.API.DocumentControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{DCTERMS, DOC, FABIO}

  @tag :tmp_dir
  test "serves LaTeX export for a document", %{conn: conn, tmp_dir: tmp_dir} do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("LATEX1")
    expression = Id.iri("LATEXW")
    list = Id.iri("LATEXL")
    paragraph = Id.iri("LATEXP")
    revision = Id.iri("LATEXR")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDF.type(), DOC.Thesis},
          {document, RDFS.label(), RDF.literal("Export Test")},
          {document, DOC.children(), list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), revision},
          {revision, RDF.type(), DOC.Paragraph},
          {revision, DOC.text(), RDF.literal("Simple paragraph.")}
        ],
        name: document
      )
      |> then(fn graph -> RDF.list([paragraph], graph: graph, head: list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {document, FABIO.isRepresentationOf(), expression},
                   {expression, DCTERMS.title(), RDF.literal("Metadata Export Title")}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    conn =
      conn
      |> auth()
      |> get(~p"/api/documents/LATEX1/latex")

    assert response(conn, 200) =~ "\\title{Metadata Export Title}"
    assert response(conn, 200) =~ "Simple paragraph."
    assert ["application/x-tex; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert [~s(inline; filename="LATEX1.tex")] = get_resp_header(conn, "content-disposition")
  end

  test "requires basic auth for document exports", %{conn: conn} do
    conn = get(conn, ~p"/api/documents/LATEX1/latex")

    assert response(conn, 401) == "Unauthorized"
    assert ["Basic realm=\"Application\""] = get_resp_header(conn, "www-authenticate")
  end

  defp auth(conn) do
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:sheaf"))
  end
end
