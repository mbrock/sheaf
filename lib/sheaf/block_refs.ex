defmodule Sheaf.BlockRefs do
  @moduledoc """
  Helpers for recognizing Sheaf block ids in user-visible text.
  """

  @hash_block_id ~r/(?<![\[\/#A-Z0-9])#([ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6})(?![A-Z0-9])/
  @block_id_extract ~r/(?<![\/#A-Z0-9])#?([A-Z0-9]{6})(?![A-Z0-9])/
  @block_href ~r/\/b\/([A-Z0-9]{6})\b/
  @bracketed_bare_block_id ~r/\[([ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6})\](?!\()/
  @existing_block_link ~r/(\[#[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}\]\(\/b\/[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}\))/

  @doc """
  Extracts block ids from bare ids, `#ID`, and `/b/ID` links.
  """
  def ids_from_text(text) when is_binary(text) do
    refs =
      @block_id_extract
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    hrefs =
      @block_href
      |> Regex.scan(text)
      |> Enum.map(fn [_match, id] -> id end)

    Enum.uniq(refs ++ hrefs)
  end

  def ids_from_text(_other), do: []

  @doc """
  Rewrites bare block references in markdown text to Sheaf block links.

  Existing markdown links such as `[#ABC123](/b/ABC123)` are left alone.
  """
  def linkify_markdown(text, opts \\ [])

  def linkify_markdown(text, opts) when is_binary(text) do
    exists? = Keyword.get(opts, :exists?, fn _id -> true end)

    @existing_block_link
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map_join(&linkify_unless_existing_block_link(&1, exists?))
  end

  def linkify_markdown(other, _opts), do: other

  defp linkify_unless_existing_block_link(text, exists?) do
    if Regex.match?(@existing_block_link, text) do
      text
    else
      text =
        Regex.replace(@bracketed_bare_block_id, text, fn _match, id ->
          if exists?.(id), do: "[##{id}](/b/#{id})", else: "[#{id}]"
        end)

      Regex.replace(@hash_block_id, text, fn _match, id ->
        if exists?.(id), do: "[##{id}](/b/#{id})", else: "##{id}"
      end)
    end
  end
end
