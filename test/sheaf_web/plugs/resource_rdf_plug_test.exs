defmodule SheafWeb.ResourceRDFPlugTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "serves subject quads from /:id when n-quads are accepted", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC123")
    block = Id.iri("BLOCK1")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {document, RDF.type(), DOC.Document},
                   {document, RDFS.label(), RDF.literal("Example")},
                   {block, RDFS.label(), RDF.literal("Other")}
                 ],
                 name: document
               )
             )

    conn =
      conn
      |> put_req_header("accept", "application/n-quads")
      |> get(~p"/DOC123")

    body = response(conn, 200)

    assert ["application/n-quads; charset=utf-8"] =
             get_resp_header(conn, "content-type")

    assert body =~ "<https://sheaf.less.rest/DOC123> "
    assert body =~ "<http://www.w3.org/2000/01/rdf-schema#label>"
    assert body =~ "<https://sheaf.less.rest/DOC123> .\n"
    refute body =~ "<https://sheaf.less.rest/BLOCK1> "
  end

  @tag :tmp_dir
  test "returns an empty n-quads response for ids with no subject quads", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    conn =
      conn
      |> put_req_header("accept", "application/n-quads")
      |> get(~p"/MISSING")

    assert response(conn, 200) == ""
  end
end
