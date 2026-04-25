defmodule Mix.Tasks.Sheaf.ImportSpreadsheet do
  @moduledoc """
  Imports a CSV spreadsheet into the Sheaf RDF dataset as a named graph.
  """

  use Mix.Task

  @shortdoc "Imports a CSV spreadsheet as a Sheaf graph"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [title: :string, graph: :string, no_backup: :boolean])

    cond do
      invalid != [] ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")

      length(paths) != 1 ->
        Mix.raise(
          "Usage: mix sheaf.import_spreadsheet PATH [--title TITLE] [--graph IRI] [--no-backup]"
        )

      true ->
        unless opts[:no_backup], do: Mix.Task.run("sheaf.backup")

        [path] = paths
        import!(path, opts)
    end
  end

  defp import!(path, opts) do
    import_opts =
      opts
      |> Keyword.take([:title])
      |> maybe_put_document(opts[:graph])

    case Sheaf.Spreadsheet.import_file(path, import_opts) do
      {:ok, result} ->
        id = Sheaf.Id.id_from_iri(result.document)

        Mix.shell().info("Imported #{result.title}")
        Mix.shell().info("Graph #{result.document}")
        Mix.shell().info("Sources #{result.sources}")
        Mix.shell().info("Rows #{result.rows}")
        Mix.shell().info("URL /#{id}")

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  defp maybe_put_document(opts, nil), do: opts
  defp maybe_put_document(opts, graph), do: Keyword.put(opts, :document, RDF.iri(graph))
end
