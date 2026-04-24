defmodule Sheaf.Thesis do
  @moduledoc """
  RDF navigation helpers for thesis-like document graphs.
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{DOC, PROV}

  def id(iri), do: Id.id_from_iri(iri)

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

  defp list_values(%Graph{} = graph, list_iri) do
    case RDF.List.new(list_iri, graph) do
      %RDF.List{} = list ->
        RDF.List.values(list)

      nil ->
        raise ArgumentError, "expected #{inspect(list_iri)} to be an RDF list"
    end
  end
end
