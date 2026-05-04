defmodule Sheaf.Corpus do
  @moduledoc """
  Corpus-level helpers for document lists, graph loading, block lookup, and
  ancestry within a loaded document graph.
  """

  alias RDF.Graph
  alias Sheaf.{Document, Documents, Id}
  alias Sheaf.NS.DOC

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

  This is how `#BLOCKID` links resolve.
  """
  @spec find_document(String.t()) :: String.t() | nil
  def find_document(block_id) when is_binary(block_id) do
    block_id
    |> List.wrap()
    |> find_documents()
    |> Map.get(block_id)
  end

  @spec find_documents([String.t()]) :: %{String.t() => String.t()}
  def find_documents([]), do: %{}

  def find_documents(block_ids) when is_list(block_ids) do
    blocks =
      block_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Map.new(&{Id.iri(&1), &1})

    with false <- map_size(blocks) == 0,
         :ok <- load_block_descriptions(Map.keys(blocks)) do
      Sheaf.Repo.ask(fn dataset ->
        dataset
        |> RDF.Dataset.graphs()
        |> document_graph_block_index(blocks)
      end)
    else
      true -> %{}
      _ -> %{}
    end
  end

  defp load_block_descriptions(blocks) do
    Enum.reduce_while(blocks, :ok, fn block, :ok ->
      case Sheaf.Repo.load_once({block, nil, nil, nil}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp document_graph_block_index(graphs, blocks) do
    graphs
    |> Enum.filter(&document_graph?/1)
    |> Enum.reduce({%{}, blocks}, fn
      _graph, {index, remaining} when map_size(remaining) == 0 ->
        {index, remaining}

      graph, {index, remaining} ->
        doc_id = Id.id_from_iri(graph.name)

        {found, remaining} =
          Enum.split_with(remaining, fn {block, _id} -> Graph.describes?(graph, block) end)

        index =
          Enum.reduce(found, index, fn {_block, id}, index ->
            Map.put_new(index, id, doc_id)
          end)

        {index, Map.new(remaining)}
    end)
    |> elem(0)
  end

  defp document_graph?(%Graph{name: nil}), do: false

  defp document_graph?(%Graph{name: name} = graph) do
    RDF.Data.include?(graph, {name, RDF.type(), DOC.Document})
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
