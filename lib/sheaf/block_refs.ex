defmodule Sheaf.BlockRefs do
  @moduledoc """
  Helpers for recognizing Sheaf block ids in user-visible text.
  """

  @bare_or_hash_block_id ~r/(?<![\[\/#A-Z0-9])#?([A-Z0-9]{6})(?![A-Z0-9])/
  @block_id_extract ~r/(?<![\/#A-Z0-9])#?([A-Z0-9]{6})(?![A-Z0-9])/
  @block_href ~r/\/b\/([A-Z0-9]{6})\b/
  @bracketed_bare_block_id ~r/\[([A-Z0-9]{6})\](?!\()/
  @existing_block_link ~r/(\[#[A-Z0-9]{6}\]\(\/b\/[A-Z0-9]{6}\))/

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
  def linkify_markdown(text) when is_binary(text) do
    @existing_block_link
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map_join(&linkify_unless_existing_block_link/1)
  end

  def linkify_markdown(other), do: other

  defp linkify_unless_existing_block_link(text) do
    if Regex.match?(@existing_block_link, text) do
      text
    else
      text =
        Regex.replace(@bracketed_bare_block_id, text, fn _match, id ->
          "[##{id}](/b/#{id})"
        end)

      Regex.replace(@bare_or_hash_block_id, text, fn _match, id -> "[##{id}](/b/#{id})" end)
    end
  end
end
