defmodule Sheaf.GraphMigration do
  @moduledoc """
  Migrates inline paragraph text to append-only paragraph revision entities.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.GraphStore
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS
  alias Sheaf.Prov

  @rdf_membership_prefix "http://www.w3.org/1999/02/22-rdf-syntax-ns#_"

  def migrate_graph(graph_name, opts \\ []) when is_binary(graph_name) do
    with {:ok, rows} <- GraphStore.fetch_rows(graph_name),
         {:ok, result} <- migrate_rows(rows),
         {:ok, inserted} <- GraphStore.replace_graph(graph_name, result.graph, opts) do
      {:ok, Map.put(result, :statements, inserted)}
    end
  end

  def migrate_rows(rows) when is_list(rows) do
    rows
    |> GraphStore.graph_from_rows()
    |> migrate_data()
  end

  defp migrate_data(%Graph{} = graph) do
    sequence_members = sequence_members(graph)
    targets = legacy_targets(graph, sequence_members)

    migrated_graph =
      Enum.reduce(targets, graph, fn target, acc ->
        migrate_target(acc, target)
      end)

    {:ok,
     %{
       migrated_blocks: length(targets),
       paragraph_revisions: length(targets),
       graph: migrated_graph
     }}
  end

  defp legacy_targets(%Graph{} = graph, sequence_members) do
    graph
    |> Graph.subjects()
    |> Enum.map(fn subject ->
      description = Graph.description(graph, subject)
      text = Description.first(description, SheafNS.text())

      cond do
        versioned?(description) ->
          nil

        utterance?(description) and match?(%RDF.Literal{}, text) ->
          %{kind: :utterance, subject: subject, text: text}

        legacy_paragraph_block?(description, subject, sequence_members) and
            match?(%RDF.Literal{}, text) ->
          %{kind: :paragraph_block, subject: subject, text: text}

        true ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp migrate_target(%Graph{} = graph, %{subject: subject, text: text}) do
    paragraph_iri = Id.iri(Id.generate())

    graph
    |> Graph.delete({subject, RDF.type(), SheafNS.Paragraph})
    |> Graph.delete({subject, SheafNS.text(), text})
    |> Graph.add([
      {subject, RDF.type(), SheafNS.ParagraphBlock},
      {subject, SheafNS.paragraph(), paragraph_iri},
      {paragraph_iri, RDF.type(), SheafNS.Paragraph},
      {paragraph_iri, RDF.type(), Prov.entity()},
      {paragraph_iri, SheafNS.text(), text}
    ])
  end

  defp sequence_members(%Graph{} = graph) do
    graph
    |> Graph.descriptions()
    |> Enum.reduce(MapSet.new(), fn description, acc ->
      description
      |> Description.predicates()
      |> Enum.filter(&membership_predicate?/1)
      |> Enum.reduce(acc, fn predicate, subjects ->
        description
        |> Description.get(predicate, [])
        |> MapSet.new()
        |> MapSet.union(subjects)
      end)
    end)
  end

  defp versioned?(%Description{} = description) do
    description
    |> Description.get(SheafNS.paragraph(), [])
    |> case do
      [] -> false
      _ -> true
    end
  end

  defp utterance?(%Description{} = description) do
    Description.include?(description, {RDF.type(), SheafNS.Utterance})
  end

  defp legacy_paragraph_block?(%Description{} = description, subject, sequence_members) do
    Description.include?(description, {RDF.type(), SheafNS.Paragraph}) and
      MapSet.member?(sequence_members, subject)
  end

  defp membership_predicate?(predicate) do
    predicate
    |> to_string()
    |> String.starts_with?(@rdf_membership_prefix)
  end
end
