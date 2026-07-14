defmodule SheafWeb.MCPControllerTest do
  use SheafWeb.ConnCase, async: true

  test "serves authenticated Streamable HTTP initialize requests", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-mcp-token")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-11-25",
               "serverInfo" => %{"name" => "sheaf"}
             }
           } = json_response(conn, 200)
  end

  test "requires the configured bearer token", %{conn: conn} do
    conn =
      post(conn, "/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      })

    assert %{"error" => "invalid or missing bearer token"} =
             json_response(conn, 401)

    assert [~s(Bearer realm="Sheaf MCP")] =
             get_resp_header(conn, "www-authenticate")
  end

  test "rejects untrusted browser origins", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-mcp-token")
      |> put_req_header("origin", "https://hostile.example")
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-11-25"}
      })

    assert %{"error" => "origin is not allowed"} = json_response(conn, 403)
  end

  test "rejects unsupported protocol headers after initialization", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-mcp-token")
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    assert %{
             "error" => "unsupported MCP protocol version",
             "requested" => "1999-01-01"
           } = json_response(conn, 400)
  end

  test "declines standalone SSE streams", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer test-mcp-token")
      |> put_req_header("accept", "text/event-stream")
      |> get("/mcp")

    assert response(conn, 405) == ""
    assert get_resp_header(conn, "allow") == ["POST"]
  end
end
