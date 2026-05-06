defmodule SheafWeb.RDFQuadControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "streams named graph quads as n-quads", %{conn: conn, tmp_dir: tmp_dir} do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    graph = Id.iri("DOC123")
    subject = Id.iri("BLOCK123")
    list = RDF.bnode("children")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {subject, RDF.type(), DOC.ParagraphBlock},
                   {subject, DOC.text(), RDF.literal("hello\nworld")},
                   {list, RDF.first(), subject}
                 ],
                 name: graph
               )
             )

    conn =
      conn
      |> put_req_header("accept", "application/n-quads")
      |> get(~p"/rdf/quads", %{"g" => RDF.Term.value(graph)})

    assert response(conn, 200) =~
             "<https://sheaf.less.rest/BLOCK123> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <https://less.rest/sheaf/ParagraphBlock> <https://sheaf.less.rest/DOC123> .\n"

    assert response(conn, 200) =~
             "_:children <http://www.w3.org/1999/02/22-rdf-syntax-ns#first> <https://sheaf.less.rest/BLOCK123> <https://sheaf.less.rest/DOC123> .\n"

    assert ["application/n-quads; charset=utf-8"] =
             get_resp_header(conn, "content-type")
  end

  @tag :tmp_dir
  test "filters by subject predicate object and graph", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    graph = Id.iri("DOC123")
    subject = Id.iri("BLOCK123")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {subject, DOC.text(), RDF.literal("match me")},
                   {subject, DOC.sourceKey(), RDF.literal("skip me")}
                 ],
                 name: graph
               )
             )

    conn =
      get(conn, ~p"/rdf/quads", %{
        "s" => RDF.Term.value(subject),
        "p" => RDF.Term.value(DOC.text()),
        "o" => "\"match me\"",
        "g" => RDF.Term.value(graph)
      })

    body = response(conn, 200)

    assert body =~ "\"match me\""
    refute body =~ "skip me"
  end

  @tag :tmp_dir
  test "does not stream default graph rows", %{conn: conn, tmp_dir: tmp_dir} do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    subject = Id.iri("DEFAULT123")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new([
                 {subject, RDF.type(), DOC.Document}
               ])
             )

    conn = get(conn, ~p"/rdf/quads")

    assert response(conn, 200) == ""
  end
end
