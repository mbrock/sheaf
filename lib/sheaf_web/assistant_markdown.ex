defmodule SheafWeb.AssistantMarkdown do
  @moduledoc """
  Shared markdown rendering for assistant-visible text.
  """

  alias Sheaf.{BlockRefs, Corpus, ResourceResolver}

  require OpenTelemetry.Tracer, as: Tracer

  @mdex_opts [
    extension: [
      strikethrough: true,
      autolink: true,
      table: true,
      tasklist: true
    ],
    parse: [smart: true]
  ]

  def document(text, opts \\ []) do
    text = text || ""

    refs =
      text
      |> BlockRefs.ids_from_text()
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    resource_paths = Keyword.get(opts, :resource_paths)

    Tracer.with_span "SheafWeb.AssistantMarkdown.document", %{
      kind: :internal,
      attributes: [
        {"sheaf.text_size", byte_size(text)},
        {"sheaf.resource_ref_count", length(refs)}
      ]
    } do
      resolver = resource_ref_resolver(refs, resource_paths)

      text
      |> BlockRefs.linkify_markdown(url_for: resolver)
      |> MDEx.parse_document!(@mdex_opts)
    end
  end

  def resource_paths(texts) when is_list(texts) do
    refs =
      texts
      |> Enum.flat_map(&BlockRefs.ids_from_text/1)
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    Tracer.with_span "SheafWeb.AssistantMarkdown.resource_paths", %{
      kind: :internal,
      attributes: [{"sheaf.resource_ref_count", length(refs)}]
    } do
      block_documents = Corpus.find_documents(refs)

      paths =
        block_paths(block_documents)
        |> Map.merge(resource_paths(refs, block_documents))

      Tracer.set_attribute("sheaf.block_ref_count", map_size(block_documents))
      Tracer.set_attribute("sheaf.resource_path_count", map_size(paths))

      paths
    end
  end

  def resource_paths(_other), do: %{}

  defp resource_ref_resolver(refs, resource_paths)
       when is_map(resource_paths) do
    Tracer.with_span "SheafWeb.AssistantMarkdown.resource_ref_resolver", %{
      kind: :internal,
      attributes: [
        {"sheaf.resource_ref_count", length(refs)},
        {"sheaf.precomputed_resource_path_count", map_size(resource_paths)}
      ]
    } do
      fn id ->
        case Map.fetch(resource_paths, id) do
          {:ok, path} -> path
          :error -> nil
        end
      end
    end
  end

  defp resource_ref_resolver(refs, _resource_paths) do
    Tracer.with_span "SheafWeb.AssistantMarkdown.resource_ref_resolver", %{
      kind: :internal,
      attributes: [{"sheaf.resource_ref_count", length(refs)}]
    } do
      block_documents = Corpus.find_documents(refs)
      resource_paths = resource_paths(refs, block_documents)

      Tracer.set_attribute("sheaf.block_ref_count", map_size(block_documents))

      Tracer.set_attribute(
        "sheaf.non_block_ref_count",
        map_size(resource_paths)
      )

      fn id ->
        cond do
          Map.has_key?(block_documents, id) -> "/b/#{id}"
          Map.has_key?(resource_paths, id) -> Map.fetch!(resource_paths, id)
          true -> nil
        end
      end
    end
  end

  defp block_paths(block_documents) do
    Map.new(block_documents, fn {id, _document_id} -> {id, "/b/#{id}"} end)
  end

  defp resource_paths(refs, block_documents) do
    refs
    |> Enum.reject(&Map.has_key?(block_documents, &1))
    |> Map.new(fn id -> {id, resource_ref_path(id, skip_block?: true)} end)
  end

  defp resource_ref_path(id, opts) do
    case ResourceResolver.resolve(id, opts) do
      {:ok, %{kind: :block}} -> "/b/#{id}"
      {:ok, %{kind: _kind}} -> "/#{id}"
      {:error, _reason} -> nil
    end
  catch
    :exit, _reason -> nil
  end
end
