defmodule Mix.Tasks.Sheaf.Embeddings.Sync do
  @moduledoc """
  Builds Sheaf's derived SQLite embedding index.
  """

  use Mix.Task

  @shortdoc "Embeds current text-bearing RDF blocks into SQLite"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          db: :string,
          dimensions: :integer,
          concurrency: :integer,
          limit: :integer,
          kind: :keep,
          model: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end

    sync_opts =
      []
      |> put_if_present(:db_path, Keyword.get(opts, :db))
      |> put_if_present(:output_dimensionality, Keyword.get(opts, :dimensions))
      |> put_if_present(:max_concurrency, Keyword.get(opts, :concurrency))
      |> put_if_present(:limit, Keyword.get(opts, :limit))
      |> put_if_present(:model, Keyword.get(opts, :model))
      |> put_kinds(Keyword.get_values(opts, :kind))

    case Sheaf.Embedding.Index.sync(sync_opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "Embedding sync #{summary.status}: run=#{summary.run_iri} target=#{summary.target_count} embedded=#{summary.embedded_count} skipped=#{summary.skipped_count} errors=#{summary.error_count}"
        )

      {:error, reason} ->
        Mix.raise("Embedding sync failed: #{inspect(reason)}")
    end
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_kinds(opts, []), do: opts
  defp put_kinds(opts, kinds), do: Keyword.put(opts, :kinds, kinds)
end
