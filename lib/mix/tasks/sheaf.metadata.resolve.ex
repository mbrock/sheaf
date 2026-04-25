defmodule Mix.Tasks.Sheaf.Metadata.Resolve do
  @moduledoc """
  Resolves bibliographic metadata for source-linked documents.

  By default this processes only documents without a metadata-graph
  `fabio:isRepresentationOf` link. A dry run lists candidates and verifies blob
  paths without calling the LLM or writing RDF.
  """

  use Mix.Task

  @shortdoc "Resolves document metadata from stored PDFs"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          file_data: :boolean,
          all: :boolean,
          missing_only: :boolean,
          limit: :integer,
          doc: :string,
          pdf_fallback: :boolean,
          pdf_pages: :integer,
          model: :string,
          receive_timeout: :integer
        ]
      )

    cond do
      invalid != [] ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")

      positional != [] ->
        Mix.raise("Unexpected arguments: #{inspect(positional)}")

      true ->
        run_resolver!(resolver_opts(opts), opts)
    end
  end

  defp run_resolver!(resolver_opts, cli_opts) do
    with {:ok, candidates} <- Sheaf.MetadataResolver.candidates(resolver_opts) do
      cond do
        cli_opts[:file_data] -> print_file_data(candidates, resolver_opts)
        cli_opts[:dry_run] -> print_dry_run(candidates, resolver_opts)
        true -> resolve!(candidates, resolver_opts)
      end
    else
      {:error, reason} -> Mix.raise("Failed to list metadata candidates: #{inspect(reason)}")
    end
  end

  defp print_dry_run(candidates, resolver_opts) do
    Mix.shell().info(
      "Would resolve #{length(candidates)} #{candidate_scope(resolver_opts)} documents from stored PDFs."
    )

    Enum.each(candidates, fn candidate ->
      Mix.shell().info(candidate_line(candidate))
    end)
  end

  defp print_file_data(candidates, resolver_opts) do
    Mix.shell().info(
      "File data for #{length(candidates)} #{candidate_scope(resolver_opts)} documents; no LLM requests, no RDF writes."
    )

    Enum.each(candidates, fn candidate ->
      Mix.shell().info(file_data_line(candidate))
    end)
  end

  defp resolve!(candidates, resolver_opts) do
    Mix.shell().info(
      "Resolving #{length(candidates)} #{candidate_scope(resolver_opts)} documents from stored PDFs."
    )

    results =
      candidates
      |> Enum.with_index(1)
      |> Enum.map(fn {candidate, index} ->
        Mix.shell().info("[#{index}/#{length(candidates)}] #{candidate_line(candidate)}")

        case Sheaf.MetadataResolver.resolve(candidate, resolver_opts) do
          {:ok, result} ->
            print_result(result)
            {:ok, result}

          {:error, reason} ->
            Mix.shell().error("ERROR #{short_iri(candidate.document)}: #{inspect(reason)}")
            {:error, {candidate, reason}}
        end
      end)

    imported = Enum.count(results, &match?({:ok, %{wrote?: true}}, &1))
    no_doi = Enum.count(results, &match?({:ok, %{wrote?: false}}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("Done. Imported #{imported}, no DOI #{no_doi}, errors #{errors}.")

    if errors > 0, do: Mix.raise("Some metadata resolutions failed.")
  end

  defp print_result(%{metadata: metadata, wrote?: true, crossref: crossref}) do
    Mix.shell().info("  metadata #{metadata_line(metadata)}")
    Mix.shell().info("  crossref #{crossref.doi} expression=#{short_iri(crossref.expression)}")
  end

  defp print_result(%{metadata: metadata, wrote?: false}) do
    Mix.shell().info("  metadata #{metadata_line(metadata)}")
    Mix.shell().info("  no DOI; skipped RDF write")
  end

  defp resolver_opts(opts) do
    []
    |> Keyword.put(:missing_only, missing_only?(opts))
    |> put_opt(:limit, opts[:limit])
    |> put_opt(:document, opts[:doc])
    |> put_opt(:pdf_fallback, opts[:pdf_fallback])
    |> put_opt(:pdf_pages, opts[:pdf_pages])
    |> put_opt(:model, opts[:model])
    |> put_opt(:receive_timeout, opts[:receive_timeout])
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

  defp candidate_scope(opts) do
    if Keyword.get(opts, :missing_only, true), do: "missing-metadata", else: "source-linked"
  end

  defp candidate_line(candidate) do
    original = candidate.original_filename || Path.basename(candidate.path)

    [
      short_iri(candidate.document),
      "file=#{short_iri(candidate.file)}",
      "original=#{inspect(original)}",
      "path=#{candidate.path}"
    ]
    |> Enum.join(" ")
  end

  defp file_data_line(candidate) do
    [
      short_iri(candidate.document),
      "file=#{short_iri(candidate.file)}",
      "original=#{inspect(candidate.original_filename || Path.basename(candidate.path))}",
      field("mime", candidate.mime_type),
      field("bytes", candidate.byte_size),
      field("sha256", short_hash(candidate.sha256)),
      field("stored", date_time(candidate.generated_at)),
      field("pdf_title", pdf_title(candidate.path)),
      "path=#{candidate.path}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp metadata_line(metadata) do
    [
      field("title", metadata.title),
      field("doi", metadata.doi),
      field("authors", authors(metadata.authors)),
      field("year", metadata.year),
      field("publication", metadata.publication),
      field("confidence", metadata.confidence)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp field(_label, nil), do: nil
  defp field(_label, ""), do: nil
  defp field(label, value), do: "#{label}=#{inspect(value)}"

  defp short_hash(nil), do: nil
  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)

  defp date_time(nil), do: nil
  defp date_time(%DateTime{} = date_time), do: DateTime.to_iso8601(date_time)
  defp date_time(value), do: to_string(value)

  defp pdf_title(path) do
    with executable when is_binary(executable) <- System.find_executable("pdfinfo"),
         {output, 0} <- System.cmd(executable, [path], stderr_to_stdout: true) do
      output
      |> String.split("\n")
      |> Enum.find_value(fn
        "Title:" <> title -> blank_to_nil(String.trim(title))
        _line -> nil
      end)
    else
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp authors([]), do: nil
  defp authors(authors), do: Enum.join(authors, "; ")

  defp short_iri(nil), do: "(none)"

  defp short_iri(iri) do
    iri
    |> to_string()
    |> String.replace_prefix("https://sheaf.less.rest/", "")
  end
end
