defmodule SheafWeb.ResourceControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "serves a resolved resource as JSON from /:id", %{conn: conn, tmp_dir: tmp_dir} do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC123")
    section = Id.iri("SEC123")
    list = Id.iri("LIST12")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDF.type(), DOC.Thesis},
          {document, RDFS.label(), RDF.literal("Example Thesis")},
          {document, DOC.children(), list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Introduction")}
        ],
        name: document
      )
      |> then(fn graph -> RDF.list([section], graph: graph, head: list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/DOC123")

    assert %{
             "id" => "DOC123",
             "iri" => "https://sheaf.less.rest/DOC123",
             "kind" => "thesis",
             "title" => "Example Thesis",
             "outline" => [
               %{
                 "id" => "SEC123",
                 "title" => "Introduction",
                 "number" => "1"
               }
             ]
           } = json_response(conn, 200)
  end
end
