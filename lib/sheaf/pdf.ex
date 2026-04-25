defmodule Sheaf.PDF do
  @moduledoc """
  Imports extracted PDF content as a Sheaf paper graph.
  """

  alias Datalab.Document, as: DatalabDocument
  alias Sheaf.BlobStore
  require RDF.Graph

  def import_file(path, opts \\ []) do
    with {:ok, document} <- DatalabDocument.read_file(path),
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
    source_path = present_value(Keyword.get(opts, :source_path))
    source_file = Keyword.get(opts, :source_file)
    source_file_iri = Keyword.get(opts, :source_file_iri) || (source_file && mint.())

    source_file_metadata =
      source_file_metadata(source_file, Keyword.has_key?(opts, :source_file_iri))

    blocks = DatalabDocument.document_blocks(document)
    nodes = flatten_nodes(blocks)
    node_iris = node_iris(nodes, mint)
    node_summaries = node_summaries(nodes, node_iris)
    child_lists = child_list_graphs(document_iri, blocks, node_iris, mint)

    graph =
      RDF.Graph.build document: document_iri,
                      title: title,
                      source_path: source_path,
                      source_file: source_file_metadata,
                      source_file_iri: source_file_iri,
                      source_file_metadata: source_file_metadata,
                      nodes: node_summaries,
                      child_lists: child_lists do
        @prefix Sheaf.NS.DOC
        @prefix Sheaf.NS.FABIO
        @prefix RDF.NS.RDFS

        document
        |> a(DOC.Document)
        |> a(DOC.Paper)
        |> RDFS.label(title)
        |> DOC.sourceKey(source_path)
        |> DOC.sourceFile(source_file_iri)

        if source_file_metadata do
          source_file_iri
          |> a(FABIO.ComputerFile)
          |> RDFS.label(source_file.original_filename)
          |> DOC.sha256(source_file.hash)
          |> DOC.sourceKey(source_file.storage_key)
          |> DOC.mimeType(source_file.mime_type)
          |> DOC.byteSize(source_file.byte_size)
          |> DOC.originalFilename(source_file.original_filename)
        end

        Enum.map(nodes, fn node ->
          node.iri
          |> a(node.class)
          |> RDFS.label(node.label)
          |> DOC.sourceKey(node.source_key)
          |> DOC.sourceBlockType(node.source_block_type)
          |> DOC.sourcePage(node.source_page)
          |> DOC.sourceHtml(node.source_html)
        end)

        child_lists
      end

    %{document: document_iri, graph: graph, source_file: source_file, title: title}
  end

  defp source_file_metadata(nil, _existing_file?), do: nil
  defp source_file_metadata(_source_file, true), do: nil

  defp source_file_metadata(source_file, false) do
    %{
      original_filename: source_file_value(source_file, :original_filename),
      hash: source_file_value(source_file, :hash),
      storage_key: source_file_value(source_file, :storage_key),
      mime_type: source_file_value(source_file, :mime_type),
      byte_size: source_file_value(source_file, :byte_size)
    }
    |> Map.new(fn {key, value} -> {key, present_value(value)} end)
  end

  defp node_summaries(nodes, node_iris) do
    Enum.map(nodes, fn node -> node_summary(node, Map.fetch!(node_iris, node.id)) end)
  end

  defp node_summary(%{type: :section, block: block} = node, iri) do
    node
    |> source_summary()
    |> Map.merge(%{
      iri: iri,
      class: Sheaf.NS.DOC.Section,
      label: present_value(DatalabDocument.block_title(block))
    })
  end

  defp node_summary(%{type: :block} = node, iri) do
    node
    |> source_summary()
    |> Map.merge(%{iri: iri, class: Sheaf.NS.DOC.ExtractedBlock, label: nil})
  end

  defp source_summary(%{block: block}) do
    %{
      source_key: present_value(Map.get(block, "id")),
      source_block_type: present_value(Map.get(block, "block_type")),
      source_page: DatalabDocument.source_page(block),
      source_html: present_value(DatalabDocument.block_html(block))
    }
  end

  defp child_list_graphs(_parent_iri, [], _node_iris, _mint), do: []

  defp child_list_graphs(parent_iri, children, node_iris, mint) do
    child_iris = Enum.map(children, &Map.fetch!(node_iris, &1.id))
    list_iri = mint.()

    [
      ordered_children_graph(parent_iri, child_iris, list_iri)
      | Enum.flat_map(children, fn child ->
          child_iri = Map.fetch!(node_iris, child.id)
          child_list_graphs(child_iri, Map.get(child, :children, []), node_iris, mint)
        end)
    ]
  end

  defp ordered_children_graph(parent_iri, child_iris, list_iri) do
    child_iris
    |> RDF.list(
      graph: RDF.Graph.new(parent_iri |> Sheaf.NS.DOC.children(list_iri)),
      head: list_iri
    )
    |> Map.fetch!(:graph)
  end

  defp node_iris(nodes, mint), do: Map.new(nodes, fn node -> {node.id, mint.()} end)

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

  defp present_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_value(value), do: value

  defp title(%{"metadata" => %{"title" => title}}) when is_binary(title) and title != "" do
    title
  end

  defp title(_document), do: nil
end
