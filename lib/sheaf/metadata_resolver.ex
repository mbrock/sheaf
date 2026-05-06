defmodule Sheaf.MetadataResolver do
  @moduledoc """
  Resolves bibliographic metadata for stored documents.

  The resolver is deliberately conservative: it uses bounded bibliographic text
  from the stored document graph first, optionally falls back to the first few
  PDF pages, and only writes Crossref-backed metadata. It does not invent
  document labels or write LLM-only title facts.
  """

  alias RDF.Description
  alias Sheaf.NS.{BIBO, DOC, FABIO}
  alias RDF.NS.RDFS

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
  Resolves one candidate by extracting metadata from bounded document text.

  If no DOI/ISBN is found, this returns successfully with `wrote?: false`.
  Set `pdf_fallback: true` to try the first few PDF pages after text extraction.
  The only RDF write path is `Sheaf.Crossref.import_metadata/2`.
  """
  @spec resolve(candidate(), keyword()) ::
          {:ok, resolve_result()} | {:error, term()}
  def resolve(%{path: path} = candidate, opts \\ []) when is_binary(path) do
    with true <- File.exists?(path) || {:error, {:missing_blob, path}},
         {:ok, metadata} <- extract_metadata(candidate, opts) do
      resolve_metadata(candidate, metadata, opts)
    end
  end

  @doc """
  Extracts local metadata for a candidate without calling Crossref or writing RDF.
  """
  @spec extract_candidate_metadata(candidate(), keyword()) ::
          {:ok, Sheaf.PaperMetadata.t()} | {:error, term()}
  def extract_candidate_metadata(%{path: path} = candidate, opts \\ [])
      when is_binary(path) do
    with true <- File.exists?(path) || {:error, {:missing_blob, path}} do
      extract_metadata(candidate, opts)
    end
  end

  @doc """
  Resolves already-extracted metadata through Crossref and RDF import.
  """
  @spec resolve_candidate_metadata(
          candidate(),
          Sheaf.PaperMetadata.t(),
          keyword()
        ) ::
          {:ok, resolve_result()} | {:error, term()}
  def resolve_candidate_metadata(candidate, metadata, opts \\ []) do
    resolve_metadata(candidate, metadata, opts)
  end

  @doc """
  Looks up Crossref data for extracted DOI or ISBN metadata.
  """
  @spec lookup_identifier(Sheaf.PaperMetadata.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def lookup_identifier(metadata, opts \\ []) do
    cond do
      metadata.doi ->
        with {:ok, work} <-
               Sheaf.Crossref.work(metadata.doi, crossref_lookup_opts(opts)) do
          {:ok, %{source: "doi", identifier: metadata.doi, work: work}}
        end

      metadata.isbn ->
        with {:ok, works} <-
               Sheaf.Crossref.works_by_isbn(
                 metadata.isbn,
                 crossref_lookup_opts(opts)
               ) do
          {:ok, %{source: "isbn", identifier: metadata.isbn, works: works}}
        end

      true ->
        {:ok,
         %{source: "none", identifier: nil, reason: "no DOI or ISBN found"}}
    end
  end

  @doc """
  Matches extracted metadata against a Crossref lookup result.
  """
  @spec match_lookup(Sheaf.PaperMetadata.t(), map()) :: {:ok, map()}
  def match_lookup(metadata, %{source: "doi", work: work}) do
    {:ok, match_crossref(metadata, work, :doi) |> Map.put(:work, work)}
  end

  def match_lookup(metadata, %{source: "isbn", works: works}) do
    {work, match} = best_isbn_match(metadata, works)
    {:ok, Map.put(match, :work, work)}
  end

  def match_lookup(_metadata, lookup) do
    {:ok,
     %{
       accept?: false,
       score: 0.0,
       source:
         Map.get(lookup, :source) || Map.get(lookup, "source") || "none",
       reason:
         Map.get(lookup, :reason) || Map.get(lookup, "reason") ||
           "no lookup result"
     }}
  end

  @doc """
  Imports Crossref metadata for an accepted match.
  """
  @spec import_match(candidate(), Sheaf.PaperMetadata.t(), map(), keyword()) ::
          {:ok, resolve_result()} | {:error, term()}
  def import_match(candidate, metadata, match, opts \\ []) do
    cond do
      not Map.get(match, :accept?) ->
        {:ok, no_import(candidate, metadata, clean_match(match))}

      doi = Map.get(match, :doi) || get_in(match, [:work, "DOI"]) ->
        import_crossref(candidate, metadata, doi, clean_match(match), opts)

      true ->
        {:ok,
         no_import(
           candidate,
           metadata,
           match
           |> clean_match()
           |> Map.put(:reason, "accepted match has no DOI")
         )}
    end
  end

  @doc """
  Resolves one queued task input map.
  """
  @spec resolve_task(map(), keyword()) ::
          {:ok, resolve_result()} | {:error, term()}
  def resolve_task(input, opts \\ []) when is_map(input) do
    input
    |> candidate_from_input()
    |> resolve(opts)
  end

  @doc false
  def task_candidate(input) when is_map(input),
    do: candidate_from_input(input)

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
    metadata_graph = Keyword.get(opts, :metadata_graph, @metadata_graph)

    with {:ok, metadata} <- Sheaf.fetch_graph(metadata_graph),
         {:ok, source_rows} <-
           Sheaf.Repo.match_rows({nil, DOC.sourceFile(), nil, nil}) do
      docs =
        source_rows
        |> Enum.map(fn {_graph, doc, _predicate, _file} -> doc end)
        |> Enum.uniq()

      with {:ok, type_rows} <-
             Sheaf.Repo.match_rows({docs, RDF.type(), document_types(), nil}),
           {:ok, label_rows} <-
             Sheaf.Repo.match_rows({docs, RDFS.label(), nil, nil}) do
        documents =
          type_rows
          |> Enum.map(fn {_graph, doc, _predicate, _type} -> doc end)
          |> MapSet.new()

        labels = first_objects(label_rows)

        rows =
          source_rows
          |> Enum.flat_map(fn {_graph, doc, _predicate, file} ->
            if MapSet.member?(documents, doc) do
              [
                %{
                  "doc" => doc,
                  "file" => file,
                  "label" => Map.get(labels, doc),
                  "expression" =>
                    first_object(metadata, doc, FABIO.isRepresentationOf())
                }
              ]
            else
              []
            end
          end)
          |> Enum.sort_by(&(Map.fetch!(&1, "doc") |> to_string()))

        {:ok, %{results: rows}}
      end
    end
  end

  defp first_objects(rows) do
    Enum.reduce(rows, %{}, fn {_graph, subject, _predicate, object}, index ->
      Map.put_new(index, subject, object)
    end)
  end

  defp document_types do
    [
      RDF.iri(DOC.Document),
      RDF.iri(DOC.Paper),
      RDF.iri(DOC.Thesis),
      RDF.iri(DOC.Transcript),
      RDF.iri(DOC.Spreadsheet),
      RDF.iri(DOC.Interview)
    ]
  end

  defp files_graph(opts) do
    case Keyword.fetch(opts, :files_graph) do
      {:ok, graph} -> {:ok, graph}
      :error -> Sheaf.Files.list_graph()
    end
  end

  defp candidate_from_row(row, files, opts) do
    with {:ok, document} <- Map.fetch(row, "doc"),
         {:ok, file} <- Map.fetch(row, "file"),
         %Description{} = file_description <-
           Enum.find(files, &(&1.subject == file)),
         {:ok, path} <- Sheaf.Files.local_path(file_description, opts) do
      [
        %{
          document: document,
          file: file,
          path: path,
          label: value(Map.get(row, "label")),
          metadata_expression: Map.get(row, "expression"),
          original_filename:
            first_value(file_description, DOC.originalFilename()),
          mime_type: first_value(file_description, DOC.mimeType()),
          byte_size: first_value(file_description, DOC.byteSize()),
          sha256: first_value(file_description, DOC.sha256()),
          generated_at:
            first_value(file_description, Sheaf.NS.PROV.generatedAtTime())
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
    with {:ok, lookup} <- lookup_identifier(metadata, opts),
         {:ok, match} <- match_lookup(metadata, lookup) do
      import_match(candidate, metadata, match, opts)
    end
  end

  defp import_crossref(candidate, metadata, doi, match, opts) do
    crossref_opts =
      opts
      |> Keyword.take([:base_url, :req_options])
      |> Keyword.put(
        :metadata_graph,
        Keyword.get(opts, :metadata_graph, @metadata_graph)
      )
      |> Keyword.put(:paper, candidate.document)
      |> put_if_present(:page_count, document_page_count(candidate.document))

    with {:ok, crossref} <- Sheaf.Crossref.import_metadata(doi, crossref_opts) do
      {:ok,
       %{
         candidate: candidate,
         metadata: metadata,
         crossref: crossref,
         wrote?: true,
         match: match
       }}
    end
  end

  defp no_import(candidate, metadata, match) do
    %{candidate: candidate, metadata: metadata, wrote?: false, match: match}
  end

  defp clean_match(match), do: Map.delete(match, :work)

  defp crossref_lookup_opts(opts),
    do: Keyword.take(opts, [:base_url, :req_options])

  defp document_page_count(document) do
    with {:ok, graph} <- Sheaf.fetch_graph(document) do
      document_page_count(graph, RDF.iri(document))
    else
      _error -> nil
    end
  end

  defp document_page_count(graph, document) do
    description =
      RDF.Graph.description(graph, document) || Description.new(document)

    case description
         |> Description.first(BIBO.numPages())
         |> integer_value() do
      count when is_integer(count) ->
        count

      _other ->
        source_page = DOC.sourcePage()

        graph
        |> RDF.Graph.triples()
        |> Enum.flat_map(fn
          {_subject, ^source_page, object} ->
            case integer_value(object) do
              page when is_integer(page) -> [page]
              _other -> []
            end

          _triple ->
            []
        end)
        |> page_count()
    end
  end

  defp extract_metadata(candidate, opts) do
    extract_metadata =
      Keyword.get(opts, :extract_metadata, &default_extract_metadata/2)

    extract_metadata.(candidate, opts)
  end

  defp default_extract_metadata(candidate, opts) do
    metadata_opts = llm_opts(opts)

    with {:ok, metadata} <-
           Sheaf.PaperMetadata.extract_document(
             candidate.document,
             metadata_opts
           ) do
      if missing_identifiers?(metadata) and
           Keyword.get(opts, :pdf_fallback, false) do
        candidate.path
        |> Sheaf.PaperMetadata.extract_pdf_pages(
          Keyword.put(metadata_opts, :pages, Keyword.get(opts, :pdf_pages, 3))
        )
      else
        {:ok, metadata}
      end
    end
  end

  defp missing_identifiers?(metadata),
    do: is_nil(metadata.doi) and is_nil(metadata.isbn)

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
      :generate_object,
      :chars,
      :first_pages,
      :last_pages,
      :first_chunks,
      :last_chunks
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

  defp input_value(input, key),
    do: Map.get(input, key) || Map.get(input, to_string(key))

  defp nullable_iri(nil), do: nil
  defp nullable_iri(value), do: RDF.iri(value)

  defp best_isbn_match(metadata, works) do
    works
    |> Enum.map(&{&1, match_crossref(metadata, &1, :isbn)})
    |> Enum.sort_by(fn {_work, match} -> match.score end, :desc)
    |> List.first(
      {%{},
       %{
         accept?: false,
         score: 0.0,
         source: "isbn",
         reason: "no Crossref ISBN candidates"
       }}
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

  defp integer_value(%RDF.Literal{} = literal), do: RDF.Literal.value(literal)
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp page_count([]), do: nil

  defp page_count(pages) do
    Enum.max(pages) - Enum.min(pages) + 1
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp first_object(nil, _subject, _predicate), do: nil

  defp first_object(graph, subject, predicate) do
    graph
    |> RDF.Graph.triples()
    |> Enum.find_value(fn
      {^subject, ^predicate, object} -> object
      _triple -> nil
    end)
  end

  defp value(nil), do: nil
  defp value(term), do: RDF.Term.value(term)
end
