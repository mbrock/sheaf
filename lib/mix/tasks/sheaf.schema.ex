defmodule Mix.Tasks.Sheaf.Schema do
  use Mix.Task

  @shortdoc "Uploads priv/sheaf-schema.ttl to the schema named graph"

  alias Sheaf.NS.Sheaf, as: SHEAF

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Req.put!(data_endpoint(),
      params: [graph: RDF.IRI.to_string(SHEAF)],
      headers: [{"content-type", "text/turtle"} | auth_headers()],
      body: File.read!(schema_path())
    )
    |> case do
      %{status: status} when status in 200..299 ->
        Mix.shell().info("Uploaded schema graph #{SHEAF}")

      %{status: status, body: body} ->
        Mix.raise("Failed to upload schema graph (#{status}): #{body}")
    end
  end

  defp auth_headers do
    Application.get_env(:sparql_client, :http_headers, %{})
  end

  defp schema_path do
    Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")
  end

  defp data_endpoint do
    Application.get_env(:sheaf, Sheaf, [])[:data_endpoint]
  end
end
