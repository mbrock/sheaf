defmodule Sheaf.Corpus do
  @moduledoc """
  Corpus-level helpers for document lists, graph loading, block lookup, and
  ancestry within a loaded document graph.
  """

  alias RDF.Graph
  alias Sheaf.{Document, Documents, Id}
  alias Sheaf.NS.DOC

  require OpenTelemetry.Tracer, as: Tracer

  @block_classes [
    DOC.Block,
    DOC.Section,
    DOC.ParagraphBlock,
    DOC.ExtractedBlock,
    DOC.Row,
    DOC.Segment,
    DOC.Utterance
  ]

  @document_classes [
    DOC.Document,
    DOC.Thesis,
    DOC.Transcript,
    DOC.Paper,
    DOC.Spreadsheet,
    DOC.Interview
  ]

  @contained_resource_classes @document_classes ++ @block_classes
  @contained_resource_class_iris Enum.map(@contained_resource_classes, &RDF.iri/1)

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
    ids =
      block_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    Tracer.with_span "Sheaf.Corpus.find_documents", %{
      kind: :internal,
      attributes: [{"sheaf.block_id_count", length(ids)}]
    } do
      requested_ids = MapSet.new(ids)
      requested_iris = Map.new(ids, &{Id.iri(&1), &1})

      with false <- MapSet.size(requested_ids) == 0,
           {:ok, rows} <- block_type_rows(Map.keys(requested_iris)) do
        index = block_document_index(rows, requested_iris)
        Tracer.set_attribute("sheaf.block_document_count", map_size(index))
        index
      else
        true -> %{}
        _ -> %{}
      end
    end
  end

  defp block_type_rows(iris) do
    Sheaf.Repo.match_rows({
      iris,
      RDF.type(),
      nil,
      nil
    })
  end

  defp block_document_index(rows, requested_iris) do
    rows
    |> Enum.reduce(%{}, fn {graph, subject, predicate, object}, index ->
      if predicate == RDF.type() and Map.has_key?(requested_iris, subject) and
           block_class?(object) do
        Map.put_new(index, Map.fetch!(requested_iris, subject), Id.id_from_iri(graph))
      else
        index
      end
    end)
  end

  defp block_class?(class), do: class in @contained_resource_class_iris

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
