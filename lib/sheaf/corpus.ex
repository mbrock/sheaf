defmodule Sheaf.Corpus do
  @moduledoc """
  Corpus-level helpers for document lists, graph loading, block lookup, and
  ancestry within a loaded document graph.
  """

  alias RDF.Graph
  alias Sheaf.{Document, Documents, Id}

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
end
