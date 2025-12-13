defmodule Sheaf.Crossref do
  @moduledoc """
  Small Crossref client for DOI and ISBN metadata.
  """

  alias RDF.Description
  alias Sheaf.NS.{BIBO, DCTERMS, DOI, FABIO, PRISM}
  require RDF.Graph

  @default_base_url "https://api.crossref.org"
  @default_metadata_graph "https://less.rest/sheaf/metadata"
  @json_media_type "application/json"
  @turtle_media_type "text/turtle"

  @type response :: {:ok, term()} | {:error, term()}

  @doc """
  Fetches Crossref REST metadata for a DOI.
  """
  @spec work(String.t(), keyword()) :: response()
  def work(doi, opts \\ []) when is_binary(doi) do
    with {:ok, %{"message" => work}} <-
           get("/works/#{encoded_doi(doi)}", @json_media_type, opts) do
      {:ok, work}
    end
  end

  @doc """
  Searches Crossref works by ISBN.
  """
  @spec works_by_isbn(String.t(), keyword()) :: response()
  def works_by_isbn(isbn, opts \\ []) when is_binary(isbn) do
    rows = Keyword.get(opts, :rows, 5)

    with {:ok, %{"message" => %{"items" => items}}} <-
           get("/works", @json_media_type, opts,
             filter: "isbn:#{normalized_isbn(isbn)}",
             rows: rows
           ) do
      {:ok, items}
    end
  end

  @doc """
  Fetches Crossref's Turtle representation for a DOI.

  DOI content negotiation through `doi.org` redirects here for Crossref DOIs.
  """
  @spec turtle(String.t(), keyword()) :: response()
  def turtle(doi, opts \\ []) when is_binary(doi) do
    get("/v1/works/#{encoded_doi(doi)}/transform", @turtle_media_type, opts)
  end

  @doc """
  Fetches and parses Crossref Turtle metadata for a DOI.
  """
  @spec graph(String.t(), keyword()) :: response()
  def graph(doi, opts \\ []) when is_binary(doi) do
    with {:ok, turtle} <- turtle(doi, opts) do
      RDF.read_string(turtle, media_type: @turtle_media_type)
    end
  end

  @doc """
  Fetches Crossref Turtle metadata for a DOI and merges it into the metadata graph.

  Options:

    * `:metadata_graph` - named graph to update, defaulting to the Sheaf metadata graph.
    * `:paper` - a generated Sheaf paper IRI to link to the expression with
      `fabio:isRepresentationOf`.
    * `:expression` - an existing local expression IRI. When omitted with
      `:paper`, an existing expression linked from the paper is reused; otherwise
      one is minted.
    * `:work` - an optional local work IRI. When omitted with `:paper`, an
      existing work linked from the paper or expression is reused; otherwise one
      is minted.
    * `:work_type` - an optional type, such as `fabio:ResearchPaper`, for `:work`.
      When a work is present and no type is provided, `fabio:ScholarlyWork` is used.
    * `:page_count` - optional integer page count to assert on the local
      expression with `bibo:numPages`.
    * `:same_as` - additional local IRIs to link to the DOI resource with
      `owl:sameAs`.
  """
  @spec import_metadata(String.t(), keyword()) :: response()
  def import_metadata(doi, opts \\ []) when is_binary(doi) do
    graph_name = Keyword.get(opts, :metadata_graph, @default_metadata_graph)

    with {:ok, crossref_work} <- work(doi, opts),
         {:ok, crossref_graph} <- graph(doi, opts),
         {:ok, metadata_graph} <- Sheaf.fetch_graph(graph_name),
         opts =
           metadata_options(metadata_graph, doi, opts)
           |> Keyword.put(:crossref_work, crossref_work),
         merged_graph = merge_metadata_graph(metadata_graph, crossref_graph, doi, opts),
         :ok <- Sheaf.put_graph(graph_name, merged_graph) do
      {:ok,
       %{
         graph: graph_name,
         doi: normalized_doi(doi),
         doi_iri: doi_iri(doi),
         expression: opts[:expression],
         work: opts[:work],
         crossref_statements: statement_count(crossref_graph),
         statements: statement_count(merged_graph)
       }}
    end
  end

  @doc false
  def merge_metadata_graph(metadata_graph, crossref_graph, doi, opts \\ []) do
    opts = metadata_options(metadata_graph, doi, opts)
    expression = opts[:expression]
    crossref_work = Keyword.get(opts, :crossref_work, %{})

    metadata_graph
    |> RDF.Graph.add(crossref_graph)
    |> RDF.Graph.add(metadata_links(expression, doi, opts))
    |> RDF.Graph.add(local_metadata(expression, crossref_graph, crossref_work, doi, opts))
  end

  defp get(path, accept, opts, params \\ []) do
    client(opts)
    |> Req.get(url: path, headers: [accept: accept], params: params)
    |> handle_response()
  end

  defp client(opts) do
    req_options = Keyword.get(opts, :req_options, [])

    [
      base_url: Keyword.get(opts, :base_url, @default_base_url),
      http_errors: :return
    ]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, %{status: status, body: body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp metadata_links(expression, doi, opts) do
    doi_iri = doi_iri(doi)
    paper = opts[:paper] && RDF.iri(opts[:paper])
    work = opts[:work] && RDF.iri(opts[:work])
    work_type = work_type(opts)
    title = crossref_title(opts)
    same_as = same_as_resources([expression | List.wrap(opts[:same_as])], doi_iri)

    RDF.Graph.build expression: expression,
                    doi_iri: doi_iri,
                    paper: paper,
                    work: work,
                    work_type: work_type,
                    title: title,
                    same_as: same_as do
      if paper, do: paper |> FABIO.isRepresentationOf(expression)

      expression |> Sheaf.NS.FRBR.realizationOf(work)

      if paper && work do
        paper |> FABIO.isPortrayalOf(work)
      end

      if work do
        work
        |> a(work_type)
        |> DCTERMS.title(title)
        |> RDFS.label(title)
      end

      Enum.map(same_as, &OWL.sameAs(&1, doi_iri))
    end
  end

  defp metadata_options(metadata_graph, doi, opts) do
    expression = expression_resource(metadata_graph, opts, doi)
    opts = Keyword.put(opts, :expression, expression)

    case work_resource(metadata_graph, opts, expression) do
      nil -> opts
      work -> Keyword.put(opts, :work, work)
    end
  end

  defp local_metadata(expression, crossref_graph, crossref_work, doi, opts) do
    doi_iri = doi_iri(doi)
    title = title(crossref_work, crossref_graph, doi_iri)
    doi_value = crossref_work["DOI"] || normalized_doi(doi)
    expression_type = expression_type(crossref_work)
    publication_year = publication_year(crossref_work)
    volume = volume(crossref_work, crossref_graph, doi_iri)
    issue = issue(crossref_work)
    page_range = page_range(crossref_work, crossref_graph, doi_iri)
    page_count = Keyword.get(opts, :page_count)
    creators = objects(crossref_graph, doi_iri, DCTERMS.creator())
    parts = objects(crossref_graph, doi_iri, DCTERMS.isPartOf())
    publishers = publisher(crossref_work, crossref_graph, doi_iri)
    work = opts[:work] && RDF.iri(opts[:work])

    RDF.Graph.build expression: expression,
                    expression_type: expression_type,
                    title: title,
                    doi_value: doi_value,
                    doi_iri: doi_iri,
                    publication_year: publication_year,
                    volume: volume,
                    issue: issue,
                    page_range: page_range,
                    page_count: page_count,
                    creators: creators,
                    parts: parts,
                    publishers: publishers,
                    work: work do
      expression
      |> a(expression_type)
      |> DCTERMS.title(title)
      |> RDFS.label(title)
      |> FABIO.hasDOI(doi_value)
      |> DCTERMS.identifier(doi_value)
      |> FABIO.hasPublicationYear(publication_year)
      |> FABIO.hasVolumeIdentifier(volume)
      |> FABIO.hasIssueIdentifier(issue)
      |> FABIO.hasPageRange(page_range)
      |> BIBO.numPages(page_count)
      |> DCTERMS.creator(creators)
      |> DCTERMS.isPartOf(parts)
      |> DCTERMS.publisher(publishers)
      |> OWL.sameAs(if(expression != doi_iri, do: doi_iri))

      if work && title do
        work
        |> DCTERMS.title(title)
        |> RDFS.label(title)
      end
    end
  end

  defp expression_resource(metadata_graph, opts, doi) do
    cond do
      opts[:expression] ->
        RDF.iri(opts[:expression])

      opts[:paper] ->
        existing_expression(metadata_graph, opts[:paper]) || Sheaf.mint()

      true ->
        doi_iri(doi)
    end
  end

  defp work_resource(metadata_graph, opts, expression) do
    cond do
      opts[:work] ->
        RDF.iri(opts[:work])

      true ->
        existing_work(metadata_graph, opts[:paper], expression) || (opts[:paper] && Sheaf.mint())
    end
  end

  defp existing_expression(metadata_graph, paper) do
    paper = RDF.iri(paper)

    metadata_graph
    |> RDF.Data.description(paper)
    |> Description.first(FABIO.isRepresentationOf())
  end

  defp existing_work(metadata_graph, paper, expression) do
    existing_paper_work =
      if paper do
        metadata_graph
        |> RDF.Data.description(RDF.iri(paper))
        |> Description.first(FABIO.isPortrayalOf())
      end

    existing_paper_work ||
      existing_expression_work(metadata_graph, expression)
  end

  defp existing_expression_work(_metadata_graph, nil), do: nil

  defp existing_expression_work(metadata_graph, expression) do
    metadata_graph
    |> RDF.Data.description(expression)
    |> Description.first(Sheaf.NS.FRBR.realizationOf())
  end

  defp work_type(opts) do
    cond do
      opts[:work_type] -> RDF.iri(opts[:work_type])
      opts[:work] -> RDF.iri(FABIO.ScholarlyWork)
      true -> nil
    end
  end

  defp crossref_title(opts),
    do: title(Keyword.get(opts, :crossref_work, %{}), RDF.Graph.new(), nil)

  defp title(crossref_work, crossref_graph, doi_iri) do
    first_string(crossref_work["title"]) || first_value(crossref_graph, doi_iri, DCTERMS.title())
  end

  defp publication_year(crossref_work) do
    Enum.find_value(["published-print", "published-online", "published", "issued"], fn key ->
      case crossref_work[key] do
        %{"date-parts" => [[year | _] | _]} when is_integer(year) -> Integer.to_string(year)
        _other -> nil
      end
    end)
  end

  defp volume(crossref_work, crossref_graph, doi_iri) do
    string(crossref_work["volume"]) || first_value(crossref_graph, doi_iri, PRISM.volume())
  end

  defp issue(crossref_work), do: string(crossref_work["issue"])

  defp page_range(crossref_work, crossref_graph, doi_iri) do
    string(crossref_work["page"]) || page_range_from_graph(crossref_graph, doi_iri)
  end

  defp page_range_from_graph(crossref_graph, doi_iri) do
    case {
      first_value(crossref_graph, doi_iri, BIBO.pageStart()),
      first_value(crossref_graph, doi_iri, BIBO.pageEnd())
    } do
      {nil, nil} -> nil
      {start_page, nil} -> start_page
      {nil, end_page} -> end_page
      {start_page, end_page} -> "#{start_page}-#{end_page}"
    end
  end

  defp publisher(crossref_work, crossref_graph, doi_iri) do
    case string(crossref_work["publisher"]) do
      nil -> objects(crossref_graph, doi_iri, DCTERMS.publisher())
      publisher -> [publisher]
    end
  end

  defp expression_type(%{"type" => "journal-article"}), do: RDF.iri(FABIO.JournalArticle)
  defp expression_type(%{"type" => "book-chapter"}), do: RDF.iri(FABIO.BookChapter)
  defp expression_type(%{"type" => "book"}), do: RDF.iri(FABIO.Book)
  defp expression_type(_crossref_work), do: nil

  defp objects(_graph, nil, _predicate), do: []

  defp objects(graph, subject, predicate) do
    graph
    |> RDF.Data.description(subject)
    |> Description.get(predicate, [])
    |> Enum.uniq()
  end

  defp first_value(graph, subject, predicate) do
    graph
    |> objects(subject, predicate)
    |> List.first()
    |> value()
  end

  defp first_string([value | _]), do: string(value)
  defp first_string(value), do: string(value)

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp value(nil), do: nil
  defp value(term), do: term |> RDF.Term.value() |> to_string()

  defp same_as_resources(resources, doi_iri) do
    resources
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&RDF.iri/1)
    |> Enum.reject(&(&1 == doi_iri))
    |> Enum.uniq()
  end

  defp doi_iri(doi), do: DOI |> RDF.IRI.coerce_base() |> RDF.IRI.append(normalized_doi(doi))

  defp normalized_doi(doi), do: String.trim(doi)

  defp encoded_doi(doi), do: doi |> normalized_doi() |> URI.encode_www_form()

  defp normalized_isbn(isbn) do
    isbn
    |> String.upcase()
    |> String.replace(~r/[^0-9X]/, "")
  end

  defp statement_count(graph), do: RDF.Data.statement_count(graph)
end
