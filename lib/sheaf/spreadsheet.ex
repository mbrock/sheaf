defmodule Sheaf.Spreadsheet do
  @moduledoc """
  Imports CSV spreadsheet data as a Sheaf document graph.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.NS.DOC

  require RDF.Graph

  NimbleCSV.define(CSV, separator: ",", escape: "\"")

  @expected_headers ["Source", "Category", "Category Title", "Marked Text"]
  @default_title "IEVA coded excerpts"

  def import_file(path, opts \\ []) do
    with {:ok, rows} <- read_rows(path) do
      result =
        rows
        |> build_graph(
          opts
          |> Keyword.put_new(:source_path, path)
        )

      :ok = Sheaf.put_graph(result.document, result.graph)
      {:ok, result}
    end
  end

  def build_graph(rows, opts \\ []) when is_list(rows) do
    mint = Keyword.get(opts, :mint, &Sheaf.mint/0)
    document_iri = opts |> Keyword.get_lazy(:document, mint) |> RDF.iri()
    title = Keyword.get(opts, :title, @default_title)
    source_path = opts |> Keyword.get(:source_path, "") |> present_value()

    source_groups = source_groups(rows)

    sections =
      Enum.map(source_groups, &section_summary(&1, source_path, mint))

    row_summaries = Enum.flat_map(sections, & &1.rows)

    graph =
      RDF.Graph.new([
        {document_iri, RDF.type(), DOC.Spreadsheet},
        {document_iri, RDFS.label(), RDF.literal(title)}
      ])
      |> add_if(document_iri, DOC.sourceKey(), source_path)
      |> add_sections(sections)
      |> add_rows(row_summaries)
      |> add_child_list(document_iri, Enum.map(sections, & &1.iri), mint.())
      |> add_section_child_lists(sections)

    %{
      document: document_iri,
      graph: graph,
      title: title,
      rows: length(rows),
      sources: length(sections)
    }
  end

  def read_rows(path) do
    rows =
      path
      |> File.read!()
      |> CSV.parse_string(skip_headers: false)

    case rows do
      [headers | data_rows] ->
        headers = normalize_headers(headers)

        if headers == @expected_headers do
          {:ok, Enum.map(Enum.with_index(data_rows, 2), &row_from_csv/1)}
        else
          {:error, {:unexpected_headers, headers}}
        end

      [] ->
        {:error, :empty_csv}
    end
  end

  defp row_from_csv({[source, category, category_title, marked_text], line}) do
    %{
      line: line,
      source: source,
      category: category,
      category_title: category_title,
      marked_text: marked_text
    }
  end

  defp source_groups(rows) do
    rows
    |> Enum.reduce({[], %{}}, fn row, {sources, rows_by_source} ->
      sources =
        if Map.has_key?(rows_by_source, row.source) do
          sources
        else
          sources ++ [row.source]
        end

      rows_by_source =
        Map.update(rows_by_source, row.source, [row], &(&1 ++ [row]))

      {sources, rows_by_source}
    end)
    |> then(fn {sources, rows_by_source} ->
      Enum.map(sources, &{&1, Map.fetch!(rows_by_source, &1)})
    end)
  end

  defp section_summary({source, rows}, source_path, mint) do
    section_iri = mint.()
    row_summaries = Enum.map(rows, &row_summary(&1, source_path, mint.()))

    %{
      iri: section_iri,
      source: source,
      source_key: source_key(source_path, "source=#{source}"),
      rows: row_summaries,
      list_iri: mint.()
    }
  end

  defp row_summary(row, source_path, iri) do
    %{
      iri: iri,
      line: row.line,
      source: row.source,
      source_key: source_key(source_path, "row=#{row.line}"),
      category: present_value(row.category),
      category_title: present_value(row.category_title),
      marked_text: row.marked_text
    }
  end

  defp add_sections(%Graph{} = graph, sections) do
    Enum.reduce(sections, graph, fn section, graph ->
      graph
      |> Graph.add({section.iri, RDF.type(), DOC.Section})
      |> Graph.add({section.iri, RDFS.label(), RDF.literal(section.source)})
      |> Graph.add(
        {section.iri, DOC.sourceKey(), RDF.literal(section.source_key)}
      )
      |> Graph.add(
        {section.iri, DOC.spreadsheetSource(), RDF.literal(section.source)}
      )
    end)
  end

  defp add_rows(%Graph{} = graph, rows) do
    Enum.reduce(rows, graph, fn row, graph ->
      graph
      |> Graph.add({row.iri, RDF.type(), DOC.Row})
      |> Graph.add({row.iri, DOC.text(), RDF.literal(row.marked_text)})
      |> Graph.add({row.iri, DOC.sourceKey(), RDF.literal(row.source_key)})
      |> Graph.add(
        {row.iri, DOC.sourceBlockType(), RDF.literal("Spreadsheet row")}
      )
      |> Graph.add({row.iri, DOC.spreadsheetRow(), RDF.literal(row.line)})
      |> Graph.add(
        {row.iri, DOC.spreadsheetSource(), RDF.literal(row.source)}
      )
      |> add_if(row.iri, DOC.codeCategory(), row.category)
      |> add_if(row.iri, DOC.codeCategoryTitle(), row.category_title)
    end)
  end

  defp add_section_child_lists(%Graph{} = graph, sections) do
    Enum.reduce(sections, graph, fn section, graph ->
      add_child_list(
        graph,
        section.iri,
        Enum.map(section.rows, & &1.iri),
        section.list_iri
      )
    end)
  end

  defp add_child_list(%Graph{} = graph, parent_iri, child_iris, list_iri) do
    child_iris
    |> RDF.list(
      graph: Graph.add(graph, {parent_iri, DOC.children(), list_iri}),
      head: list_iri
    )
    |> Map.fetch!(:graph)
  end

  defp add_if(%Graph{} = graph, _subject, _predicate, nil), do: graph

  defp add_if(%Graph{} = graph, subject, predicate, value) do
    Graph.add(graph, {subject, predicate, RDF.literal(value)})
  end

  defp normalize_headers([first | rest]) do
    [String.trim_leading(first, <<0xFEFF::utf8>>) | rest]
  end

  defp source_key(nil, fragment), do: fragment
  defp source_key(source_path, fragment), do: "#{source_path}##{fragment}"

  defp present_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_value(value), do: value
end
