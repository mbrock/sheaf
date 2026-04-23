defmodule Mix.Tasks.Sheaf.Schema do
  use Mix.Task

  @shortdoc "Verifies or syncs the schema named graph"

  alias RDF.Graph
  alias Sheaf.NS.Sheaf, as: SheafNS

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} = OptionParser.parse(args, strict: [sync: :boolean])

    case invalid do
      [] ->
        sync? = Keyword.get(opts, :sync, false)
        schema_graph = SheafNS.__base_iri__()
        local_schema = local_schema()
        remote_schema = remote_schema(schema_graph)

        cond do
          Graph.isomorphic?(local_schema, remote_schema) ->
            Mix.shell().info("Schema graph #{schema_graph} is in sync")

          sync? ->
            sync_schema(schema_graph, local_schema)
            verify_synced!(schema_graph, local_schema)
            Mix.shell().info("Synced schema graph #{schema_graph}")

          true ->
            Mix.raise("""
            Schema graph #{schema_graph} does not match priv/sheaf-schema.ttl
            Run `mix sheaf.schema --sync` to replace it.
            """)
        end

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp verify_synced!(schema_graph, local_schema) do
    if Graph.isomorphic?(local_schema, remote_schema(schema_graph)) do
      :ok
    else
      Mix.raise(
        "Schema graph #{schema_graph} still does not match priv/sheaf-schema.ttl after sync"
      )
    end
  end

  defp sync_schema(schema_graph, local_schema) do
    case SPARQL.Client.clear(update_endpoint(), graph: schema_graph, silent: true) do
      :ok ->
        dataset =
          local_schema
          |> Graph.new(name: schema_graph)
          |> RDF.Dataset.new()

        case SPARQL.Client.insert_data(dataset, update_endpoint()) do
          :ok -> :ok
          {:error, reason} -> Mix.raise("Failed to insert schema graph: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Failed to clear schema graph: #{inspect(reason)}")
    end
  end

  defp remote_schema(schema_graph) do
    """
    CONSTRUCT { ?s ?p ?o }
    WHERE {
      GRAPH <#{schema_graph}> {
        ?s ?p ?o .
      }
    }
    """
    |> SPARQL.Client.construct(query_endpoint())
    |> case do
      {:ok, %Graph{} = graph} ->
        graph

      {:error, reason} ->
        Mix.raise("Failed to fetch schema graph: #{inspect(reason)}")

      other ->
        Mix.raise("Unexpected schema graph response: #{inspect(other)}")
    end
  end

  defp local_schema do
    Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")
    |> RDF.Turtle.read_file!()
  end

  defp query_endpoint do
    Application.get_env(:sheaf, Sheaf, [])[:query_endpoint]
  end

  defp update_endpoint do
    Application.get_env(:sheaf, Sheaf, [])[:update_endpoint]
  end
end
