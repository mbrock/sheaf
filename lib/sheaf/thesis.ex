defmodule Sheaf.Thesis do
  @moduledoc """
  Reads a thesis outline from a named graph.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.Id
  alias Sheaf.DOC
  alias Sheaf.Prov

  defmodule Document do
    defstruct [:id, :iri, :kind, :title, children: []]
  end

  defmodule Block do
    defstruct [:id, :iri, :type, :heading, :text, children: []]
  end

  def fetch_outline(id) do
    with {:ok, graph} <- Sheaf.fetch_graph(Id.iri(id)) do
      {:ok, from_graph(graph)}
    end
  end

  def from_graph(graph) do
    case root_document_iri(graph) do
      nil -> nil
      iri -> build_document(graph, iri)
    end
  end

  defp build_document(graph, iri) do
    description = Graph.description(graph, iri)

    %Document{
      id: Id.id_from_iri(iri),
      iri: iri,
      kind: document_kind(graph, iri),
      title: literal_value(Description.first(description, DOC.title())) || "Untitled thesis",
      children: build_children(graph, iri)
    }
  end

  defp build_block(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    cond do
      typed?(description, DOC.Section) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :section,
          heading:
            literal_value(Description.first(description, DOC.heading())) || "Untitled section",
          children: build_children(graph, iri)
        }

      typed?(description, DOC.ParagraphBlock) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: current_paragraph_text(graph, description) || ""
        }

      typed?(description, DOC.Paragraph) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: literal_value(Description.first(description, DOC.text())) || ""
        }

      true ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: ""
        }
    end
  end

  defp build_children(%Graph{} = graph, container_iri) do
    graph
    |> Graph.description(container_iri)
    |> Description.first(DOC.children())
    |> case do
      nil -> []
      list_iri -> list_members(graph, list_iri) |> Enum.map(&build_block(graph, &1))
    end
  end

  defp current_paragraph_text(%Graph{} = graph, %Description{} = description) do
    case active_paragraph_iri(graph, description) do
      nil ->
        nil

      paragraph_iri ->
        graph
        |> Graph.description(paragraph_iri)
        |> Description.first(DOC.text())
        |> literal_value()
    end
  end

  defp active_paragraph_iri(%Graph{} = graph, %Description{} = description) do
    revisions = Description.get(description, DOC.paragraph(), [])

    Enum.find(revisions, &(not invalidated?(graph, &1))) || List.last(revisions)
  end

  defp invalidated?(%Graph{} = graph, paragraph_iri) do
    graph
    |> Graph.description(paragraph_iri)
    |> Description.get(Prov.was_invalidated_by(), [])
    |> case do
      [] -> false
      _ -> true
    end
  end

  defp list_members(%Graph{} = graph, list_iri) do
    case RDF.List.new(list_iri, graph) do
      %RDF.List{} = list ->
        RDF.List.values(list)

      nil ->
        raise ArgumentError, "expected #{inspect(list_iri)} to be an RDF list"
    end
  end

  defp root_document_iri(%Graph{} = graph) do
    find_typed_subject(graph, DOC.Thesis) ||
      find_typed_subject(graph, DOC.Transcript) ||
      find_typed_subject(graph, DOC.Document)
  end

  defp find_typed_subject(%Graph{} = graph, type) do
    graph
    |> Graph.subjects()
    |> Enum.filter(&typed?(Graph.description(graph, &1), type))
    |> Enum.sort_by(&to_string/1)
    |> List.first()
  end

  defp typed?(%Description{} = description, type) do
    Description.include?(description, {RDF.type(), type})
  end

  defp document_kind(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    cond do
      typed?(description, DOC.Thesis) -> :thesis
      typed?(description, DOC.Transcript) -> :transcript
      true -> :document
    end
  end

  defp literal_value(nil), do: nil
  defp literal_value(%RDF.Literal{} = literal), do: literal |> RDF.Term.value() |> to_string()
  defp literal_value(value) when is_binary(value), do: value
end
