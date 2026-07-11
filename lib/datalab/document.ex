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
    |> coalesce_page_continuations()
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

  @doc """
  Returns the LaTeX expressions carried by Datalab `<math>` elements.

  Datalab uses `<math>` as a container for LaTeX rather than emitting MathML.
  Keeping this extraction here preserves the raw HTML while giving importers a
  structured mathematical representation to index and inspect.
  """
  def math_expressions(block) do
    block
    |> Map.get("html", "")
    |> then(
      &Regex.scan(~r/<math\b[^>]*>(.*?)<\/math>/is, &1,
        capture: :all_but_first
      )
    )
    |> List.flatten()
    |> Enum.map(&decode_html_entities/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Summarizes a Datalab JSON document for deterministic import review.
  """
  def quality_report(%{"children" => pages}) when is_list(pages) do
    blocks = Enum.flat_map(pages, &Map.get(&1, "children", []))

    block_types =
      Enum.frequencies_by(blocks, &Map.get(&1, "block_type", "Unknown"))

    math = Enum.flat_map(blocks, &math_expressions/1)

    equation_blocks =
      Enum.count(blocks, &(Map.get(&1, "block_type") == "Equation"))

    %{
      pages: length(pages),
      blocks: length(blocks),
      block_types: block_types,
      equation_blocks: equation_blocks,
      math_expressions: length(math),
      pages_with_math:
        blocks
        |> Enum.filter(&(math_expressions(&1) != []))
        |> Enum.map(&source_page/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length(),
      empty_equation_blocks:
        Enum.count(blocks, fn block ->
          Map.get(block, "block_type") == "Equation" and
            math_expressions(block) == []
        end),
      page_continuations: length(page_continuations(pages))
    }
  end

  def quality_report(_document), do: {:error, :invalid_datalab_document}

  @doc """
  Returns conservative text-fragment pairs that can be reconstructed across a
  source page boundary.
  """
  def page_continuations(%{"children" => pages}),
    do: page_continuations(pages)

  def page_continuations(pages) when is_list(pages) do
    pages
    |> flatten_blocks()
    |> continuation_pairs()
    |> Enum.map(fn {previous, following} ->
      %{
        previous_id: block_id(previous),
        following_id: block_id(following),
        page_start: source_page_start(previous),
        page_end: source_page_end(following),
        previous_text: block_title(previous),
        following_text: block_title(following)
      }
    end)
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

  def source_page_end(block) do
    case Map.get(block, "_reader_source_pages") do
      pages when is_list(pages) and pages != [] -> List.last(pages)
      _other -> source_page(block)
    end
  end

  def source_keys(block) do
    case Map.get(block, "_reader_source_ids") do
      ids when is_list(ids) and ids != [] -> ids
      _other -> [Map.get(block, "id")]
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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
        |> Map.put("_reader_source_ids", [id])
        |> Map.put("_reader_source_pages", source_pages(block))
      end)
    end)
  end

  defp coalesce_page_continuations(blocks) do
    {done, last_text, between} =
      Enum.reduce(blocks, {[], nil, []}, fn block,
                                            {done, last_text, between} ->
        if text_block?(block) do
          if last_text && continuation?(last_text, block, between) do
            {done, merge_text_blocks(last_text, block), between}
          else
            {flush_pending(done, last_text, between), block, []}
          end
        else
          {done, last_text, between ++ [block]}
        end
      end)

    flush_pending(done, last_text, between)
  end

  defp continuation_pairs(blocks) do
    {_last_text, _between, pairs} =
      Enum.reduce(blocks, {nil, [], []}, fn block,
                                            {last_text, between, pairs} ->
        if text_block?(block) do
          pairs =
            if last_text && continuation?(last_text, block, between),
              do: [{last_text, block} | pairs],
              else: pairs

          {block, [], pairs}
        else
          {last_text, [block | between], pairs}
        end
      end)

    Enum.reverse(pairs)
  end

  defp flush_pending(done, nil, between), do: done ++ between

  defp flush_pending(done, last_text, between),
    do: done ++ [last_text] ++ between

  defp continuation?(previous, following, between) do
    consecutive_pages?(previous, following) and
      same_section_hierarchy?(previous, following) and
      Enum.all?(between, &continuation_furniture?/1) and
      not sentence_terminal?(block_title(previous)) and
      continuation_start?(block_title(following))
  end

  defp consecutive_pages?(previous, following) do
    case {source_page_end(previous), source_page_start(following)} do
      {previous_page, following_page}
      when is_integer(previous_page) and is_integer(following_page) ->
        previous_page + 1 == following_page

      _other ->
        false
    end
  end

  defp text_block?(%{"block_type" => "Text"}), do: true
  defp text_block?(_block), do: false

  defp continuation_furniture?(block) do
    Map.get(block, "block_type") in ~w(PageHeader PageFooter Picture Figure Caption)
  end

  defp same_section_hierarchy?(left, right) do
    Map.get(left, "section_hierarchy", %{}) ==
      Map.get(right, "section_hierarchy", %{})
  end

  defp sentence_terminal?(text) do
    Regex.match?(~r/[.!?][\"”’')\]]*$/u, String.trim(text))
  end

  defp continuation_start?(text) do
    Regex.match?(~r/^[\s\"“‘'(\[]*[[:lower:]]/u, text)
  end

  defp merge_text_blocks(previous, following) do
    previous_html = Map.get(previous, "html", "")
    following_html = Map.get(following, "html", "")

    previous
    |> Map.put("html", merge_text_html(previous_html, following_html))
    |> Map.put(
      "images",
      Map.merge(
        Map.get(previous, "images", %{}),
        Map.get(following, "images", %{})
      )
    )
    |> Map.put(
      "_reader_source_ids",
      Enum.uniq(source_keys(previous) ++ source_keys(following))
    )
    |> Map.put(
      "_reader_source_pages",
      Enum.uniq(source_pages(previous) ++ source_pages(following))
    )
  end

  defp merge_text_html(previous, following) do
    previous = Regex.replace(~r/\s*<\/p>\s*$/i, previous, "")
    following = Regex.replace(~r/^\s*<p(?:\s[^>]*)?>\s*/i, following, "")

    if String.ends_with?(String.trim_trailing(previous), "-") do
      String.trim_trailing(previous)
      |> String.trim_trailing("-")
      |> Kernel.<>(String.trim_leading(following))
    else
      String.trim_trailing(previous) <> " " <> String.trim_leading(following)
    end
  end

  defp source_page_start(block) do
    case Map.get(block, "_reader_source_pages") do
      [page | _rest] -> page
      _other -> source_page(block)
    end
  end

  defp source_pages(block) do
    case Map.get(block, "_reader_source_pages") do
      pages when is_list(pages) -> pages
      _other -> List.wrap(source_page(block))
    end
    |> Enum.reject(&is_nil/1)
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

  defp decode_html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end
end
