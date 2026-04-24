defmodule Mix.Tasks.Sheaf.ImportDatalabJson do
  use Mix.Task

  @shortdoc "Imports Datalab JSON as a Sheaf paper graph"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [title: :string, no_backup: :boolean])

    cond do
      invalid != [] ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")

      length(paths) != 1 ->
        Mix.raise("Usage: mix sheaf.import_datalab_json PATH [--title TITLE] [--no-backup]")

      true ->
        unless opts[:no_backup], do: Mix.Task.run("sheaf.backup")

        [path] = paths
        import!(path, opts)
    end
  end

  defp import!(path, opts) do
    case Sheaf.PaperImport.import_file(path, title: opts[:title]) do
      {:ok, result} ->
        id = Sheaf.Id.id_from_iri(result.document)

        Mix.shell().info("Imported #{result.title}")
        Mix.shell().info("Graph #{result.document}")
        Mix.shell().info("URL /#{id}")

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end
end
