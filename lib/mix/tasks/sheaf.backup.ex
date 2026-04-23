defmodule Mix.Tasks.Sheaf.Backup do
  use Mix.Task

  @shortdoc "Backs up the configured dataset default graph to a Turtle file"

  alias RDF.Turtle

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [output: :string])

    case invalid do
      [] ->
        output_path = output_path(opts)

        case backup_graph(output_path) do
          {:ok, path} ->
            Mix.shell().info("Backed up the default graph to #{path}")

          {:error, message} ->
            Mix.raise(message)
        end

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp output_path(opts) do
    Keyword.get_lazy(opts, :output, &default_backup_path/0)
  end

  defp backup_graph(output_path) do
    with {:ok, graph} <- Sheaf.fetch_graph() do
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, Turtle.write_string!(graph))
      {:ok, output_path}
    end
  end

  defp default_backup_path do
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()
      |> String.replace(":", "-")

    Path.join(["output", "backups", "default-#{timestamp}.ttl"])
  end
end
