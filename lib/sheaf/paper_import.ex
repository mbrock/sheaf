defmodule Sheaf.PaperImport do
  @moduledoc """
  Imports Datalab JSON as a Sheaf paper graph.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.{BlobStore, DatalabJSON}
  alias Sheaf.NS.{DOC, FABIO}

  def import_file(path, opts \\ []) do
    with {:ok, document} <- DatalabJSON.read_file(path),
         {:ok, source_file} <- source_file_for(path, opts) do
      result =
        document
        |> build_graph(
          opts
          |> Keyword.put_new(:source_path, path)
          |> put_source_file(source_file)
        )

      :ok = Sheaf.put_graph(result.document, result.graph)
      {:ok, result}
    end
  end

  def build_graph(%{"children" => _pages} = document, opts \\ []) do
    mint = Keyword.get(opts, :mint, &Sheaf.mint/0)
    document_iri = Keyword.get_lazy(opts, :document, mint)
    title = Keyword.get(opts, :title) || title(document)
    source_path = Keyword.get(opts, :source_path)
    source_file = Keyword.get(opts, :source_file)
    source_file_iri = source_file && Keyword.get_lazy(opts, :source_file_iri, mint)

    blocks = DatalabJSON.document_blocks(document)
    node_iris = node_iris(blocks, mint)

    graph =
      Graph.new(document_triples(document_iri, title, source_path))
      |> add_source_file(document_iri, source_file, source_file_iri)
      |> add_children(document_iri, blocks, node_iris, mint)
      |> add_nodes(blocks, node_iris, mint)

    %{document: document_iri, graph: graph, source_file: source_file, title: title}
  end

  defp document_triples(document_iri, title, source_path) do
    [
      {document_iri, RDF.type(), DOC.Document},
      {document_iri, RDF.type(), DOC.Paper},
      {document_iri, RDFS.label(), RDF.literal(title)}
    ]
    |> maybe_add(source_path, fn path -> {document_iri, DOC.sourceKey(), RDF.literal(path)} end)
  end

  defp add_source_file(graph, _document_iri, nil, _source_file_iri), do: graph

  defp add_source_file(graph, document_iri, source_file, source_file_iri) do
    Graph.add(graph, source_file_triples(document_iri, source_file, source_file_iri))
  end

  defp source_file_triples(document_iri, source_file, source_file_iri) do
    [
      {document_iri, DOC.sourceFile(), source_file_iri},
      {source_file_iri, RDF.type(), FABIO.ComputerFile}
    ]
    |> maybe_add(source_file_value(source_file, :original_filename), fn filename ->
      {source_file_iri, RDFS.label(), RDF.literal(filename)}
    end)
    |> maybe_add(source_file_value(source_file, :hash), fn hash ->
      {source_file_iri, DOC.sha256(), RDF.literal(hash)}
    end)
    |> maybe_add(source_file_value(source_file, :storage_key), fn key ->
      {source_file_iri, DOC.sourceKey(), RDF.literal(key)}
    end)
    |> maybe_add(source_file_value(source_file, :mime_type), fn mime_type ->
      {source_file_iri, DOC.mimeType(), RDF.literal(mime_type)}
    end)
    |> maybe_add(source_file_value(source_file, :byte_size), fn byte_size ->
      {source_file_iri, DOC.byteSize(), RDF.literal(byte_size)}
    end)
    |> maybe_add(source_file_value(source_file, :original_filename), fn filename ->
      {source_file_iri, DOC.originalFilename(), RDF.literal(filename)}
    end)
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

  defp source_file_for(path, opts) do
    cond do
      Keyword.has_key?(opts, :source_file) ->
        {:ok, Keyword.fetch!(opts, :source_file)}

      pdf_path = Keyword.get(opts, :pdf_path) ->
        BlobStore.put_file(pdf_path, blob_store_opts(opts))

      pdf_path = default_pdf_path(path) ->
        BlobStore.put_file(pdf_path, blob_store_opts(opts))

      true ->
        {:ok, nil}
    end
  end

  defp put_source_file(opts, nil), do: opts
  defp put_source_file(opts, source_file), do: Keyword.put(opts, :source_file, source_file)

  defp default_pdf_path(path) do
    pdf_path =
      cond do
        String.ends_with?(path, ".datalab.hq.json") ->
          String.replace_suffix(path, ".datalab.hq.json", ".pdf")

        String.ends_with?(path, ".datalab.json") ->
          String.replace_suffix(path, ".datalab.json", ".pdf")

        true ->
          Path.rootname(path) <> ".pdf"
      end

    if File.exists?(pdf_path), do: pdf_path
  end

  defp blob_store_opts(opts) do
    opts
    |> Keyword.take([:blob_root])
    |> Keyword.new(fn {:blob_root, root} -> {:root, root} end)
  end

  defp source_file_value(source_file, key) do
    Map.get(source_file, key) || Map.get(source_file, to_string(key))
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
