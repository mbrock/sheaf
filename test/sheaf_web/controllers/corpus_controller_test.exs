defmodule SheafWeb.CorpusControllerTest do
  use SheafWeb.ConnCase, async: true

  alias SheafWeb.CorpusController

  test "requires a query", %{conn: conn} do
    conn = get(conn, ~p"/corpus")

    assert text_response(conn, 400) == "Missing required query parameter: q\n"
  end

  test "returns html by default", %{conn: conn} do
    conn = get(conn, ~p"/corpus", q: "")

    assert get_resp_header(conn, "content-type") == [
             "text/html; charset=utf-8"
           ]

    assert response(conn, 200) =~ "<!doctype html>"
    assert response(conn, 200) =~ "No results found for &quot;&quot;."
  end

  test "returns markdown when requested by accept header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/markdown")
      |> get(~p"/corpus", q: "")

    assert get_resp_header(conn, "content-type") == [
             "text/markdown; charset=utf-8"
           ]

    assert response(conn, 200) == "No results found for \"\".\n"
  end

  test "returns turtle when requested by accept header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/turtle")
      |> get(~p"/corpus", q: "")

    assert get_resp_header(conn, "content-type") == [
             "text/turtle; charset=utf-8"
           ]

    assert response(conn, 200) =~ "@prefix :"
  end

  test "format parameter does not request turtle", %{conn: conn} do
    conn = get(conn, ~p"/corpus", q: "", format: "ttl")

    assert get_resp_header(conn, "content-type") == [
             "text/html; charset=utf-8"
           ]

    assert response(conn, 200) =~ "No results found"
  end

  test "path query route uses trailing path parts as the query", %{conn: conn} do
    conn = get(conn, "/corpus/%20")

    assert get_resp_header(conn, "content-type") == [
             "text/html; charset=utf-8"
           ]

    assert response(conn, 200) =~ "No results found for &quot; &quot;."
  end

  test "path query syntax joins trailing path parts with spaces" do
    assert CorpusController.path_query([
             "schatzki",
             "macintyre",
             "teleology"
           ]) == "schatzki macintyre teleology"
  end
end
