defmodule Sheaf.Document do
  @moduledoc """
  RDF navigation helpers for reader document graphs.

  Works uniformly for any `sheaf:Document` — theses, papers, transcripts —
  since they all share the same block schema (`doc:Section`,
  `doc:ExtractedBlock`, `doc:children` list, etc.).
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{DOC, PROV}

  @doi_pattern ~r/\b10\.\d{4,9}\/[-._;()\/:A-Z0-9]+/i

  def id(iri), do: Id.id_from_iri(iri)

  @doc """
  Fetches a document graph and returns ordered readable text chunks.

  Useful from IEx when inspecting imported papers:

      Sheaf.Document.text_chunks!(paper_iri) |> Enum.take(12)
  """
  def text_chunks(document_iri) do
    document_iri = RDF.iri(document_iri)

    with {:ok, graph} <- Sheaf.fetch_graph(document_iri) do
      {:ok, text_chunks(graph, document_iri)}
    end
  end

  def text_chunks!(document_iri) do
    case text_chunks(document_iri) do
      {:ok, chunks} -> chunks
      {:error, reason} -> raise "could not fetch document text chunks: #{inspect(reason)}"
    end
  end

  @doc """
  Returns ordered readable text chunks from an already fetched document graph.
  """
  def text_chunks(%Graph{} = graph, root) do
    graph
    |> children(root)
    |> Enum.flat_map(&text_chunks_for(graph, &1))
  end

  @doc """
  Fetches the start of a document as plain text.
  """
  def text_preview(document_iri, opts \\ []) do
    document_iri = RDF.iri(document_iri)

    with {:ok, graph} <- Sheaf.fetch_graph(document_iri) do
      {:ok, text_preview(graph, document_iri, opts)}
    end
  end

  def text_preview!(document_iri, opts \\ []) do
    case text_preview(document_iri, opts) do
      {:ok, preview} -> preview
      {:error, reason} -> raise "could not fetch document text preview: #{inspect(reason)}"
    end
  end

  def text_preview(%Graph{} = graph, root, opts) do
    graph
    |> text_chunks(root)
    |> Enum.map_join("\n\n", & &1.text)
    |> String.slice(0, Keyword.get(opts, :chars, 4_000))
  end

  @doc """
  Finds DOI-looking strings in the start of a document.
  """
  def doi_candidates(document_iri, opts \\ []) do
    document_iri = RDF.iri(document_iri)

    with {:ok, graph} <- Sheaf.fetch_graph(document_iri) do
      {:ok, doi_candidates(graph, document_iri, opts)}
    end
  end

  def doi_candidates!(document_iri, opts \\ []) do
    case doi_candidates(document_iri, opts) do
      {:ok, candidates} -> candidates
      {:error, reason} -> raise "could not fetch DOI candidates: #{inspect(reason)}"
    end
  end

  def doi_candidates(%Graph{} = graph, root, opts) do
    graph
    |> text_preview(root, opts)
    |> doi_candidates_from_text()
  end

  def title(%Graph{} = graph, iri) do
    value(graph, iri, RDFS.label(), "Untitled thesis")
  end

  def kind(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    cond do
      typed?(description, DOC.Thesis) -> :thesis
      typed?(description, DOC.Transcript) -> :transcript
      typed?(description, DOC.Paper) -> :paper
      true -> :document
    end
  end

  def children(%Graph{} = graph, iri) do
    case object(graph, iri, DOC.children()) do
      nil -> []
      list_iri -> list_values(graph, list_iri)
    end
  end

  @doc """
  Returns the section table of contents for a document graph.

  Non-section blocks are ignored. Section numbering follows the rendered reader:
  only sibling sections increment the section number.
  """
  def toc(%Graph{} = graph, root) do
    graph
    |> children(root)
    |> toc_entries(graph, [])
  end

  def block_type(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    cond do
      typed?(description, DOC.Section) -> :section
      typed?(description, DOC.ParagraphBlock) -> :paragraph
      typed?(description, DOC.ExtractedBlock) -> :extracted
      true -> nil
    end
  end

  def heading(%Graph{} = graph, iri) do
    value(graph, iri, RDFS.label(), "Untitled section")
  end

  def paragraph_text(%Graph{} = graph, iri) do
    case active_paragraph_iri(graph, iri) do
      nil -> ""
      paragraph_iri -> value(graph, paragraph_iri, DOC.text(), "")
    end
  end

  def source_html(%Graph{} = graph, iri) do
    value(graph, iri, DOC.sourceHtml(), "")
  end

  def source_key(%Graph{} = graph, iri) do
    value(graph, iri, DOC.sourceKey(), "")
  end

  def source_block_type(%Graph{} = graph, iri) do
    value(graph, iri, DOC.sourceBlockType(), "")
  end

  def source_page(%Graph{} = graph, iri) do
    case object(graph, iri, DOC.sourcePage()) do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp text_chunks_for(%Graph{} = graph, iri) do
    chunk = text_chunk(graph, iri)
    child_chunks = graph |> children(iri) |> Enum.flat_map(&text_chunks_for(graph, &1))

    case chunk do
      nil -> child_chunks
      %{text: ""} -> child_chunks
      chunk -> [chunk | child_chunks]
    end
  end

  defp text_chunk(%Graph{} = graph, iri) do
    case block_type(graph, iri) do
      :section ->
        chunk(graph, iri, :section, heading(graph, iri))

      :paragraph ->
        chunk(graph, iri, :paragraph, paragraph_text(graph, iri))

      :extracted ->
        chunk(graph, iri, :extracted, plain_text(source_html(graph, iri)))

      _other ->
        nil
    end
  end

  defp chunk(graph, iri, type, text) do
    %{
      id: id(iri),
      iri: iri,
      source_key: source_key(graph, iri),
      source_page: source_page(graph, iri),
      source_type: source_block_type(graph, iri),
      text: text |> to_string() |> normalize_text(),
      type: type
    }
  end

  defp active_paragraph_iri(%Graph{} = graph, iri) do
    graph
    |> Graph.description(iri)
    |> DOC.paragraph()
    |> Enum.find(&(not invalidated?(graph, &1)))
  end

  defp invalidated?(%Graph{} = graph, iri) do
    graph
    |> Graph.description(iri)
    |> PROV.was_invalidated_by()
    |> is_list()
  end

  defp toc_entries(iris, graph, prefix) do
    iris
    |> Enum.reduce({[], 0}, fn iri, {entries, section_index} ->
      case block_type(graph, iri) do
        :section ->
          number = prefix ++ [section_index + 1]
          entry = toc_entry(graph, iri, number)

          {[entry | entries], section_index + 1}

        _other ->
          {entries, section_index}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp toc_entry(graph, iri, number) do
    %{
      iri: iri,
      id: id(iri),
      title: heading(graph, iri),
      number: number,
      children: graph |> children(iri) |> toc_entries(graph, number)
    }
  end

  defp object(%Graph{} = graph, iri, property) do
    graph
    |> Graph.description(iri)
    |> Description.first(property)
  end

  defp value(%Graph{} = graph, iri, property, default) do
    case object(graph, iri, property) do
      nil -> default
      term -> term |> RDF.Term.value() |> to_string()
    end
  end

  defp typed?(%Description{} = description, type) do
    Description.include?(description, {RDF.type(), type})
  end

  defp doi_candidates_from_text(text) do
    @doi_pattern
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, ~r/[.,;:\]\)\}>]+$/, ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp plain_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> html_entities()
    |> normalize_text()
  end

  defp html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end

  defp normalize_text(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp list_values(%Graph{} = graph, list_iri) do
    case RDF.List.new(list_iri, graph) do
      %RDF.List{} = list ->
        RDF.List.values(list)

      nil ->
        raise ArgumentError, "expected #{inspect(list_iri)} to be an RDF list"
    end
  end
end
