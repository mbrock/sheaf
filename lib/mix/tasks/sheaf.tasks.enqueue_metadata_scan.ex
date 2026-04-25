defmodule Mix.Tasks.Sheaf.Tasks.EnqueueMetadataScan do
  @moduledoc """
  Enqueues source-linked documents for bibliographic metadata resolution.
  """

  use Mix.Task

  @shortdoc "Enqueues metadata resolution tasks"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional} =
      OptionParser.parse!(args,
        strict: [
          all: :boolean,
          missing_only: :boolean,
          limit: :integer,
          doc: :string,
          telegram: :boolean
        ]
      )

    if positional != [], do: Mix.raise("Unexpected arguments: #{inspect(positional)}")

    resolver_opts = resolver_opts(opts)

    case Sheaf.MetadataResolver.Queue.enqueue(resolver_opts) do
      {:ok, batch} ->
        message = "Enqueued #{batch.target_count} metadata task(s) in #{short(batch.iri)}"
        Mix.shell().info(message)
        if opts[:telegram], do: Sheaf.Telegram.notify(telegram_message(batch, resolver_opts))

      {:error, reason} ->
        Mix.raise("Failed to enqueue metadata tasks: #{inspect(reason)}")
    end
  end

  defp resolver_opts(opts) do
    []
    |> Keyword.put(:missing_only, missing_only?(opts))
    |> put_opt(:limit, opts[:limit])
    |> put_opt(:document, opts[:doc])
  end

  defp missing_only?(opts) do
    cond do
      opts[:all] -> false
      Keyword.has_key?(opts, :missing_only) -> opts[:missing_only]
      true -> true
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp short(iri), do: String.replace_prefix(to_string(iri), "https://sheaf.less.rest/", "")

  defp telegram_message(batch, opts) do
    scope =
      cond do
        opts[:document] -> "one document"
        opts[:limit] -> "up to #{opts[:limit]} document(s)"
        opts[:missing_only] -> "all documents missing Crossref metadata"
        true -> "all source-linked documents"
      end

    """
    Sheaf metadata batch queued

    Batch: #{short(batch.iri)}
    Scope: #{scope}
    Initial tasks: #{batch.target_count} identifier extraction task(s)

    Workflow:
    - extract DOI/ISBN from bounded front-matter text
    - optionally fall back to first PDF pages only
    - look up Crossref serially
    - import accepted matches into RDF serially
    """
    |> String.trim()
  end
end
