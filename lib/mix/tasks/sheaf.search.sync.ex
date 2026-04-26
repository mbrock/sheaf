defmodule Mix.Tasks.Sheaf.Search.Sync do
  @moduledoc """
  Rebuilds Sheaf's derived SQLite full-text search mirror.
  """

  use Mix.Task

  @shortdoc "Mirrors current RDF text units into SQLite FTS"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          db: :string,
          limit: :integer,
          kind: :keep
        ]
      )

    if invalid != [] do
      Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end

    sync_opts =
      []
      |> put_if_present(:db_path, Keyword.get(opts, :db))
      |> put_if_present(:limit, Keyword.get(opts, :limit))
      |> put_kinds(Keyword.get_values(opts, :kind))

    case Sheaf.Search.Index.sync(sync_opts) do
      {:ok, summary} ->
        Mix.shell().info(
          "Search sync complete: db=#{summary.db_path} rows=#{summary.count}#{kind_summary(summary.kinds)}"
        )

      {:error, reason} ->
        Mix.raise("Search sync failed: #{inspect(reason)}")
    end
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_kinds(opts, []), do: opts
  defp put_kinds(opts, kinds), do: Keyword.put(opts, :kinds, kinds)

  defp kind_summary(kinds) when map_size(kinds) == 0, do: ""

  defp kind_summary(kinds) do
    kinds
    |> Enum.sort()
    |> Enum.map(fn {kind, count} -> "#{kind}=#{count}" end)
    |> Enum.join(" ")
    |> then(&(" " <> &1))
  end
end
