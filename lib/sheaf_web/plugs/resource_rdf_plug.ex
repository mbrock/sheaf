defmodule SheafWeb.ResourceRDFPlug do
  @moduledoc """
  Serves `/:id` resources as N-Quads when requested with an RDF quad accept type.
  """

  import Plug.Conn

  require OpenTelemetry.Tracer, as: Tracer

  @reserved ~w(api assets b dev health history live phoenix rdf search sheaf-schema.ttl)
  @nquads_accepts ["application/n-quads", "application/nquads"]

  def init(opts), do: opts

  def call(%{method: "GET"} = conn, _opts) do
    with true <- nquads_request?(conn),
         [id] <- conn.path_info,
         false <- id in @reserved do
      stream_resource(conn, id)
    else
      _other -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp stream_resource(conn, id) do
    subject = Sheaf.Id.iri(id)
    pattern = {subject, nil, nil, nil}

    conn =
      conn
      |> put_resp_content_type("application/n-quads")
      |> send_chunked(200)

    case Quadlog.stream_nquads(Sheaf.Repo.path(), pattern, conn, &chunk/2, []) do
      {:ok, count, conn} ->
        Tracer.set_attribute("sheaf.rdf.quad_count", count)
        halt(conn)

      {:error, reason} ->
        raise "failed to stream RDF resource #{inspect(id)}: #{inspect(reason)}"
    end
  end

  defp nquads_request?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept ->
      Enum.any?(@nquads_accepts, &String.contains?(accept, &1))
    end)
  end
end
