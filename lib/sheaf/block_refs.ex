defmodule Sheaf.BlockRefs do
  @moduledoc """
  Helpers for recognizing Sheaf block ids in user-visible text.
  """

  @hash_block_id ~r/(?<![\[\/#A-Z0-9])#([A-Z0-9]{3,12})(?![A-Z0-9])/i
  @block_id_extract ~r/(?<![\/#A-Z0-9])#?((?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]{6})(?![A-Z0-9])/i
  @block_href ~r/\/b\/([A-Z0-9]{3,12})\b/i
  @bracketed_bare_block_id ~r/\[([A-Z0-9]{3,12})\](?!\()/i
  @existing_block_link ~r/(\[#[A-Z0-9]{3,12}\]\(\/b\/[A-Z0-9]{3,12}\))/i
  @space_before_punctuation ~r/[ \t]+([,.;:!?\)\]\}])/

  @doc """
  Extracts block ids from bare ids, `#ID`, and `/b/ID` links.
  """
  def ids_from_text(text) when is_binary(text) do
    bare_refs =
      @block_id_extract
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    hash_refs =
      @hash_block_id
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    bracketed_refs =
      @bracketed_bare_block_id
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    hrefs =
      @block_href
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    code_refs =
      text
      |> split_fenced_code()
      |> Enum.flat_map(fn
        {:code, _segment} -> []
        {:text, segment} -> code_span_ids(segment)
      end)

    bare_refs
    |> Kernel.++(hash_refs)
    |> Kernel.++(bracketed_refs)
    |> Kernel.++(hrefs)
    |> Kernel.++(code_refs)
    |> Enum.map(&String.upcase/1)
    |> Enum.uniq()
  end

  def ids_from_text(_other), do: []

  @doc """
  Rewrites bare block references in markdown text to Sheaf block links.

  Existing markdown links such as `[#ABC123](/b/ABC123)` are left alone.
  """
  def linkify_markdown(text, opts \\ [])

  def linkify_markdown(text, opts) when is_binary(text) do
    exists? = Keyword.get(opts, :exists?, fn _id -> true end)
    url_for = Keyword.get(opts, :url_for, fn id -> if exists?.(id), do: "/b/#{id}" end)

    text
    |> split_fenced_code()
    |> Enum.map_join(fn
      {:code, segment} -> segment
      {:text, segment} -> linkify_inline_markdown(segment, url_for)
    end)
  end

  def linkify_markdown(other, _opts), do: other

  defp linkify_inline_markdown(text, url_for) do
    text
    |> split_inline_code()
    |> Enum.map_join(fn
      {:code, segment} -> linkify_code_span(segment, url_for)
      {:text, segment} -> segment |> normalize_spacing() |> linkify_plain_markdown(url_for)
    end)
  end

  defp linkify_plain_markdown(text, url_for) do
    @existing_block_link
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map_join(&linkify_unless_existing_block_link(&1, url_for))
  end

  defp linkify_unless_existing_block_link(text, url_for) do
    if Regex.match?(@existing_block_link, text) do
      text
    else
      text =
        Regex.replace(@bracketed_bare_block_id, text, fn _match, id ->
          id = String.upcase(id)
          if url = url_for.(id), do: "[##{id}](#{url})", else: "[#{id}]"
        end)

      Regex.replace(@hash_block_id, text, fn _match, id ->
        id = String.upcase(id)
        if url = url_for.(id), do: "[##{id}](#{url})", else: "##{id}"
      end)
    end
  end

  defp normalize_spacing(text) do
    Regex.replace(@space_before_punctuation, text, "\\1")
  end

  defp split_fenced_code(text) do
    text
    |> String.split(~r/((?:^|\n)[ \t]*(?:```|~~~).*(?:\n|$))/,
      include_captures: true,
      trim: false
    )
    |> Enum.map_reduce(false, fn segment, in_fence? ->
      fence? = Regex.match?(~r/^(?:\n)?[ \t]*(?:```|~~~)/, segment)
      kind = if in_fence? or fence?, do: :code, else: :text

      state = if fence?, do: not in_fence?, else: in_fence?

      {{kind, segment}, state}
    end)
    |> elem(0)
  end

  defp split_inline_code(text) do
    ~r/(`+[^`]*`+)/
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map(fn
      "`" <> _rest = segment -> {:code, segment}
      segment -> {:text, segment}
    end)
  end

  defp code_span_ids(text) do
    text
    |> split_inline_code()
    |> Enum.flat_map(fn
      {:code, segment} ->
        case Regex.run(~r/^(`+)(.*)\1$/, segment) do
          [_, _ticks, content] ->
            case code_span_resource_id(content) do
              nil -> []
              id -> [id]
            end

          _other ->
            []
        end

      {:text, _segment} ->
        []
    end)
  end

  defp linkify_code_span(segment, url_for) do
    with [_, _ticks, content] <- Regex.run(~r/^(`+)(.*)\1$/, segment),
         id when not is_nil(id) <- code_span_resource_id(content),
         url when is_binary(url) <- url_for.(id) do
      "[##{id}](#{url})"
    else
      _ -> segment
    end
  end

  defp code_span_resource_id("#" <> id), do: valid_resource_id(id)
  defp code_span_resource_id(id), do: valid_resource_id(id)

  defp valid_resource_id(id) do
    if Regex.match?(~r/^[A-Z0-9]{3,12}$/i, id), do: String.upcase(id)
  end
end
