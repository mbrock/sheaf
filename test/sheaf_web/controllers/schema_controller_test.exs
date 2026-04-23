defmodule SheafWeb.SchemaControllerTest do
  use SheafWeb.ConnCase, async: true

  test "serves the sheaf schema", %{conn: conn} do
    conn = get(conn, ~p"/sheaf-schema.ttl")

    assert response(conn, 200) =~ "@prefix sheaf: <https://less.rest/sheaf/> ."
    assert ["text/turtle; charset=utf-8"] = get_resp_header(conn, "content-type")
  end
end
