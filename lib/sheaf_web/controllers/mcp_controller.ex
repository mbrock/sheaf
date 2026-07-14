defmodule SheafWeb.MCPController do
  @moduledoc """
  Stateless MCP Streamable HTTP endpoint.
  """

  use SheafWeb, :controller

  alias Sheaf.MCP

  def create(conn, params) do
    with :ok <- validate_protocol_header(conn, params) do
      case MCP.handle(params) do
        {:response, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> json(body)

        :accepted ->
          send_resp(conn, 202, "")
      end
    else
      {:error, version} ->
        conn
        |> put_status(400)
        |> json(%{
          error: "unsupported MCP protocol version",
          requested: version,
          supported: MCP.supported_protocol_versions()
        })
    end
  end

  def index(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp validate_protocol_header(_conn, %{"method" => "initialize"}), do: :ok

  defp validate_protocol_header(conn, _params) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version] when version in ["2025-11-25", "2025-06-18", "2025-03-26"] ->
        :ok

      [version] ->
        {:error, version}

      versions ->
        {:error, Enum.join(versions, ", ")}
    end
  end
end
