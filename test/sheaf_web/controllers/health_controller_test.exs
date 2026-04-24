defmodule SheafWeb.HealthControllerTest do
  use SheafWeb.ConnCase, async: true

  test "reports ok when the application is ready", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert %{"status" => "ok"} = json_response(conn, 200)
  end
end
