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
      |> protect_math_delimiters()
      |> BlockRefs.linkify_markdown(url_for: resolver)
      |> MDEx.parse_document!(@mdex_opts)
    end
  end

  @doc false
  def restore_math_delimiters(text) when is_binary(text) do
    text
    |> restore_math_tokens(
      ~r/\x{E000}([A-Za-z0-9_-]+)\x{E001}/u,
      "\\(",
      "\\)"
    )
    |> restore_math_tokens(
      ~r/\x{E002}([A-Za-z0-9_-]+)\x{E003}/u,
      "\\[",
      "\\]"
    )
    |> restore_math_tokens(~r/\x{E004}([A-Za-z0-9_-]+)\x{E005}/u, "$", "$")
    |> restore_math_tokens(~r/\x{E006}([A-Za-z0-9_-]+)\x{E007}/u, "$$", "$$")
  end

  @doc false
  def math_token_content(token) when is_binary(token) do
    token
    |> String.slice(1, String.length(token) - 2)
    |> Base.url_decode64!(padding: false)
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

  defp protect_math_delimiters(text) do
    text
    |> protect_math_tokens(~r/\\\[([\s\S]*?)\\\]/, "\uE002", "\uE003")
    |> protect_math_tokens(~r/\\\(([\s\S]*?)\\\)/, "\uE000", "\uE001")
    |> protect_math_tokens(~r/\$\$([\s\S]*?)\$\$/, "\uE006", "\uE007")
    |> protect_math_tokens(
      ~r/(?<!\$)\$([0-9][^$\n]*(?:\\[A-Za-z]+|[_^])[^$\n]*)\$(?!\$)/,
      "\uE004",
      "\uE005"
    )
    |> protect_math_tokens(
      ~r/(?<!\$)\$(?![\d\s])([^$\n]+?)\$(?!\$)/,
      "\uE004",
      "\uE005"
    )
  end

  defp protect_math_tokens(text, pattern, opening, closing) do
    Regex.replace(pattern, text, fn _match, latex ->
      opening <> Base.url_encode64(latex, padding: false) <> closing
    end)
  end

  defp restore_math_tokens(text, pattern, opening, closing) do
    Regex.replace(pattern, text, fn _match, encoded ->
      opening <> Base.url_decode64!(encoded, padding: false) <> closing
    end)
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
