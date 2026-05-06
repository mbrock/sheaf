defmodule SheafWeb.ResourceJSONPlug do
  @moduledoc """
  Serves `/:id` resources as JSON when requested with `Accept: application/json`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @reserved ~w(api assets b dev health history live phoenix rdf search sheaf-schema.ttl)

  def init(opts), do: opts

  def call(%{method: "GET"} = conn, _opts) do
    with true <- json_request?(conn),
         [id] <- conn.path_info,
         false <- id in @reserved do
      send_resource(conn, id)
    else
      _other -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp send_resource(conn, id) do
    case SheafWeb.ResourceController.resource_payload(id) do
      {:ok, payload} ->
        conn
        |> json(payload)
        |> halt()

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "resource not found", id: id, reason: inspect(reason)})
        |> halt()
    end
  end

  defp json_request?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "application/json"))
  end
end
