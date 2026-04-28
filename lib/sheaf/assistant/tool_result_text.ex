defmodule Sheaf.Assistant.ToolResultText do
  @moduledoc """
  Text renderings for assistant tool results.

  These are intentionally designed as compact reading notes for a model, not as
  API payloads.
  """

  alias Sheaf.Assistant.ToolResults.{
    Block,
    Blocks,
    Child,
    Coding,
    Document,
    DocumentSummary,
    ListDocuments,
    Note,
    OutlineEntry,
    SearchHit,
    SearchResults,
    Spreadsheet,
    SpreadsheetQuery,
    SpreadsheetSearch,
    SpreadsheetSheet,
    ListSpreadsheets
  }

  def to_text(%ListDocuments{documents: documents}) do
    documents
    |> grouped_documents()
    |> Enum.map(fn {group, documents} -> document_group_text(group, documents) end)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  def to_text(%Document{} = document) do
    """
    #{document_heading(document.kind)} ##{document.id}
    Title: #{document.title}

    Outline:
    #{outline_lines(document.outline)}
    """
    |> String.trim()
  end

  def to_text(%Block{type: :document} = block) do
    """
    #{document_heading(block.kind)} ##{block.id}
    Title: #{block.title}

    Outline:
    #{outline_lines(block.outline)}
    """
    |> String.trim()
  end

  def to_text(%Block{type: :section} = block) do
    """
    SECTION ##{block.id}
    Document: #{document_line(block)}
    Context:
    #{context_lines(block.ancestry)}

    Children:
    #{children_lines(block.children)}
    """
    |> String.trim()
  end

  def to_text(%Block{type: :paragraph} = block) do
    """
    THESIS PARAGRAPH ##{block.id}
    Document: #{document_line(block)}
    Context:
    #{context_lines(block.ancestry)}

    #{block.text}
    """
    |> String.trim()
  end

  def to_text(%Block{type: :extracted} = block) do
    """
    PAPER EXCERPT ##{block.id}
    Document: #{document_line(block)}
    Context:
    #{context_lines(block.ancestry)}

    #{block.text}
    """
    |> String.trim()
  end

  def to_text(%Block{type: :row} = block) do
    """
    CODED EXCERPT ##{block.id}
    Document: #{document_line(block)}
    Context:
    #{context_lines(block.ancestry)}
    #{coding_text(block.coding)}

    #{block.text}
    """
    |> String.trim()
  end

  def to_text(%Blocks{expanded?: true, blocks: blocks}) do
    blocks
    |> Enum.map(&expanded_block_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  def to_text(%Blocks{blocks: blocks}) do
    blocks
    |> Enum.map(&to_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  def to_text(%SearchResults{} = results) do
    [
      search_section("Exact matches", results.exact_results, :exact),
      search_section("Approximate matches", results.approximate_results, :approximate)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  def to_text(%ListSpreadsheets{spreadsheets: spreadsheets}) do
    spreadsheets
    |> Enum.map(&spreadsheet_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  def to_text(%SpreadsheetQuery{} = result) do
    """
    SPREADSHEET QUERY
    SQL: #{result.sql}
    Columns: #{Enum.join(result.columns, ", ")}

    #{json_rows(result.rows)}
    """
    |> String.trim()
  end

  def to_text(%SpreadsheetSearch{} = result) do
    """
    SPREADSHEET SEARCH
    Query: #{result.query}

    #{json_rows(result.hits)}
    """
    |> String.trim()
  end

  def to_text(%Note{} = note) do
    """
    NOTE SAVED ##{note.id}
    IRI: #{note.iri}
    """
    |> String.trim()
  end

  def selected_block_text(%Block{} = block) do
    [
      selected_block_heading(block),
      selected_block_context(block),
      selected_block_coding(block),
      selected_block_body(block)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp grouped_documents(documents) do
    owner_documents = Enum.filter(documents, & &1.workspace_owner_authored?)
    library_documents = Enum.reject(documents, & &1.workspace_owner_authored?)

    owner_group =
      case owner_documents do
        [] -> []
        docs -> [{nil, Enum.sort_by(docs, &document_sort_key/1)}]
      end

    library_groups =
      library_documents
      |> Enum.group_by(&document_group/1)
      |> Enum.map(fn {kind, docs} -> {kind, Enum.sort_by(docs, &document_sort_key/1)} end)
      |> Enum.sort_by(fn {kind, docs} ->
        {kind_order(kind), kind_label(kind), first_title(docs)}
      end)

    owner_group ++ library_groups
  end

  defp document_group_text(nil, documents),
    do: Enum.map_join(documents, "\n", &document_summary_line/1)

  defp document_group_text(group, documents) do
    """
    #{kind_label(group)} (#{length(documents)})
    #{Enum.map_join(documents, "\n", &document_summary_line/1)}
    """
    |> String.trim()
  end

  defp spreadsheet_text(%Spreadsheet{} = spreadsheet) do
    """
    SPREADSHEET #{spreadsheet.id}
    Title: #{spreadsheet.title}
    Path: #{spreadsheet.path}

    Sheets:
    #{Enum.map_join(spreadsheet.sheets, "\n", &spreadsheet_sheet_line/1)}
    """
    |> String.trim()
  end

  defp spreadsheet_sheet_line(%SpreadsheetSheet{} = sheet) do
    columns =
      sheet.columns
      |> Enum.map(fn
        %{"name" => name, "header" => header} when name != header -> "#{name} (#{header})"
        %{"name" => name} -> name
        %{name: name, header: header} when name != header -> "#{name} (#{header})"
        %{name: name} -> name
        other -> to_string(other)
      end)
      |> Enum.join(", ")

    "  - #{sheet.table_name} \"#{sheet.name}\" rows=#{sheet.row_count} cols=#{sheet.col_count} columns=[#{columns}]"
  end

  defp document_sort_key(document),
    do: {kind_order(document_group(document)), String.downcase(document.title || "")}

  defp document_group(%DocumentSummary{metadata_kind: kind}) when is_binary(kind),
    do: {:expression, kind}

  defp document_group(%DocumentSummary{kind: kind}), do: kind

  defp first_title([document | _documents]), do: String.downcase(document.title || "")
  defp first_title([]), do: ""

  defp kind_label({:expression, kind}), do: pluralize_expression_kind(kind)
  defp kind_label(:thesis), do: "Thesis"
  defp kind_label(:paper), do: "Papers"
  defp kind_label(:document), do: "Documents"
  defp kind_label(kind) when is_atom(kind), do: kind |> Atom.to_string() |> String.capitalize()

  defp pluralize_expression_kind("Book"), do: "Books"
  defp pluralize_expression_kind("Book chapter"), do: "Book chapters"
  defp pluralize_expression_kind("Doctoral thesis"), do: "Doctoral theses"
  defp pluralize_expression_kind("Journal article"), do: "Journal articles"
  defp pluralize_expression_kind("Report document"), do: "Reports"
  defp pluralize_expression_kind(kind), do: kind <> "s"

  defp kind_order(:thesis), do: 0
  defp kind_order({:expression, "Journal article"}), do: 1
  defp kind_order({:expression, "Book"}), do: 2
  defp kind_order({:expression, "Book chapter"}), do: 3
  defp kind_order({:expression, "Doctoral thesis"}), do: 4
  defp kind_order({:expression, "Report document"}), do: 5
  defp kind_order({:expression, _kind}), do: 6
  defp kind_order(:paper), do: 6
  defp kind_order(:document), do: 9
  defp kind_order(_kind), do: 10

  defp document_summary_line(%DocumentSummary{} = doc) do
    details =
      [
        doc.year,
        authors(doc.authors),
        document_publication(doc),
        page_count(doc.page_count),
        doi(doc.doi)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" | ")

    suffix = if details == "", do: "", else: " - " <> details
    badges = document_badges(doc)
    "- ##{doc.id} #{doc.title}#{badges}#{suffix}"
  end

  defp document_badges(doc) do
    [
      if(doc.cited?, do: "cited"),
      if(doc.status == "draft", do: "draft")
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> ""
      badges -> " [" <> Enum.join(badges, ", ") <> "]"
    end
  end

  defp document_publication(%DocumentSummary{metadata_kind: "Book chapter"} = doc) do
    [doc.venue, doc.publisher, pages(doc.pages)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp document_publication(%DocumentSummary{venue: venue}), do: venue

  defp document_heading(:thesis), do: "THESIS"
  defp document_heading(:paper), do: "DOCUMENT"
  defp document_heading(:transcript), do: "TRANSCRIPT"
  defp document_heading(:spreadsheet), do: "SPREADSHEET"
  defp document_heading(_), do: "DOCUMENT"

  defp outline_lines([]), do: "  (no outline)"

  defp outline_lines(outline) do
    outline
    |> Enum.flat_map(&outline_entry_lines(&1, 1))
    |> Enum.join("\n")
  end

  defp outline_entry_lines(%OutlineEntry{} = entry, level) do
    label =
      [entry.number, "##{entry.id}", entry.title] |> Enum.reject(&blank?/1) |> Enum.join(" ")

    line = indent(level) <> "- " <> label

    [line | Enum.flat_map(entry.children, &outline_entry_lines(&1, level + 1))]
  end

  defp context_lines([]), do: "  (no context)"

  defp context_lines(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> context_line(entry, index) end)
    |> Enum.join("\n")
  end

  defp context_line(entry, index) do
    indent(index + 1) <> context_label(entry)
  end

  defp context_label(entry) do
    title =
      case entry.title do
        nil -> type_label(entry.type)
        "" -> type_label(entry.type)
        title -> title
      end

    "##{entry.id} " <> title
  end

  defp children_lines([]), do: "  (no children)"

  defp children_lines(children) do
    children
    |> Enum.map(&child_line/1)
    |> Enum.join("\n")
  end

  defp child_line(%Child{} = child) do
    label =
      [type_label(child.type), child.title]
      |> Enum.reject(&blank?/1)
      |> Enum.join(": ")

    preview = if blank?(child.preview), do: "", else: " - " <> child.preview

    "  - ##{child.id} #{label}#{preview}"
  end

  defp search_section(_title, [], _mode), do: nil

  defp search_section(title, hits, mode) do
    lines =
      hits
      |> Enum.with_index(1)
      |> Enum.map(fn {hit, index} -> search_hit_lines(hit, index, mode) end)
      |> Enum.join("\n\n")

    """
    #{title}

    #{lines}
    """
    |> String.trim()
  end

  defp search_hit_lines(%SearchHit{} = hit, index, mode) do
    label = search_hit_label(hit.kind, mode)
    source = source_line(hit)
    coding = coding_inline(hit.coding)
    score = if mode == :approximate, do: score(hit.score), else: nil
    context = search_context(hit.context)

    [
      "#{index}. #{source}",
      indent_multiline(context, 1),
      line(coding, 1),
      line(score, 1),
      "#{indent(1)}#{label} ##{hit.block_id}:",
      indent_text(hit.text, 3)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp expanded_block_text(%Block{type: :document} = block) do
    """
    #{document_heading(block.kind)} ##{block.id}
    #{block.title}
    """
    |> String.trim()
  end

  defp expanded_block_text(%Block{type: :section} = block) do
    "SECTION ##{block.id} #{block.title}"
  end

  defp expanded_block_text(%Block{type: :paragraph} = block) do
    """
    PARAGRAPH ##{block.id}
    #{indent_text(block.text, 1)}
    """
    |> String.trim()
  end

  defp expanded_block_text(%Block{type: :extracted} = block) do
    source = expanded_source(block)

    """
    EXCERPT ##{block.id}#{source}
    #{indent_text(block.text, 1)}
    """
    |> String.trim()
  end

  defp expanded_block_text(%Block{type: :row} = block) do
    coding =
      case coding_inline(block.coding) do
        nil -> ""
        text -> " [" <> text <> "]"
      end

    """
    CODED EXCERPT ##{block.id}#{coding}
    #{indent_text(block.text, 1)}
    """
    |> String.trim()
  end

  defp expanded_source(%Block{source: %{page: page}}) when not is_nil(page), do: " p. #{page}"
  defp expanded_source(_block), do: ""

  defp selected_block_heading(%Block{} = block) do
    "The user has selected #{type_label(block.type)} ##{block.id}:"
  end

  defp selected_block_context(%Block{ancestry: ancestry, id: id}) do
    entries =
      Enum.reject(ancestry, fn
        %{type: :document} -> true
        %{id: ^id} -> true
        _entry -> false
      end)

    case entries do
      [] -> nil
      entries -> "  Context:\n" <> selected_context_lines(entries)
    end
  end

  defp selected_context_lines(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> indent(index + 2) <> context_label(entry) end)
    |> Enum.join("\n")
  end

  defp selected_block_coding(%Block{type: :row, coding: %Coding{} = coding}) do
    case coding_inline(coding) do
      nil -> nil
      text -> "  Coding: " <> text
    end
  end

  defp selected_block_coding(_block), do: nil

  defp selected_block_body(%Block{type: :section, children: children}) do
    "  Children:\n" <> indent_multiline(children_lines(children), 1)
  end

  defp selected_block_body(%Block{text: text}) when not is_nil(text) do
    "  Text:\n" <> indent_text(text, 2)
  end

  defp selected_block_body(_block), do: nil

  defp document_line(%Block{document_id: id, ancestry: [%{id: id, title: title} | _]}),
    do: "##{id} #{title}"

  defp document_line(%Block{document_id: id}), do: "##{id}"

  defp coding_text(nil), do: ""

  defp coding_text(%Coding{} = coding) do
    lines =
      [
        {"Source", source_row(coding)},
        {"Code", code_label(coding)}
      ]
      |> Enum.reject(fn {_label, value} -> blank?(value) end)
      |> Enum.map(fn {label, value} -> "  #{label}: #{value}" end)
      |> Enum.join("\n")

    if lines == "", do: "", else: "\nCoding:\n" <> lines
  end

  defp coding_inline(nil), do: nil

  defp coding_inline(%Coding{} = coding) do
    [source_row(coding), code_label(coding)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" | ")
  end

  defp source_row(%Coding{source: source, row: row}) when not is_nil(row) do
    [source, "row #{row}"] |> Enum.reject(&blank?/1) |> Enum.join(", ")
  end

  defp source_row(%Coding{source: source}), do: source

  defp code_label(%Coding{category: category, category_title: title}) do
    [category, title] |> Enum.reject(&blank?/1) |> Enum.join(" - ")
  end

  defp authors([]), do: nil
  defp authors(nil), do: nil
  defp authors(authors), do: Enum.join(authors, ", ")

  defp page_count(nil), do: nil
  defp page_count(count), do: "#{count} pp."

  defp pages(nil), do: nil
  defp pages(""), do: nil
  defp pages(pages), do: "pp. #{pages}"

  defp doi(nil), do: nil
  defp doi(""), do: nil
  defp doi(doi), do: "doi:#{doi}"

  defp score(nil), do: nil
  defp score(score) when is_float(score), do: "Score: #{Float.round(score, 3)}"
  defp score(score), do: "Score: #{score}"

  defp source_line(%SearchHit{} = hit) do
    page = if hit.source_page, do: ", p. #{hit.source_page}", else: ""
    authors = authors(hit.document_authors)
    byline = if blank?(authors), do: "", else: ", #{authors}"
    "Source: #{hit.document_title} (##{hit.document_id})#{byline}#{page}"
  end

  defp search_context([]), do: nil

  defp search_context(context) do
    lines =
      context
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} -> context_line(entry, index) end)
      |> Enum.join("\n")

    "Context:\n" <> lines
  end

  defp search_hit_label(:paragraph, :exact), do: "Matching paragraph"
  defp search_hit_label(:paragraph, :approximate), do: "Related paragraph"
  defp search_hit_label(:extracted, :exact), do: "Matching excerpt"
  defp search_hit_label(:extracted, :approximate), do: "Related excerpt"
  defp search_hit_label(:row, :exact), do: "Matching coded excerpt"
  defp search_hit_label(:row, :approximate), do: "Related coded excerpt"
  defp search_hit_label(kind, :exact), do: "Matching #{type_label(kind)}"
  defp search_hit_label(kind, :approximate), do: "Related #{type_label(kind)}"

  defp indent_text(nil, level), do: indent(level)

  defp indent_text(text, level) do
    prefix = indent(level)

    text
    |> to_string()
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
    |> Enum.join("\n")
  end

  defp indent_multiline(nil, _level), do: nil

  defp indent_multiline(text, level) do
    prefix = indent(level)

    text
    |> String.split("\n")
    |> Enum.map(&(prefix <> &1))
    |> Enum.join("\n")
  end

  defp line(nil, _level), do: nil
  defp line(text, level), do: indent(level) <> text

  defp json_rows([]), do: "(no rows)"

  defp json_rows(rows) do
    rows
    |> Enum.map(&Jason.encode!/1)
    |> Enum.join("\n")
  end

  defp type_label(:paragraph), do: "paragraph"
  defp type_label(:extracted), do: "excerpt"
  defp type_label(:section), do: "section"
  defp type_label(:document), do: "document"
  defp type_label(:row), do: "coded excerpt"
  defp type_label(type) when is_atom(type), do: Atom.to_string(type)
  defp type_label(type), do: to_string(type)

  defp indent(level), do: String.duplicate("  ", level)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false
end
