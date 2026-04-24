defmodule Sheaf.PaperImport do
  @moduledoc """
  Imports Datalab JSON as a Sheaf paper graph.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.DatalabJSON
  alias Sheaf.NS.DOC

  def import_file(path, opts \\ []) do
    with {:ok, document} <- DatalabJSON.read_file(path) do
      result = build_graph(document, Keyword.put_new(opts, :source_path, path))
      :ok = Sheaf.put_graph(result.document, result.graph)
      {:ok, result}
    end
  end

  def build_graph(%{"children" => _pages} = document, opts \\ []) do
    mint = Keyword.get(opts, :mint, &Sheaf.mint/0)
    document_iri = Keyword.get_lazy(opts, :document, mint)
    title = Keyword.get(opts, :title) || title(document)
    source_path = Keyword.get(opts, :source_path)

    blocks = DatalabJSON.document_blocks(document)
    node_iris = node_iris(blocks, mint)

    graph =
      Graph.new(document_triples(document_iri, title, source_path))
      |> add_children(document_iri, blocks, node_iris, mint)
      |> add_nodes(blocks, node_iris, mint)

    %{document: document_iri, graph: graph, title: title}
  end

  defp document_triples(document_iri, title, source_path) do
    [
      {document_iri, RDF.type(), DOC.Document},
      {document_iri, RDF.type(), DOC.Paper},
      {document_iri, RDFS.label(), RDF.literal(title)}
    ]
    |> maybe_add(source_path, fn path -> {document_iri, DOC.sourceKey(), RDF.literal(path)} end)
  end

  defp add_nodes(graph, blocks, node_iris, mint) do
    Enum.reduce(blocks, graph, fn node, graph ->
      graph
      |> Graph.add(node_triples(node, Map.fetch!(node_iris, node.id)))
      |> add_children(
        Map.fetch!(node_iris, node.id),
        Map.get(node, :children, []),
        node_iris,
        mint
      )
      |> add_nodes(Map.get(node, :children, []), node_iris, mint)
    end)
  end

  defp add_children(graph, _parent_iri, [], _node_iris, _mint), do: graph

  defp add_children(graph, parent_iri, children, node_iris, mint) do
    child_iris = Enum.map(children, &Map.fetch!(node_iris, &1.id))
    list_iri = mint.()

    graph
    |> Graph.add({parent_iri, DOC.children(), list_iri})
    |> then(fn graph -> RDF.list(child_iris, graph: graph, head: list_iri).graph end)
  end

  defp node_triples(%{type: :section, block: block} = node, iri) do
    [
      {iri, RDF.type(), DOC.Section},
      {iri, RDFS.label(), RDF.literal(DatalabJSON.block_title(block))}
    ] ++ source_triples(iri, node)
  end

  defp node_triples(%{type: :block} = node, iri) do
    [
      {iri, RDF.type(), DOC.ExtractedBlock}
    ] ++ source_triples(iri, node)
  end

  defp source_triples(iri, %{block: block}) do
    []
    |> maybe_add(Map.get(block, "id"), fn id -> {iri, DOC.sourceKey(), RDF.literal(id)} end)
    |> maybe_add(Map.get(block, "block_type"), fn type ->
      {iri, DOC.sourceBlockType(), RDF.literal(type)}
    end)
    |> maybe_add(DatalabJSON.source_page(block), fn page ->
      {iri, DOC.sourcePage(), RDF.literal(page)}
    end)
    |> maybe_add(DatalabJSON.block_html(block), fn html ->
      {iri, DOC.sourceHtml(), RDF.literal(html)}
    end)
  end

  defp node_iris(blocks, mint) do
    blocks
    |> flatten_nodes()
    |> Map.new(fn node -> {node.id, mint.()} end)
  end

  defp flatten_nodes(nodes) do
    Enum.flat_map(nodes, fn node -> [node | flatten_nodes(Map.get(node, :children, []))] end)
  end

  defp maybe_add(triples, nil, _fun), do: triples
  defp maybe_add(triples, "", _fun), do: triples
  defp maybe_add(triples, value, fun), do: triples ++ [fun.(value)]

  defp title(%{"metadata" => %{"title" => title}}) when is_binary(title) and title != "" do
    title
  end

  defp title(document) do
    document
    |> DatalabJSON.document_blocks()
    |> DatalabJSON.section_blocks()
    |> Enum.find_value("Untitled paper", fn section ->
      section.block
      |> DatalabJSON.block_title()
      |> case do
        "" -> nil
        title -> title
      end
    end)
  end
end
