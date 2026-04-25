defmodule Sheaf.MetadataResolver do
  @moduledoc """
  Resolves bibliographic metadata for stored documents.

  The resolver is deliberately conservative: it uses the document's
  `sheaf:sourceFile` link to find the original stored PDF, asks the LLM for a
  DOI from that PDF, and only writes DOI-backed Crossref metadata. It does not
  invent document labels or write LLM-only title facts.
  """

  alias RDF.Description
  alias Sheaf.NS.DOC

  @metadata_graph "https://less.rest/sheaf/metadata"

  @type candidate :: %{
          required(:document) => RDF.IRI.t(),
          required(:file) => RDF.IRI.t(),
          required(:path) => Path.t(),
          optional(:label) => String.t(),
          optional(:metadata_expression) => RDF.IRI.t(),
          optional(:original_filename) => String.t(),
          optional(:mime_type) => String.t(),
          optional(:byte_size) => integer(),
          optional(:sha256) => String.t(),
          optional(:generated_at) => DateTime.t()
        }

  @type resolve_result :: %{
          required(:candidate) => candidate(),
          required(:metadata) => Sheaf.PaperMetadata.t(),
          required(:wrote?) => boolean(),
          optional(:crossref) => map(),
          optional(:match) => map()
        }

  @doc """
  Returns source-linked document candidates with resolved blob paths.

  Defaults to documents that do not already have a `fabio:isRepresentationOf`
  link in the metadata graph.
  """
  @spec candidates(keyword()) :: {:ok, [candidate()]} | {:error, term()}
  def candidates(opts \\ []) do
    with {:ok, result} <- select_candidates(opts),
         {:ok, files_graph} <- files_graph(opts) do
      {:ok, candidates_from(result.results, files_graph, opts)}
    end
  end

  @doc """
  Resolves one candidate by extracting metadata from the source PDF.

  If the LLM does not find a DOI, this returns successfully with `wrote?: false`.
  The only RDF write path is `Sheaf.Crossref.import_metadata/2`.
  """
  @spec resolve(candidate(), keyword()) :: {:ok, resolve_result()} | {:error, term()}
  def resolve(%{path: path} = candidate, opts \\ []) when is_binary(path) do
    with true <- File.exists?(path) || {:error, {:missing_blob, path}},
         {:ok, metadata} <- Sheaf.PaperMetadata.extract_pdf(path, llm_opts(opts)) do
      resolve_metadata(candidate, metadata, opts)
    end
  end

  @doc """
  Resolves one queued task input map.
  """
  @spec resolve_task(map(), keyword()) :: {:ok, resolve_result()} | {:error, term()}
  def resolve_task(input, opts \\ []) when is_map(input) do
    input
    |> candidate_from_input()
    |> resolve(opts)
  end

  @doc false
  def candidates_from(rows, files_graph, opts \\ []) when is_list(rows) do
    files = Sheaf.Files.descriptions(files_graph)

    rows
    |> maybe_missing_only(opts)
    |> maybe_document(opts)
    |> Enum.flat_map(&candidate_from_row(&1, files, opts))
    |> maybe_limit(opts)
  end

  @doc false
  def metadata_graph, do: @metadata_graph

  defp select_candidates(opts) do
    select = Keyword.get(opts, :select, &Sheaf.select/1)
    select.(candidate_query(Keyword.get(opts, :metadata_graph, @metadata_graph)))
  end

  defp files_graph(opts) do
    case Keyword.fetch(opts, :files_graph) do
      {:ok, graph} -> {:ok, graph}
      :error -> Sheaf.Files.list_graph()
    end
  end

  defp candidate_query(metadata_graph) do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX fabio: <http://purl.org/spar/fabio/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    SELECT ?doc ?file ?label ?expression WHERE {
      GRAPH ?doc {
        ?doc a sheaf:Document ;
          sheaf:sourceFile ?file .
        OPTIONAL { ?doc rdfs:label ?label }
      }
      OPTIONAL {
        GRAPH <#{metadata_graph}> {
          ?doc fabio:isRepresentationOf ?expression .
        }
      }
    }
    ORDER BY ?doc
    """
  end

  defp candidate_from_row(row, files, opts) do
    with {:ok, document} <- Map.fetch(row, "doc"),
         {:ok, file} <- Map.fetch(row, "file"),
         %Description{} = file_description <- Enum.find(files, &(&1.subject == file)),
         {:ok, path} <- Sheaf.Files.local_path(file_description, opts) do
      [
        %{
          document: document,
          file: file,
          path: path,
          label: value(Map.get(row, "label")),
          metadata_expression: Map.get(row, "expression"),
          original_filename: first_value(file_description, DOC.originalFilename()),
          mime_type: first_value(file_description, DOC.mimeType()),
          byte_size: first_value(file_description, DOC.byteSize()),
          sha256: first_value(file_description, DOC.sha256()),
          generated_at: first_value(file_description, Sheaf.NS.PROV.generatedAtTime())
        }
      ]
    else
      _ -> []
    end
  end

  defp maybe_missing_only(rows, opts) do
    if Keyword.get(opts, :missing_only, true) do
      Enum.reject(rows, &Map.get(&1, "expression"))
    else
      rows
    end
  end

  defp maybe_document(rows, opts) do
    case Keyword.get(opts, :document) do
      nil ->
        rows

      document ->
        document = document |> RDF.iri() |> to_string()
        Enum.filter(rows, &(to_string(Map.get(&1, "doc")) == document))
    end
  end

  defp maybe_limit(rows, opts) do
    case Keyword.get(opts, :limit) do
      nil -> rows
      limit when is_integer(limit) and limit >= 0 -> Enum.take(rows, limit)
    end
  end

  defp resolve_metadata(candidate, metadata, opts) do
    cond do
      metadata.doi ->
        resolve_doi(candidate, metadata, metadata.doi, opts)

      metadata.isbn ->
        resolve_isbn(candidate, metadata, opts)

      true ->
        {:ok,
         %{candidate: candidate, metadata: metadata, wrote?: false, match: no_identifier_match()}}
    end
  end

  defp resolve_doi(candidate, metadata, doi, opts) do
    with {:ok, work} <- Sheaf.Crossref.work(doi, crossref_lookup_opts(opts)),
         match = match_crossref(metadata, work, :doi),
         true <- match.accept? || {:ok, no_import(candidate, metadata, match)} do
      import_crossref(candidate, metadata, doi, match, opts)
    end
  end

  defp resolve_isbn(candidate, metadata, opts) do
    with {:ok, works} <- Sheaf.Crossref.works_by_isbn(metadata.isbn, crossref_lookup_opts(opts)),
         {work, match} <- best_isbn_match(metadata, works),
         true <- match.accept? || {:ok, no_import(candidate, metadata, match)},
         doi when is_binary(doi) <-
           work["DOI"] ||
             {:ok,
              no_import(
                candidate,
                metadata,
                Map.put(match, :reason, "matched ISBN record has no DOI")
              )} do
      import_crossref(candidate, metadata, doi, match, opts)
    end
  end

  defp import_crossref(candidate, metadata, doi, match, opts) do
    crossref_opts =
      opts
      |> Keyword.take([:base_url, :req_options])
      |> Keyword.put(:metadata_graph, Keyword.get(opts, :metadata_graph, @metadata_graph))
      |> Keyword.put(:paper, candidate.document)

    with {:ok, crossref} <- Sheaf.Crossref.import_metadata(doi, crossref_opts) do
      {:ok,
       %{candidate: candidate, metadata: metadata, crossref: crossref, wrote?: true, match: match}}
    end
  end

  defp no_import(candidate, metadata, match) do
    %{candidate: candidate, metadata: metadata, wrote?: false, match: match}
  end

  defp crossref_lookup_opts(opts), do: Keyword.take(opts, [:base_url, :req_options])

  defp llm_opts(opts) do
    opts
    |> Keyword.take([
      :model,
      :max_tokens,
      :thinking,
      :reasoning_effort,
      :receive_timeout,
      :provider_options,
      :llm_options,
      :generate_object
    ])
  end

  defp candidate_from_input(input) do
    %{
      document: input |> input_value(:document) |> RDF.iri(),
      file: input |> input_value(:file) |> nullable_iri(),
      path: input_value(input, :path),
      label: input_value(input, :label),
      original_filename: input_value(input, :original_filename),
      mime_type: input_value(input, :mime_type),
      byte_size: input_value(input, :byte_size),
      sha256: input_value(input, :sha256)
    }
  end

  defp input_value(input, key), do: Map.get(input, key) || Map.get(input, to_string(key))

  defp nullable_iri(nil), do: nil
  defp nullable_iri(value), do: RDF.iri(value)

  defp no_identifier_match do
    %{accept?: false, score: 0.0, identifier: nil, source: "none", reason: "no DOI or ISBN found"}
  end

  defp best_isbn_match(metadata, works) do
    works
    |> Enum.map(&{&1, match_crossref(metadata, &1, :isbn)})
    |> Enum.sort_by(fn {_work, match} -> match.score end, :desc)
    |> List.first(
      {%{}, %{accept?: false, score: 0.0, source: "isbn", reason: "no Crossref ISBN candidates"}}
    )
  end

  defp match_crossref(metadata, work, source) do
    score = title_score(metadata.title, first_string(work["title"]))
    type = work["type"]
    threshold = if source == :isbn, do: 0.78, else: 0.62

    %{
      accept?: score >= threshold,
      score: Float.round(score, 3),
      source: Atom.to_string(source),
      identifier: if(source == :isbn, do: metadata.isbn, else: metadata.doi),
      doi: work["DOI"],
      crossref_type: type,
      crossref_title: first_string(work["title"]),
      reason: match_reason(score, threshold, type)
    }
  end

  defp match_reason(score, threshold, type) do
    if score >= threshold do
      "title match accepted for Crossref type #{type || "unknown"}"
    else
      "title match score below #{threshold}"
    end
  end

  defp title_score(nil, _crossref_title), do: 0.0
  defp title_score(_local_title, nil), do: 0.0

  defp title_score(local_title, crossref_title) do
    local = title_tokens(local_title)
    crossref = title_tokens(crossref_title)

    cond do
      MapSet.size(local) == 0 or MapSet.size(crossref) == 0 ->
        0.0

      true ->
        intersection = local |> MapSet.intersection(crossref) |> MapSet.size()
        denominator = min(MapSet.size(local), MapSet.size(crossref))
        intersection / denominator
    end
  end

  defp title_tokens(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp first_string([value | _]), do: first_string(value)
  defp first_string(value) when is_binary(value), do: value
  defp first_string(_value), do: nil

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> value()
  end

  defp value(nil), do: nil
  defp value(term), do: RDF.Term.value(term)
end
