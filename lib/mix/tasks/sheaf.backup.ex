defmodule Mix.Tasks.Sheaf.Backup do
  use Mix.Task

  @shortdoc "Backs up configured named graphs to Turtle files"

  alias RDF.Turtle

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

          case backup_graph(graph_name, output_path) do
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
      [] -> configured_graphs()
      graph_names -> graph_names
    end
  end

  defp output_path(opts, graph_name, 0) do
    Keyword.get_lazy(opts, :output, fn -> default_backup_path(graph_name) end)
  end

  defp output_path(_opts, graph_name, _index), do: default_backup_path(graph_name)

  defp backup_graph(graph_name, output_path) do
    with {:ok, graph} <- Sheaf.fetch_graph(graph_name) do
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, Turtle.write_string!(graph))
      {:ok, output_path}
    end
  end

  defp configured_graphs do
    graph_store_config()
    |> Keyword.get(:backup_graphs)
    |> normalize_graph_names()
    |> case do
      [] -> normalize_graph_names([Keyword.get(graph_store_config(), :graph)])
      graph_names -> graph_names
    end
  end

  defp default_backup_path(graph_name) do
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()
      |> String.replace(":", "-")

    Path.join(["output", "backups", "#{graph_slug(graph_name)}-#{timestamp}.ttl"])
  end

  defp graph_slug(graph_name) do
    graph_name
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  defp normalize_graph_names(graph_names) do
    graph_names
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp graph_store_config do
    Application.get_env(:sheaf, Sheaf, [])
  end
end
