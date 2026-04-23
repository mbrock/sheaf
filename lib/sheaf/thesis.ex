defmodule Sheaf.Thesis do
  @moduledoc """
  Reads the thesis outline from the configured named graph.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS
  alias Sheaf.Prov

  defmodule Document do
    defstruct [:id, :iri, :kind, :title, children: []]
  end

  defmodule Block do
    defstruct [:id, :iri, :type, :heading, :text, children: []]
  end

  @rdf_membership_prefix "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"

  def fetch_outline(graph_name) do
    with {:ok, graph} <- Sheaf.fetch_graph(graph_name) do
      {:ok, from_graph(graph)}
    end
  end

  def from_graph(%Graph{} = graph) do
    case root_document_iri(graph) do
      nil -> nil
      iri -> build_document(graph, iri)
    end
  end

  defp build_document(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    %Document{
      id: Id.id_from_iri(iri),
      iri: iri,
      kind: document_kind(graph, iri),
      title: literal_value(Description.first(description, SheafNS.title())) || "Untitled thesis",
      children: build_children(graph, iri)
    }
  end

  defp build_block(%Graph{} = graph, iri) do
    description = Graph.description(graph, iri)

    cond do
      typed?(description, SheafNS.Section) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :section,
          heading:
            literal_value(Description.first(description, SheafNS.heading())) || "Untitled section",
          children: build_children(graph, iri)
        }

      typed?(description, SheafNS.ParagraphBlock) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: current_paragraph_text(graph, description) || ""
        }

      typed?(description, SheafNS.Paragraph) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: literal_value(Description.first(description, SheafNS.text())) || ""
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
    |> Description.first(SheafNS.children())
    |> case do
      nil -> []
      sequence_iri -> sequence_members(graph, sequence_iri) |> Enum.map(&build_block(graph, &1))
    end
  end

  defp current_paragraph_text(%Graph{} = graph, %Description{} = description) do
    case active_paragraph_iri(graph, description) do
      nil ->
        nil

      paragraph_iri ->
        graph
        |> Graph.description(paragraph_iri)
        |> Description.first(SheafNS.text())
        |> literal_value()
    end
  end

  defp active_paragraph_iri(%Graph{} = graph, %Description{} = description) do
    revisions = Description.get(description, SheafNS.paragraph(), [])

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

  defp sequence_members(%Graph{} = graph, sequence_iri) do
    graph
    |> Graph.description(sequence_iri)
    |> Description.predicates()
    |> Enum.flat_map(fn predicate ->
      case membership_position(predicate) do
        nil ->
          []

        position ->
          graph
          |> Graph.description(sequence_iri)
          |> Description.get(predicate, [])
          |> Enum.map(&{position, &1})
      end
    end)
    |> Enum.sort_by(fn {position, iri} -> {position, iri} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp membership_position(predicate) do
    case to_string(predicate) do
      <<@rdf_membership_prefix::binary, suffix::binary>> ->
        case Integer.parse(suffix) do
          {position, ""} -> position
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp root_document_iri(%Graph{} = graph) do
    find_typed_subject(graph, SheafNS.Thesis) ||
      find_typed_subject(graph, SheafNS.Transcript) ||
      find_typed_subject(graph, SheafNS.Document)
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
      typed?(description, SheafNS.Thesis) -> :thesis
      typed?(description, SheafNS.Transcript) -> :transcript
      true -> :document
    end
  end

  defp literal_value(nil), do: nil
  defp literal_value(%RDF.Literal{} = literal), do: literal |> RDF.Term.value() |> to_string()
  defp literal_value(value) when is_binary(value), do: value
end
