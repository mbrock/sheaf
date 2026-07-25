defmodule SheafWeb.LibraryMarkdown do
  @moduledoc """
  Concise Markdown representations of the library index and static reader.
  """

  alias Sheaf.{Document, Id}

  @doc """
  Renders the readable document index for text clients.
  """
  def index(documents) do
    readable_documents =
      Enum.filter(documents, fn document ->
        document.kind not in [:transcript, :spreadsheet] and
          document.has_document?
      end)

    sections =
      readable_documents
      |> grouped_documents()
      |> Enum.map(fn {folder, folder_documents} ->
        document_section(folder, folder_documents)
      end)

    [
      "# Sheaf library",
      "Follow any link with `Accept: text/markdown` to read its contents.",
      Enum.join(sections, "\n\n")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Renders a whole document as metadata followed by a navigable outline.
  """
  def document(metadata, graph, root) do
    title = metadata.title || "Untitled"

    [
      "# #{heading_text(title)}",
      metadata_line(metadata),
      "## Contents",
      outline_markdown(Document.outline(graph, root))
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Renders one document section or source-tree resource.
  """
  def resource(metadata, graph, iri, type, breadcrumbs) do
    title = metadata.title || "Untitled"
    heading = Document.heading(graph, iri)

    [
      "# #{heading_text(title)}",
      metadata_line(metadata),
      breadcrumb_line(breadcrumbs),
      "## #{heading_text(heading)}",
      resource_body(graph, iri, type)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp document_section(folder, documents) do
    entries = Enum.map(documents, &document_entry/1)
    Enum.join(["## #{heading_text(folder || "Unfiled")}" | entries], "\n")
  end

  defp document_entry(document) do
    details =
      [
        document.metadata[:authors]
        |> List.wrap()
        |> Enum.reject(&blank?/1)
        |> Enum.join(", "),
        document.metadata[:year],
        document.micro_abstract
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.map(&inline_text/1)
      |> Enum.join(" — ")

    suffix = if details == "", do: "", else: " — " <> details
    "- #{link(document.title, document.id)}#{suffix}"
  end

  defp grouped_documents(documents) do
    documents
    |> Enum.group_by(&Map.get(&1, :folder))
    |> Enum.map(fn {folder, folder_documents} ->
      {folder, Enum.sort_by(folder_documents, &sort_title/1)}
    end)
    |> Enum.sort_by(fn {folder, folder_documents} ->
      {is_nil(folder), String.downcase(folder || ""),
       folder_documents |> List.first() |> sort_title()}
    end)
  end

  defp sort_title(nil), do: ""
  defp sort_title(document), do: String.downcase(document.title)

  defp outline_markdown([]), do: "No contents available."
  defp outline_markdown(entries), do: outline_markdown(entries, 0)

  defp outline_markdown(entries, depth) do
    Enum.map_join(entries, "\n", fn entry ->
      title = numbered_title(entry)
      children = outline_markdown(Map.get(entry, :children, []), depth + 1)
      line = "#{String.duplicate("  ", depth)}- #{link(title, entry.id)}"

      if children == "", do: line, else: line <> "\n" <> children
    end)
  end

  defp numbered_title(entry) do
    number =
      entry
      |> Map.get(:number, [])
      |> Enum.join(".")

    [number, Map.get(entry, :title)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp resource_body(graph, iri, :section) do
    graph
    |> Document.children(iri)
    |> Enum.map(&resource_child(graph, &1))
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> empty_body()
  end

  defp resource_body(graph, iri, :paragraph),
    do: graph |> Document.paragraph_text(iri) |> block_text() |> empty_body()

  defp resource_body(graph, iri, :extracted) do
    text =
      case Document.text(graph, iri) do
        "" -> Document.inline_markup_text(Document.source_html(graph, iri))
        text -> text
      end

    text |> block_text() |> empty_body()
  end

  defp resource_body(graph, iri, :row),
    do: graph |> Document.text(iri) |> block_text() |> empty_body()

  defp resource_body(graph, iri, type)
       when type in [:source_directory, :source_file] do
    graph
    |> Document.children(iri)
    |> Enum.map(&resource_child(graph, &1))
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> empty_body()
  end

  defp resource_body(_graph, _iri, _type),
    do: "No readable content available."

  defp resource_child(graph, iri) do
    case Document.block_type(graph, iri) do
      type when type in [:section, :source_directory, :source_file] ->
        "### #{link(Document.heading(graph, iri), Document.id(iri))}"

      type ->
        resource_body(graph, iri, type)
    end
  end

  defp breadcrumb_line([]), do: nil

  defp breadcrumb_line(breadcrumbs) do
    breadcrumbs
    |> Enum.map(&link(&1.title, &1.id))
    |> Enum.join(" › ")
  end

  defp metadata_line(metadata) do
    [
      metadata.source_label,
      metadata.authors |> Enum.reject(&blank?/1) |> Enum.join(", "),
      metadata.year,
      metadata.publisher
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&inline_text/1)
    |> Enum.join(" · ")
  end

  defp link(title, id) do
    "[#{escape_link_text(title)}](#{read_url(id)})"
  end

  defp read_url(id) do
    base = URI.parse(Id.base_iri())

    base
    |> Map.put(:path, "/read/#{URI.encode(id, &URI.char_unreserved?/1)}")
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp escape_link_text(text) do
    text
    |> inline_text()
    |> String.replace("\\", "\\\\")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp heading_text(text) do
    text
    |> inline_text()
    |> String.replace(~r/^#+\s*/, "")
  end

  defp inline_text(text) do
    text
    |> to_string()
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp block_text(text) do
    text
    |> to_string()
    |> String.replace("\r\n", "\n")
    |> String.trim()
  end

  defp empty_body(""), do: "No readable content available."
  defp empty_body(body), do: body

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
