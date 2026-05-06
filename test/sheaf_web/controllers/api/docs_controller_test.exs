defmodule SheafWeb.API.DocsControllerTest do
  use SheafWeb.ConnCase, async: true

  test "returns structured docs for a function", %{conn: conn} do
    conn = get(conn, ~p"/api/docs", %{target: "Sheaf.mint/0", source: "true"})

    assert %{
             "targets" => [
               %{
                 "kind" => "function_group",
                 "requested_as" => "Sheaf.mint/0",
                 "functions" => [
                   %{
                     "name" => "mint",
                     "arity" => 0,
                     "signature" => "mint()",
                     "source_excerpt" => %{
                       "from" => from,
                       "to" => to,
                       "lines" => lines
                     }
                   }
                 ]
               }
             ]
           } = json_response(conn, 200)

    assert from <= to
    assert Enum.any?(lines, &(&1 =~ "def mint"))
  end
end
