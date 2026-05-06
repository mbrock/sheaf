defmodule Datalab.Document do
  @moduledoc """
  Helpers for Datalab's extracted document model.
  """

  def read_file(path) do
    with {:ok, json} <- File.read(path) do
      Jason.decode(json)
    end
  end

  def document_blocks(%{"children" => pages}), do: document_blocks(pages)

  def document_blocks(pages) when is_list(pages) do
    pages
    |> flatten_blocks()
    |> build_tree()
  end

  def block_html(block) do
    html = Map.get(block, "html", "")

    block
    |> Map.get("images", %{})
    |> Enum.reduce(html, fn {filename, base64}, html ->
      String.replace(
        html,
        ~s(src="#{filename}"),
        ~s(src="data:#{mime_type(filename)};base64,#{base64}")
      )
    end)
  end

  def block_title(block) do
    block
    |> Map.get("html", "")
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def section_blocks(blocks) do
    Enum.filter(blocks, &match?(%{type: :section}, &1))
  end

  def source_page(block) do
    case Map.get(block, "page") do
      page when is_integer(page) -> page
      page when is_float(page) -> trunc(page)
      _ -> nil
    end
  end

  defp flatten_blocks(pages) do
    pages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {page, page_number} ->
      page
      |> Map.get("children", [])
      |> Enum.with_index()
      |> Enum.map(fn {block, block_index} ->
        id = Map.get(block, "id", "page-#{page_number}-block-#{block_index}")

        block
        |> Map.put("_reader_page", page_number)
        |> Map.put("_reader_dom_id", dom_id(id))
        |> Map.put("_reader_source_id", id)
      end)
    end)
  end

  defp build_tree(blocks) do
    {sections, children_by_parent} =
      Enum.reduce(blocks, {%{}, %{}}, fn block,
                                         {sections, children_by_parent} ->
        case heading_level(block) do
          nil ->
            node = block_node(block)
            parent_id = parent_section_id(block, :block)

            {sections, append_child(children_by_parent, parent_id, node)}

          level ->
            node = section_node(block, level)
            parent_id = parent_section_id(block, {:section, level})

            {Map.put(sections, node.id, true),
             append_child(children_by_parent, parent_id, node)}
        end
      end)

    roots = Map.get(children_by_parent, nil, []) |> Enum.reverse()

    orphans =
      children_by_parent
      |> Enum.reject(fn {parent_id, _children} ->
        is_nil(parent_id) or Map.has_key?(sections, parent_id)
      end)
      |> Enum.flat_map(fn {_parent_id, children} ->
        Enum.reverse(children)
      end)

    Enum.map(roots ++ orphans, &attach_children(&1, children_by_parent))
  end

  defp attach_children(%{type: :section} = node, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(node.id, [])
      |> Enum.reverse()
      |> Enum.map(&attach_children(&1, children_by_parent))

    %{node | children: children}
  end

  defp attach_children(node, _children_by_parent), do: node

  defp section_node(block, level) do
    %{
      type: :section,
      id: block_id(block),
      dom_id: Map.fetch!(block, "_reader_dom_id"),
      level: level,
      block: block,
      children: []
    }
  end

  defp block_node(block) do
    %{
      type: :block,
      id: block_id(block),
      dom_id: Map.fetch!(block, "_reader_dom_id"),
      page: Map.fetch!(block, "_reader_page"),
      block: block
    }
  end

  defp append_child(children_by_parent, parent_id, node) do
    Map.update(children_by_parent, parent_id, [node], &[node | &1])
  end

  defp parent_section_id(block, {:section, heading_level}) do
    block
    |> hierarchy_entries()
    |> Enum.filter(fn {level, _id} -> level < heading_level end)
    |> deepest_id()
  end

  defp parent_section_id(block, :block) do
    block
    |> hierarchy_entries()
    |> deepest_id()
  end

  defp hierarchy_entries(block) do
    block
    |> Map.get("section_hierarchy", %{})
    |> Enum.flat_map(fn {level, id} ->
      case Integer.parse(to_string(level)) do
        {level, ""} -> [{level, id}]
        _ -> []
      end
    end)
  end

  defp deepest_id(entries) do
    entries
    |> Enum.max_by(fn {level, _id} -> level end, fn -> nil end)
    |> case do
      {_level, id} -> id
      nil -> nil
    end
  end

  defp heading_level(%{"block_type" => "SectionHeader", "html" => html}) do
    case Regex.run(~r/<h([1-6])(?:\s|>)/i, html) do
      [_, level] -> String.to_integer(level)
      _ -> nil
    end
  end

  defp heading_level(_block), do: nil

  defp block_id(block),
    do: Map.get(block, "id") || Map.fetch!(block, "_reader_source_id")

  defp dom_id(id) do
    id
    |> to_string()
    |> String.trim("/")
    |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
  end

  defp mime_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      _ -> "image/jpeg"
    end
  end
end
