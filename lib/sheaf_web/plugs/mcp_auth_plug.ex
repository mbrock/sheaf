defmodule SheafWeb.MCPAuthPlug do
  @moduledoc """
  Bearer-token authentication and Origin validation for the MCP endpoint.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:sheaf, Sheaf.MCP, [])

    with :ok <- validate_origin(conn, config),
         :ok <- authenticate(conn, config) do
      conn
    else
      {:error, :origin} ->
        reject(conn, 403, "origin is not allowed")

      {:error, :not_configured} ->
        reject(conn, 503, "MCP access is not configured")

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  defp authenticate(conn, config) do
    token = config[:token]

    cond do
      not is_binary(token) or token == "" ->
        {:error, :not_configured}

      bearer_token(conn) |> secure_match?(token) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _headers -> nil
    end
  end

  defp secure_match?(left, right)
       when is_binary(left) and is_binary(right) and
              byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_match?(_left, _right), do: false

  defp validate_origin(conn, config) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        allowed =
          Enum.map(config[:allowed_origins] || [], &normalize_origin/1)

        same_origin = request_origin(conn)

        if normalize_origin(origin) in [same_origin | allowed],
          do: :ok,
          else: {:error, :origin}

      _origins ->
        {:error, :origin}
    end
  end

  defp request_origin(conn) do
    default_port = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port == default_port, do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{String.downcase(conn.host)}#{port}"
  end

  defp normalize_origin(origin) do
    origin
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.downcase()
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer realm="Sheaf MCP"))
    |> reject(401, "invalid or missing bearer token")
  end

  defp reject(conn, status, message) do
    body = Jason.encode!(%{error: message})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end
end
