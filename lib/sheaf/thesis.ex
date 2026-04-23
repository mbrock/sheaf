defmodule Sheaf.Thesis do
  @moduledoc """
  Reads the thesis outline from the configured named graph.
  """

  alias SPARQL.Query.Result
  alias Sheaf.Fuseki
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS

  defmodule Document do
    defstruct [:id, :iri, :kind, :title, children: []]
  end

  defmodule Block do
    defstruct [:id, :iri, :type, :heading, :text, children: []]
  end

  @rdf_membership_prefix "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"

  def fetch_outline do
    with {:ok, %Result{results: rows}} <- Fuseki.select(graph_query()) do
      {:ok, from_rows(rows)}
    end
  end

  def from_rows(rows) when is_list(rows) do
    index = build_index(rows)

    case root_document_iri(index) do
      nil -> nil
      iri -> build_document(iri, index)
    end
  end

  defp graph_query do
    """
    SELECT ?s ?p ?o
    WHERE {
      GRAPH #{Fuseki.graph_ref()} {
        ?s ?p ?o .
      }
    }
    ORDER BY STR(?s) STR(?p) STR(?o)
    """
  end

  defp build_index(rows) do
    Enum.reduce(rows, %{types: %{}, literals: %{}, refs: %{}}, fn row, acc ->
      subject = term_key(row["s"])
      predicate = term_key(row["p"])
      object = row["o"]

      cond do
        predicate == rdf_type_iri() ->
          type = term_key(object)
          %{acc | types: put_type(acc.types, subject, type)}

        match?(%RDF.Literal{}, object) ->
          value = RDF.Term.value(object)
          %{acc | literals: put_value(acc.literals, subject, predicate, to_string(value))}

        true ->
          %{acc | refs: put_value(acc.refs, subject, predicate, term_key(object))}
      end
    end)
  end

  defp root_document_iri(index) do
    find_typed_subject(index, thesis_iri()) ||
      find_typed_subject(index, transcript_iri()) ||
      find_typed_subject(index, document_iri())
  end

  defp find_typed_subject(index, type_iri) do
    index.types
    |> Enum.filter(fn {_subject, types} -> MapSet.member?(types, type_iri) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> List.first()
  end

  defp build_document(iri, index) do
    %Document{
      id: Id.id_from_iri(iri),
      iri: iri,
      kind: document_kind(iri, index),
      title: first_literal(index, iri, title_iri()) || "Untitled thesis",
      children: build_children(iri, index)
    }
  end

  defp build_block(iri, index) do
    cond do
      typed?(index, iri, section_iri()) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :section,
          heading: first_literal(index, iri, heading_iri()) || "Untitled section",
          children: build_children(iri, index)
        }

      typed?(index, iri, paragraph_iri()) ->
        %Block{
          id: Id.id_from_iri(iri),
          iri: iri,
          type: :paragraph,
          text: first_literal(index, iri, text_iri()) || ""
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

  defp build_children(container_iri, index) do
    index
    |> first_ref(container_iri, children_iri())
    |> sequence_members(index)
    |> Enum.map(&build_block(&1, index))
  end

  defp sequence_members(nil, _index), do: []

  defp sequence_members(sequence_iri, index) do
    index.refs
    |> Map.get(sequence_iri, %{})
    |> Enum.flat_map(fn {predicate, values} ->
      case membership_position(predicate) do
        nil -> []
        position -> Enum.map(values, &{position, &1})
      end
    end)
    |> Enum.sort_by(fn {position, iri} -> {position, iri} end)
    |> Enum.map(&elem(&1, 1))
  end

  defp membership_position(predicate) do
    case predicate do
      <<@rdf_membership_prefix::binary, suffix::binary>> ->
        case Integer.parse(suffix) do
          {position, ""} -> position
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp typed?(index, iri, type_iri) do
    index.types
    |> Map.get(iri, MapSet.new())
    |> MapSet.member?(type_iri)
  end

  defp document_kind(iri, index) do
    cond do
      typed?(index, iri, thesis_iri()) -> :thesis
      typed?(index, iri, transcript_iri()) -> :transcript
      true -> :document
    end
  end

  defp first_literal(index, subject, predicate) do
    index.literals
    |> Map.get(subject, %{})
    |> Map.get(predicate, [])
    |> Enum.reverse()
    |> List.first()
  end

  defp first_ref(index, subject, predicate) do
    index.refs
    |> Map.get(subject, %{})
    |> Map.get(predicate, [])
    |> Enum.reverse()
    |> List.first()
  end

  defp term_key(%RDF.IRI{} = iri), do: to_string(iri)
  defp term_key(%RDF.BlankNode{} = bnode), do: to_string(bnode)
  defp term_key(value) when is_atom(value), do: value |> RDF.Namespace.resolve_term!() |> to_string()
  defp term_key(value) when is_binary(value), do: value

  defp put_type(types, subject, type) do
    Map.update(types, subject, MapSet.new([type]), &MapSet.put(&1, type))
  end

  defp put_value(values, subject, predicate, object) do
    subject_values = Map.get(values, subject, %{})
    predicate_values = Map.get(subject_values, predicate, [])

    Map.put(values, subject, Map.put(subject_values, predicate, [object | predicate_values]))
  end

  defp rdf_type_iri, do: to_string(RDF.type())
  defp document_iri, do: SheafNS.Document |> RDF.Namespace.resolve_term!() |> to_string()
  defp thesis_iri, do: SheafNS.Thesis |> RDF.Namespace.resolve_term!() |> to_string()
  defp transcript_iri, do: SheafNS.Transcript |> RDF.Namespace.resolve_term!() |> to_string()
  defp section_iri, do: SheafNS.Section |> RDF.Namespace.resolve_term!() |> to_string()
  defp paragraph_iri, do: SheafNS.Paragraph |> RDF.Namespace.resolve_term!() |> to_string()
  defp children_iri, do: to_string(SheafNS.children())
  defp heading_iri, do: to_string(SheafNS.heading())
  defp text_iri, do: to_string(SheafNS.text())
  defp title_iri, do: to_string(SheafNS.title())
end
