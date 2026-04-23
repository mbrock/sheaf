defmodule Mix.Tasks.Sheaf.Backup do
  use Mix.Task

  @shortdoc "Backs up configured named graphs to Turtle files"

  alias Sheaf.GraphStore

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [graph: :string, output: :string])

    case invalid do
      [] ->
        opts
        |> target_graphs()
        |> Enum.with_index()
        |> Enum.each(fn {graph_name, index} ->
          output_path = output_path(opts, graph_name, index)

          case GraphStore.backup_graph(graph_name, output_path) do
            {:ok, path} ->
              Mix.shell().info("Backed up #{graph_name} to #{path}")

            {:error, message} ->
              Mix.raise(message)
          end
        end)

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp target_graphs(opts) do
    case Keyword.get_values(opts, :graph) do
      [] -> GraphStore.backup_graphs()
      graph_names -> graph_names
    end
  end

  defp output_path(opts, graph_name, 0) do
    Keyword.get_lazy(opts, :output, fn -> GraphStore.default_backup_path(graph_name) end)
  end

  defp output_path(_opts, graph_name, _index), do: GraphStore.default_backup_path(graph_name)
end
