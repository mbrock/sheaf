defmodule Mix.Tasks.Sheaf.Schema do
  use Mix.Task

  @shortdoc "Uploads priv/sheaf-schema.ttl to the schema named graph"

  alias Finch.Response
  alias Sheaf.NS.Sheaf, as: SheafNS

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [] ->
        schema_graph = SheafNS.__base_iri__()

        request =
          Finch.build(
            :put,
            graph_endpoint(schema_graph),
            [{"content-type", "text/turtle"} | auth_headers()],
            File.read!(schema_path())
          )

        case Finch.request(request, Sheaf.Finch) do
          {:ok, %Response{status: status}} when status in 200..299 ->
            Mix.shell().info("Uploaded schema graph #{schema_graph}")

          {:ok, %Response{status: status, body: body}} ->
            Mix.raise("Failed to upload schema graph (#{status}): #{String.trim(body)}")

          {:error, reason} ->
            Mix.raise("Failed to upload schema graph: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("mix sheaf.schema takes no arguments")
    end
  end

  defp graph_endpoint(schema_graph) do
    data_endpoint() <> "?" <> URI.encode_query(%{"graph" => schema_graph})
  end

  defp auth_headers do
    Application.get_env(:sparql_client, :http_headers, %{})
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp schema_path do
    Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")
  end

  defp data_endpoint do
    Application.get_env(:sheaf, Sheaf, [])[:data_endpoint]
  end
end
