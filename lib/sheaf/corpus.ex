defmodule Sheaf.Corpus do
  @moduledoc """
  Corpus-level helpers built as thin wrappers over SPARQL and `Sheaf.fetch_graph/1`.

  Stateless: every call talks to Fuseki directly. The point of this module is
  not to cache anything — Fuseki is fast — but to give the rest of the
  application ergonomic, high-level questions to ask about the corpus:
  "what's in it?", "which document contains this block?", "where does this
  word appear?"
  """

  alias RDF.Graph
  alias Sheaf.{Document, Documents, Id}

  @default_search_limit 20

  @doc """
  Full document list (delegates to `Sheaf.Documents.list/0`).
  """
  def documents, do: Documents.list(include_excluded: false)

  @doc """
  Fetches a single document's graph by id. Raises if fetch fails.
  """
  def graph(doc_id) when is_binary(doc_id) do
    Sheaf.fetch_graph(Id.iri(doc_id))
  end

  @doc """
  Returns the containing document id for a block id, or `nil` if unknown.

  One SPARQL query against Fuseki. This is how `#BLOCKID` links resolve.
  """
  @spec find_document(String.t()) :: String.t() | nil
  def find_document(block_id) when is_binary(block_id) do
    iri = Id.iri(block_id) |> to_string()

    sparql = """
    SELECT ?g WHERE {
      GRAPH ?g { <#{iri}> ?p ?o }
    } LIMIT 1
    """

    case Sheaf.select("block document lookup select", sparql) do
      {:ok, %{results: [row | _]}} ->
        row
        |> Map.fetch!("g")
        |> RDF.Term.value()
        |> to_string()
        |> Id.id_from_iri()

      _ ->
        nil
    end
  end

  @doc """
  Case-insensitive substring search across paragraph and extracted-block text.
  Spreadsheet row text is searched only when `:include_spreadsheets` is true.
  Multi-word queries are treated as keyword searches: exact phrase matches rank
  first, then blocks matching the most query terms.

  Options:

    * `:document_id` — scope search to one document.
    * `:include_spreadsheets` — include `sheaf:Row` blocks, default `false`.
    * `:limit` — maximum hits, defaulting to #{@default_search_limit}.

  Returns `{:ok, [hit]}` where each hit is `%{document_id, document_title,
  block_id, kind, text, source_page}`. Row hits also include coding metadata.
  """
  @spec search_text(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_text(query, opts \\ []) when is_binary(query) do
    needle = String.trim(query)

    if needle == "" do
      {:ok, []}
    else
      limit = Keyword.get(opts, :limit, @default_search_limit)
      scope = Keyword.get(opts, :document_id)
      include_spreadsheets? = Keyword.get(opts, :include_spreadsheets, false)
      select = Keyword.get(opts, :select, &Sheaf.select/2)

      sparql = search_sparql(needle, scope, limit, include_spreadsheets?)

      case select.("corpus text search select", sparql) do
        {:ok, result} -> {:ok, Enum.map(result.results, &hit_from_row/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Path from the document root to `block_iri` within an already-loaded graph.

  Returns a list of `%{id, type, title}` entries including the block itself, or
  `[]` if the block is not reachable from the root.
  """
  @spec ancestry(Graph.t(), RDF.IRI.t(), RDF.IRI.t()) :: [map()]
  def ancestry(%Graph{} = graph, %RDF.IRI{} = root, %RDF.IRI{} = target) do
    case walk_to_target(graph, root, target, []) do
      nil -> []
      path -> Enum.map(path, &ancestry_entry(graph, &1))
    end
  end

  defp walk_to_target(_graph, iri, target, trail) when iri == target do
    Enum.reverse([iri | trail])
  end

  defp walk_to_target(graph, iri, target, trail) do
    graph
    |> Document.children(iri)
    |> Enum.find_value(fn child -> walk_to_target(graph, child, target, [iri | trail]) end)
  end

  defp ancestry_entry(graph, iri) do
    type = Document.block_type(graph, iri) || :document

    %{
      id: Id.id_from_iri(iri),
      type: type,
      title: ancestry_title(graph, iri, type)
    }
  end

  defp ancestry_title(graph, iri, :document), do: Document.title(graph, iri)
  defp ancestry_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp ancestry_title(_graph, _iri, _type), do: nil

  defp search_sparql(query, scope, limit, include_spreadsheets?) do
    escaped = escape_sparql_string(query)
    terms = search_terms(query)
    match_filter = search_match_filter(escaped, terms)
    score_bind = search_score_bind(escaped, terms)
    scope_filter = if scope, do: "FILTER(?doc = <#{Id.iri(scope)}>)", else: ""
    row_union = if include_spreadsheets?, do: row_search_union(), else: ""

    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX prov: <http://www.w3.org/ns/prov#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    SELECT ?doc ?docTitle ?block ?kind ?text ?page ?spreadsheetRow ?spreadsheetSource ?codeCategory ?codeCategoryTitle WHERE {
      GRAPH ?doc {
        {
          ?doc a ?docKind .
          FILTER(?docKind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
        } UNION {
          ?doc a sheaf:Document .
          FILTER NOT EXISTS {
            ?doc a ?specificKind .
            FILTER(?specificKind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
          }
          BIND(sheaf:Document AS ?docKind)
        }
        OPTIONAL { ?doc rdfs:label ?docTitle }
        {
          ?block sheaf:paragraph ?para .
          ?para sheaf:text ?text .
          FILTER NOT EXISTS { ?para prov:wasInvalidatedBy ?_inv }
          BIND("paragraph" AS ?kind)
        } UNION {
          ?block sheaf:sourceHtml ?text .
          OPTIONAL { ?block sheaf:sourcePage ?page }
          BIND("extracted" AS ?kind)
        }
        #{row_union}
        BIND(LCASE(STR(?text)) AS ?haystack)
        #{match_filter}
        #{score_bind}
      }
      #{scope_filter}
      #{Sheaf.Workspace.exclusion_filter("?doc")}
    }
    ORDER BY DESC(?score)
    LIMIT #{limit}
    """
  end

  defp row_search_union do
    """
    UNION {
      ?block a sheaf:Row ;
        sheaf:text ?text .
      OPTIONAL { ?block sheaf:spreadsheetRow ?spreadsheetRow }
      OPTIONAL { ?block sheaf:spreadsheetSource ?spreadsheetSource }
      OPTIONAL { ?block sheaf:codeCategory ?codeCategory }
      OPTIONAL { ?block sheaf:codeCategoryTitle ?codeCategoryTitle }
      BIND("row" AS ?kind)
    }
    """
    |> String.trim()
  end

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
  end

  defp search_match_filter(escaped_query, []),
    do: ~s/FILTER(CONTAINS(?haystack, LCASE("#{escaped_query}")))/

  defp search_match_filter(escaped_query, terms) do
    keyword_match =
      terms
      |> Enum.map(&~s/CONTAINS(?haystack, "#{escape_sparql_string(&1)}")/)
      |> Enum.join(" || ")

    ~s/FILTER(CONTAINS(?haystack, LCASE("#{escaped_query}")) || #{keyword_match})/
  end

  defp search_score_bind(escaped_query, []),
    do: ~s/BIND(IF(CONTAINS(?haystack, LCASE("#{escaped_query}")), 100, 0) AS ?score)/

  defp search_score_bind(escaped_query, terms) do
    keyword_score =
      terms
      |> Enum.map(&~s/IF(CONTAINS(?haystack, "#{escape_sparql_string(&1)}"), 1, 0)/)
      |> Enum.join(" + ")

    """
    BIND(IF(CONTAINS(?haystack, LCASE("#{escaped_query}")), 100, 0) AS ?exactScore)
        BIND((?exactScore + #{keyword_score}) AS ?score)
    """
    |> String.trim()
  end

  defp escape_sparql_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", " ")
  end

  defp hit_from_row(row) do
    %{
      document_id: row |> Map.fetch!("doc") |> term_value() |> Id.id_from_iri(),
      document_title: row |> Map.get("docTitle") |> term_value(),
      block_id: row |> Map.fetch!("block") |> term_value() |> Id.id_from_iri(),
      kind: row |> Map.fetch!("kind") |> term_value() |> String.to_atom(),
      text: row |> Map.fetch!("text") |> term_value() |> clean_text(),
      source_page: row |> Map.get("page") |> integer_value()
    }
    |> maybe_add_coding(row)
  end

  defp maybe_add_coding(hit, %{"kind" => kind} = row) do
    if kind |> term_value() == "row" do
      Map.put(hit, :coding, %{
        row: row |> Map.get("spreadsheetRow") |> integer_value(),
        source: row |> Map.get("spreadsheetSource") |> term_value(),
        category: row |> Map.get("codeCategory") |> term_value(),
        category_title: row |> Map.get("codeCategoryTitle") |> term_value()
      })
    else
      hit
    end
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp integer_value(nil), do: nil

  defp integer_value(term) do
    case RDF.Term.value(term) do
      int when is_integer(int) -> int
      _ -> nil
    end
  end

  defp clean_text(text) do
    text
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
