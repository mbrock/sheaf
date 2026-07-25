defmodule SheafWeb.LibraryMarkdownPlugTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "serves a concise linked library index for Markdown clients", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC999")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {document, RDF.type(), DOC.Document},
                   {document, RDFS.label(), "Agent-readable book"}
                 ],
                 name: document
               )
             )

    conn =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get("/")

    assert get_resp_header(conn, "content-type") == [
             "text/markdown; charset=utf-8"
           ]

    assert get_resp_header(conn, "vary") == ["Accept"]
    assert markdown = response(conn, 200)
    assert markdown =~ "# Sheaf library"
    assert markdown =~ "`Accept: text/markdown`"

    assert markdown =~
             "[Agent-readable book](#{read_url("DOC999")})"
  end

  defp read_url(id) do
    URI.merge(Id.base_iri(), "/read/#{id}") |> URI.to_string()
  end
end
