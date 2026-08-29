defmodule Sheaf.Document.Markdown do
  @moduledoc """
  Renders a complete Sheaf document graph as portable Markdown.

  The renderer follows the graph's ordered block hierarchy and translates
  Datalab HTML fragments, including LaTeX stored in `math` elements, rather
  than flattening the document to its search text.
  """

  alias RDF.Graph
  alias Sheaf.Document

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Renders an already fetched document graph as a complete Markdown document.
  """
  def render(%Graph{} = graph, root, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    title = metadata[:title] || Document.title(graph, root)
    children = Document.children(graph, root)
    footnotes_by_page = footnotes_by_page(graph, root)

    Tracer.with_span "Sheaf.Document.Markdown.render", %{
      kind: :internal,
      attributes: [
        {"sheaf.document", to_string(root)},
        {"sheaf.document.kind", to_string(Document.kind(graph, root))},
        {"sheaf.statement_count", RDF.Data.statement_count(graph)},
        {"sheaf.root_block_count", length(children)}
      ]
    } do
      body = render_blocks(children, graph, 0, footnotes_by_page)

      markdown =
        [
          "# #{heading_text(title)}",
          metadata_line(metadata),
          body
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join("\n\n")
        |> normalize_document()

      Tracer.set_attribute("sheaf.markdown.bytes", byte_size(markdown))
      markdown
    end
  end

  defp render_blocks(blocks, graph, depth, footnotes_by_page) do
    blocks
    |> Enum.map(&render_block(&1, graph, depth, footnotes_by_page))
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp render_block(iri, graph, depth, footnotes_by_page) do
    case Document.block_type(graph, iri) do
      :section ->
        heading = String.duplicate("#", min(depth + 2, 6))

        children =
          graph
          |> Document.children(iri)
          |> render_blocks(graph, depth + 1, footnotes_by_page)

        Enum.join(
          [
            "#{heading} #{heading_text(Document.heading(graph, iri))}",
            children
          ],
          "\n\n"
        )

      :paragraph ->
        render_paragraph(graph, iri)

      :extracted ->
        render_extracted(graph, iri, footnotes_by_page)

      :row ->
        Document.text(graph, iri) |> plain_block()

      type when type in [:source_directory, :source_file] ->
        heading = String.duplicate("#", min(depth + 2, 6))

        children =
          graph
          |> Document.children(iri)
          |> render_blocks(graph, depth + 1, footnotes_by_page)

        Enum.join(
          [
            "#{heading} #{heading_text(Document.heading(graph, iri))}",
            children
          ],
          "\n\n"
        )

      :source_file_block ->
        Document.text(graph, iri) |> plain_block()

      _other ->
        ""
    end
  end

  defp render_paragraph(graph, iri) do
    body =
      case Document.paragraph_markup(graph, iri) do
        nil -> Document.paragraph_text(graph, iri) |> plain_block()
        markup -> html_fragment(markup)
      end

    definitions =
      graph
      |> Document.footnotes(iri)
      |> Enum.map_join("\n", fn footnote ->
        marker = footnote_marker(footnote)
        content = html_fragment(footnote.markup || footnote.text)
        "[^#{marker}]: #{indent_continuation(content)}"
      end)

    [body, definitions]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp render_extracted(graph, iri, footnotes_by_page) do
    html = Document.source_html(graph, iri)

    footnote_markers =
      Map.get(
        footnotes_by_page,
        Document.source_page(graph, iri),
        MapSet.new()
      )

    case Document.source_block_type(graph, iri) do
      "Equation" -> render_equation(html, footnote_markers)
      "Table" -> render_table(html, footnote_markers)
      "ListGroup" -> render_list(html, footnote_markers)
      "Footnote" -> render_extracted_footnote(html)
      "Figure" -> render_figure(html)
      "Picture" -> render_figure(html)
      _other -> html_fragment(html, footnote_markers)
    end
  end

  defp render_equation(html, footnote_markers) do
    html_fragment(html, footnote_markers)
  end

  defp render_list(html, footnote_markers) do
    {_protected, math} = extract_math(html)

    items =
      Regex.scan(~r/<li\b[^>]*>(.*?)<\/li>/is, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(fn item ->
        item
        |> html_fragment(footnote_markers)
        |> String.replace(~r/^\s*[•‣◦]\s*/u, "")
        |> indent_continuation()
        |> then(&("- " <> &1))
      end)

    case items do
      [] -> restore_math(html_fragment(html, footnote_markers), math)
      _items -> Enum.join(items, "\n")
    end
  end

  defp render_table(html, footnote_markers) do
    rows =
      Regex.scan(~r/<tr\b[^>]*>(.*?)<\/tr>/is, html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&table_row(&1, footnote_markers))
      |> Enum.reject(&(elem(&1, 0) == []))
      |> table_grid()

    case rows do
      [] -> html_fragment(html)
      _rows -> markdown_table(rows)
    end
  end

  defp table_row(row, footnote_markers) do
    cells =
      Regex.scan(~r/<t(h|d)\b([^>]*)>(.*?)<\/t(?:h|d)>/is, row)
      |> Enum.map(fn [_whole, kind, attrs, content] ->
        %{
          content:
            content
            |> html_fragment(footnote_markers)
            |> String.replace("|", "\\|")
            |> String.replace(~r/\s*\n\s*/, "<br>"),
          colspan: span_value(attrs, "colspan"),
          rowspan: span_value(attrs, "rowspan"),
          header?: String.downcase(kind) == "h"
        }
      end)

    {cells, Enum.any?(cells, & &1.header?)}
  end

  defp table_grid(rows) do
    {rows, _active} =
      Enum.map_reduce(rows, %{}, fn {cells, header?}, active ->
        occupied =
          Map.new(active, fn {column, {_remaining, content}} ->
            {column, content}
          end)

        carried =
          active
          |> Enum.flat_map(fn
            {column, {remaining, content}} when remaining > 1 ->
              [{column, {remaining - 1, content}}]

            _expired ->
              []
          end)
          |> Map.new()

        {values, active} = place_cells(cells, occupied, carried, 0)
        max_column = values |> Map.keys() |> Enum.max(fn -> -1 end)

        row =
          if max_column < 0,
            do: [],
            else: Enum.map(0..max_column, &Map.get(values, &1, ""))

        {{row, header?}, active}
      end)

    rows
  end

  defp place_cells([], values, active, _column), do: {values, active}

  defp place_cells([cell | rest], values, active, column) do
    column = next_open_column(values, column)
    columns = column..(column + cell.colspan - 1)
    values = Enum.reduce(columns, values, &Map.put(&2, &1, cell.content))

    active =
      if cell.rowspan > 1 do
        Enum.reduce(
          columns,
          active,
          &Map.put(&2, &1, {cell.rowspan - 1, cell.content})
        )
      else
        active
      end

    place_cells(rest, values, active, column + cell.colspan)
  end

  defp next_open_column(values, column) do
    if Map.has_key?(values, column),
      do: next_open_column(values, column + 1),
      else: column
  end

  defp span_value(attrs, name) do
    case Regex.run(~r/#{name}\s*=\s*["']?(\d+)/i, attrs) do
      [_match, value] -> max(String.to_integer(value), 1)
      _other -> 1
    end
  end

  defp markdown_table(rows) do
    width =
      rows |> Enum.map(fn {row, _header?} -> length(row) end) |> Enum.max()

    rows =
      Enum.map(rows, fn {row, header?} -> {pad_row(row, width), header?} end)

    {header_rows, body} = Enum.split_while(rows, &elem(&1, 1))

    {header, body} =
      case header_rows do
        [] -> {List.duplicate("", width), rows}
        rows -> {merge_header_rows(rows, width), body}
      end

    separator = List.duplicate("---", width)
    body = Enum.map(body, &elem(&1, 0))

    [header, separator | body]
    |> Enum.map_join("\n", fn row -> "| " <> Enum.join(row, " | ") <> " |" end)
  end

  defp merge_header_rows(rows, width) do
    Enum.map(0..(width - 1), fn column ->
      rows
      |> Enum.map(fn {row, _header?} -> Enum.at(row, column) end)
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()
      |> Enum.join("<br>")
    end)
  end

  defp pad_row(row, width), do: row ++ List.duplicate("", width - length(row))

  defp render_figure(html) do
    description =
      case Regex.run(
             ~r/<div\b[^>]*class="[^"]*(?:img-alt|img-description)[^"]*"[^>]*>(.*?)<\/div>/is,
             html
           ) do
        [_match, text] -> html_fragment(text)
        _other -> nil
      end

    if blank?(description),
      do: "*[Figure omitted]*",
      else: "*[Figure: #{description}]*"
  end

  defp render_extracted_footnote(html) do
    case Regex.run(
           ~r/^\s*<p\b[^>]*>\s*<sup\b[^>]*>([^<]+)<\/sup>(.*?)<\/p>\s*$/is,
           html
         ) do
      [_match, marker, content] ->
        "[^#{clean_fragment(marker)}]: #{content |> html_fragment() |> indent_continuation()}"

      _other ->
        html_fragment(html)
    end
  end

  defp html_fragment(html, footnote_markers \\ MapSet.new())

  defp html_fragment(nil, _footnote_markers), do: ""

  defp html_fragment(html, footnote_markers) do
    {html, math} = extract_math(to_string(html))

    html
    |> replace_footnote_markers()
    |> replace_links()
    |> String.replace(
      ~r/<(?:strong|b)\b[^>]*>(.*?)<\/(?:strong|b)>/is,
      "**\\1**"
    )
    |> String.replace(~r/<(?:em|i)\b[^>]*>(.*?)<\/(?:em|i)>/is, "*\\1*")
    |> String.replace(~r/<code\b[^>]*>(.*?)<\/code>/is, "`\\1`")
    |> replace_numeric_footnote_markers(footnote_markers)
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p\s*>/i, "\n\n")
    |> String.replace(~r/<p\b[^>]*>/i, "")
    |> String.replace(~r/<sup\b[^>]*>(.*?)<\/sup>/is, "<sup>\\1</sup>")
    |> String.replace(~r/<sub\b[^>]*>(.*?)<\/sub>/is, "<sub>\\1</sub>")
    |> String.replace(~r/<[^>]*>/, " ")
    |> decode_entities()
    |> clean_fragment()
    |> restore_math(math)
  end

  defp extract_math(html) do
    Regex.scan(~r/<math\b([^>]*)>(.*?)<\/math>/is, html)
    |> Enum.with_index()
    |> Enum.reduce({html, %{}}, fn {[whole, attrs, expression], index},
                                   {text, math} ->
      token = "SHEAFMATHTOKEN#{index}END"
      expression = expression |> decode_entities() |> String.trim()

      markdown =
        if String.match?(attrs, ~r/display\s*=\s*["']block["']/i) do
          "$$\n#{expression}\n$$"
        else
          "$#{expression}$"
        end

      {String.replace(text, whole, token, global: false),
       Map.put(math, token, markdown)}
    end)
  end

  defp restore_math(text, math) do
    Enum.reduce(math, text, fn {token, expression}, text ->
      String.replace(text, token, expression)
    end)
  end

  defp replace_links(html) do
    Regex.replace(
      ~r/<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/is,
      html,
      fn _match, href, label ->
        "[#{label}](#{href})"
      end
    )
  end

  defp replace_footnote_markers(html) do
    Regex.replace(
      ~r/<span\b[^>]*data-footnote=["']([^"']+)["'][^>]*>.*?<\/span>/is,
      html,
      fn _match, marker -> "[^#{marker}]" end
    )
  end

  defp replace_numeric_footnote_markers(html, footnote_markers) do
    Regex.replace(
      ~r/(^|[\p{L}\p{N}\p{Pe}.,;:!?…"'”’])<sup\b[^>]*>\s*(\d+)\s*<\/sup>(?=$|[<\s,.;:!?…\p{Pe}])/isu,
      html,
      fn _whole, prefix, marker ->
        if MapSet.member?(footnote_markers, marker),
          do: "#{prefix}[^#{marker}]",
          else: prefix <> marker
      end
    )
  end

  defp footnotes_by_page(graph, root) do
    graph
    |> Document.text_chunks(root)
    |> Enum.filter(&(&1.source_type == "Footnote"))
    |> Enum.reduce(%{}, fn footnote, pages ->
      case extracted_footnote_marker(
             Document.source_html(graph, footnote.iri)
           ) do
        nil ->
          pages

        marker ->
          Map.update(
            pages,
            footnote.source_page,
            MapSet.new([marker]),
            &MapSet.put(&1, marker)
          )
      end
    end)
  end

  defp extracted_footnote_marker(html) do
    case Regex.run(~r/^\s*<p\b[^>]*>\s*<sup\b[^>]*>([^<]+)<\/sup>/is, html) do
      [_match, marker] -> clean_fragment(marker)
      _other -> nil
    end
  end

  defp footnote_marker(%{source_key: source_key, id: id}) do
    case Regex.run(~r/#([^#]+)$/, source_key || "") do
      [_match, marker] -> marker
      _other -> id
    end
  end

  defp indent_continuation(text) do
    String.replace(text, "\n", "\n  ")
  end

  defp plain_block(text), do: text |> to_string() |> clean_fragment()

  defp clean_fragment(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(~r/[\t ]+/, " ")
    |> String.replace(~r/ *\n */, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(text) do
    Regex.replace(~r/&#(x[0-9a-f]+|[0-9]+);/i, text, fn _match, number ->
      base =
        if String.starts_with?(String.downcase(number), "x"), do: 16, else: 10

      digits = if base == 16, do: String.slice(number, 1..-1//1), else: number

      case Integer.parse(digits, base) do
        {codepoint, ""} -> <<codepoint::utf8>>
        _other -> ""
      end
    end)
  end

  defp metadata_line(metadata) do
    [
      metadata[:source_label],
      metadata[:authors]
      |> List.wrap()
      |> Enum.reject(&blank?/1)
      |> Enum.join(", "),
      metadata[:year],
      metadata[:publisher]
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&inline_text/1)
    |> Enum.join(" · ")
  end

  defp heading_text(text) do
    text
    |> inline_text()
    |> String.replace(~r/^#+\s*/, "")
  end

  defp inline_text(text) do
    text
    |> to_string()
    |> decode_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_document(markdown) do
    markdown
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
