defmodule Mix.Tasks.Sheaf.Tasks.Work do
  @moduledoc """
  Runs queued Sheaf tasks.
  """

  use Mix.Task

  @shortdoc "Works queued Sheaf tasks"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional} =
      OptionParser.parse!(args,
        strict: [
          limit: :integer,
          concurrency: :integer,
          extract_concurrency: :integer,
          lookup_concurrency: :integer,
          match_concurrency: :integer,
          import_concurrency: :integer,
          telegram: :boolean,
          pdf_fallback: :boolean,
          pdf_pages: :integer,
          model: :string,
          receive_timeout: :integer
        ]
      )

    if positional not in [[], ["metadata"]],
      do: Mix.raise("Unexpected arguments: #{inspect(positional)}")

    worker_opts =
      []
      |> Keyword.put(:limit, opts[:limit] || 1)
      |> Keyword.put(:concurrency_by_kind, concurrency_by_kind(opts))
      |> Keyword.put(:telegram, opts[:telegram] || false)
      |> put_opt(:pdf_fallback, opts[:pdf_fallback])
      |> put_opt(:pdf_pages, opts[:pdf_pages])
      |> put_opt(:model, opts[:model])
      |> put_opt(:receive_timeout, opts[:receive_timeout])

    {:ok, result} = Sheaf.MetadataResolver.Queue.work(worker_opts)

    Mix.shell().info(
      "Processed #{result.processed}; imported #{result.imported}, skipped #{result.skipped}, errors #{result.errors}."
    )
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp concurrency_by_kind(opts) do
    extract = opts[:extract_concurrency] || opts[:concurrency]

    %{}
    |> put_kind("metadata.extract_identifiers", extract)
    |> put_kind("metadata.resolve_document", extract)
    |> put_kind("metadata.crossref.lookup", opts[:lookup_concurrency])
    |> put_kind("metadata.match_candidate", opts[:match_concurrency])
    |> put_kind("metadata.import_crossref", opts[:import_concurrency])
  end

  defp put_kind(map, _kind, nil), do: map
  defp put_kind(map, kind, value), do: Map.put(map, kind, value)
end
