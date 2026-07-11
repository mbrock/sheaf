defmodule Sheaf.CorpusSearch do
  @moduledoc """
  Public corpus search helpers for lightweight HTTP and script access.
  """

  use RDF

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.{Description, Graph, IRI}
  alias RDF.NS.RDFS
  alias Sheaf.Assistant.ToolResults
  alias Sheaf.Id
  alias Sheaf.NS.{DCTERMS, FABIO, FRBR}

  @search_limit 10
  @default_kinds ~w(paragraph sourceHtml)
  @turtle_prefixes [
    dcterms: "http://purl.org/dc/terms/",
    bibo: "http://purl.org/ontology/bibo/",
    fabio: "http://purl.org/spar/fabio/",
    prism: "http://prismstandard.org/namespaces/basic/2.1/",
    owl: "http://www.w3.org/2002/07/owl#",
    foaf: "http://xmlns.com/foaf/0.1/",
    c4o: "http://purl.org/spar/c4o/",
    doco: "http://purl.org/spar/doco/"
  ]

  @doc """
  Runs the same exact-plus-semantic text search used by the assistant corpus tool.
  """
  @spec search(String.t(), keyword()) ::
          {:ok, ToolResults.SearchResults.t()} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)
    document_kind = Keyword.get(opts, :document_kind)

    Tracer.with_span "Sheaf.CorpusSearch.search", %{
      query: query,
      limit: @search_limit,
      document_kind: document_kind || "all"
    } do
      if query == "" do
        {:ok, %ToolResults.SearchResults{}}
      else
        search_fun =
          Keyword.get(opts, :search, &Sheaf.Embedding.Index.search/2)

        exact_search_fun =
          Keyword.get(
            opts,
            :exact_search,
            &Sheaf.Embedding.Index.exact_search/2
          )

        search_opts =
          [
            limit: @search_limit,
            kinds: Keyword.get(opts, :kinds, @default_kinds)
          ]
          |> maybe_put(:document_kind, document_kind)

        with {:ok, exact_results} <- exact_search_fun.(query, search_opts),
             {:ok, approximate_results} <-
               search_fun.(query, Keyword.put(search_opts, :exact_limit, 0)) do
          {:ok,
           %ToolResults.SearchResults{
             exact_results: Enum.map(exact_results, &search_hit/1),
             approximate_results: Enum.map(approximate_results, &search_hit/1)
           }}
        end
      end
    end
  end

  @doc """
  Renders search results as concise Markdown intended for curl and notes.
  """
  @spec markdown(ToolResults.SearchResults.t(), keyword()) :: String.t()
  def markdown(%ToolResults.SearchResults{} = results, opts \\ []) do
    query = opts |> Keyword.get(:query, "") |> to_string()
    hits = merged_hits(results)

    if hits == [] do
      "No results found for #{inspect(query)}.\n"
    else
      [
        "# Corpus results for #{query}",
        hits
        |> Enum.with_index(1)
        |> Enum.map(fn {hit, index} -> markdown_hit(hit, index) end)
        |> Enum.join("\n\n")
      ]
      |> Enum.join("\n\n")
      |> Kernel.<>("\n")
    end
  end

  @doc """
  Renders search results as Turtle.
  """
  @spec turtle(ToolResults.SearchResults.t(), keyword()) :: String.t()
  def turtle(%ToolResults.SearchResults{} = results, opts \\ []) do
    prefixes = Keyword.get_lazy(opts, :prefixes, &turtle_prefixes/0)

    hits = merged_hits(results)

    hits
    |> response_graph()
    |> RDF.Turtle.write_string!(prefixes: prefixes)
  end

  defp merged_hits(%ToolResults.SearchResults{} = results) do
    results.exact_results ++
      Enum.reject(results.approximate_results, fn approximate ->
        Enum.any?(
          results.exact_results,
          &(&1.block_id == approximate.block_id)
        )
      end)
  end

  defp markdown_hit(%ToolResults.SearchHit{} = hit, index) do
    [
      "#{index}. **#{hit.document_title || "Untitled"}**#{byline(hit)}#{page(hit)}",
      breadcrumb_links(hit.breadcrumbs),
      normalize_text(hit.text)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp response_graph(hits) do
    paragraphs =
      hits
      |> Enum.map(&quote_part/1)
      |> Enum.reject(&is_nil/1)

    RDF.Graph.build parts: paragraphs do
      Enum.map(parts, fn {expression, paragraph, content} ->
        [
          expression |> Sheaf.NS.DCTERMS.hasPart(paragraph),
          paragraph
          |> a(Sheaf.NS.DOCO.Paragraph)
          |> Sheaf.NS.C4O.hasContent(content)
        ]
      end)
    end
    |> RDF.Graph.add(selected_metadata_graph(paragraphs))
  end

  defp quote_part(%ToolResults.SearchHit{} = hit) do
    with document_id when not is_nil(document_id) <- hit.document_id,
         {:ok, metadata} <- metadata_graph(),
         expression when not is_nil(expression) <-
           represented_expression(metadata, Id.iri(document_id)),
         content when content != "" <- quote_content(hit) do
      {expression, RDF.bnode(), content}
    else
      _other -> nil
    end
  end

  defp selected_metadata_graph(paragraphs) do
    case metadata_graph() do
      {:error, _reason} ->
        Graph.new()

      {:ok, metadata} ->
        paragraphs
        |> Enum.map(fn {expression, _paragraph, _content} -> expression end)
        |> metadata_closure(metadata, 3)
        |> then(fn resources ->
          people = person_blank_nodes(metadata, resources)

          metadata
          |> descriptions_graph(resources, people)
          |> RDF.Graph.add(person_same_as_graph(people))
        end)
    end
  end

  defp metadata_closure(resources, metadata, depth) do
    do_metadata_closure(MapSet.new(resources), metadata, depth)
    |> MapSet.to_list()
  end

  defp do_metadata_closure(resources, _metadata, 0), do: resources

  defp do_metadata_closure(resources, metadata, depth) do
    next =
      resources
      |> Enum.flat_map(fn resource ->
        metadata
        |> RDF.Data.description(resource)
        |> linked_metadata_resources()
      end)
      |> MapSet.new()
      |> MapSet.union(resources)

    if MapSet.equal?(next, resources) do
      resources
    else
      do_metadata_closure(next, metadata, depth - 1)
    end
  end

  defp linked_metadata_resources(%Description{} = description) do
    [
      DCTERMS.creator(),
      DCTERMS.isPartOf(),
      DCTERMS.publisher()
    ]
    |> Enum.flat_map(&objects(description, &1))
  end

  defp descriptions_graph(graph, resources, replacements) do
    resources
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(Graph.new(), fn resource, acc ->
      RDF.Graph.add(acc, description_graph(graph, resource, replacements))
    end)
  end

  defp description_graph(graph, resource, replacements) do
    statements =
      graph
      |> RDF.Data.description(resource)
      |> Description.statements()
      |> Enum.reject(&omitted_metadata_statement?/1)
      |> Enum.map(&replace_statement_resources(&1, replacements))

    if type_only_description?(statements) do
      Graph.new()
    else
      Graph.new(statements)
    end
  end

  defp omitted_metadata_statement?({_subject, predicate, _object}) do
    predicate in [
      RDFS.label(),
      FRBR.realizationOf(),
      Sheaf.NS.FOAF.familyName(),
      Sheaf.NS.FOAF.givenName()
    ]
  end

  defp type_only_description?([]), do: false

  defp type_only_description?(statements) do
    Enum.all?(statements, fn {_subject, predicate, _object} ->
      predicate == RDF.type()
    end)
  end

  defp represented_expression(%Graph{} = metadata, document_iri) do
    metadata
    |> RDF.Data.description(document_iri)
    |> Description.first(FABIO.isRepresentationOf())
  end

  defp person_blank_nodes(metadata, resources) do
    resources
    |> Enum.filter(&person?(metadata, &1))
    |> Map.new(fn person -> {person, RDF.bnode()} end)
  end

  defp person_same_as_graph(people) do
    RDF.Graph.build people: people do
      Enum.map(people, fn {person, blank_node} ->
        blank_node |> RDF.NS.OWL.sameAs(person)
      end)
    end
  end

  defp person?(metadata, resource) do
    metadata
    |> RDF.Data.description(resource)
    |> Description.include?({RDF.type(), RDF.iri(Sheaf.NS.FOAF.Person)})
  end

  defp replace_statement_resources({subject, predicate, object}, replacements) do
    {
      Map.get(replacements, subject, subject),
      predicate,
      Map.get(replacements, object, object)
    }
  end

  defp quote_content(%ToolResults.SearchHit{text: text}) do
    text
    |> normalize_text()
  end

  defp objects(%Description{} = description, predicate) do
    description
    |> Description.get(predicate)
    |> List.wrap()
    |> Enum.filter(&match?(%IRI{}, &1))
  end

  defp fetch_graph(iri) do
    case Sheaf.fetch_graph(iri) do
      {:ok, %Graph{} = graph} -> graph
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp metadata_graph do
    case fetch_graph(Sheaf.Repo.metadata_graph()) do
      %Graph{} = graph -> {:ok, graph}
      nil -> {:error, :metadata_graph_not_found}
    end
  end

  defp byline(%{document_authors: authors}) when is_list(authors) do
    authors = authors |> Enum.reject(&blank?/1) |> Enum.join(", ")
    if authors == "", do: "", else: " - #{authors}"
  end

  defp byline(_hit), do: ""

  defp page(%{source_page: page}) when page not in [nil, ""],
    do: " (p. #{page})"

  defp page(_hit), do: ""

  defp search_hit(result) do
    %ToolResults.SearchHit{
      document_id: result.doc_iri && Id.id_from_iri(result.doc_iri),
      document_title: result.doc_title,
      document_authors: Map.get(result, :doc_authors, []),
      document_status: Map.get(result, :doc_status),
      block_id: Id.id_from_iri(result.iri),
      kind: search_hit_kind(result.kind),
      text: search_hit_text(result),
      source_page: result.source_page,
      breadcrumbs: Map.get(result, :breadcrumbs, []),
      match: result.match,
      score: result.score
    }
  end

  defp search_hit_kind("paragraph"), do: :paragraph
  defp search_hit_kind("sourceHtml"), do: :extracted
  defp search_hit_kind("row"), do: :row
  defp search_hit_kind(kind) when is_binary(kind), do: String.to_atom(kind)
  defp search_hit_kind(kind), do: kind

  defp search_hit_text(%{kind: "sourceHtml", text: text}),
    do: plain_text(text)

  defp search_hit_text(%{text: text}), do: normalize_text(text)

  defp plain_text(html) do
    html
    |> to_string()
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> normalize_text()
  end

  defp normalize_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp turtle_prefixes do
    [{"", Id.base_iri()} | @turtle_prefixes]
  end

  defp breadcrumb_links(nil), do: ""
  defp breadcrumb_links([]), do: ""

  defp breadcrumb_links(breadcrumbs) when is_list(breadcrumbs) do
    breadcrumbs
    |> Enum.map(fn breadcrumb ->
      "[#{escape_markdown_link_text(breadcrumb.title)}](#{read_url(breadcrumb.id)})"
    end)
    |> Enum.join(" > ")
  end

  defp read_url(id) do
    base = URI.parse(Id.base_iri())

    base
    |> Map.put(:path, "/read/#{URI.encode(id, &URI.char_unreserved?/1)}")
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp escape_markdown_link_text(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false
end
