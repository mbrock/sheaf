defmodule Sheaf.DocumentMentions do
  @moduledoc """
  Resolves research-note and conversation mentions back to their documents.
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.{Corpus, Id}
  alias Sheaf.NS.{AS, DOC}

  require OpenTelemetry.Tracer, as: Tracer

  @doc "Returns mention contexts keyed by document id."
  def for_documents(documents) when is_list(documents) do
    Tracer.with_span "sheaf.document_mentions.for_documents", %{
      kind: :internal,
      attributes: [{"sheaf.document_count", length(documents)}]
    } do
      document_ids = MapSet.new(documents, & &1.id)

      with {:ok, graph} <- Sheaf.fetch_graph(Sheaf.Repo.workspace_graph()) do
        target_ids = mention_target_ids(graph)

        block_documents =
          target_ids
          |> Enum.reject(&MapSet.member?(document_ids, &1))
          |> Corpus.find_documents()

        mentions = from_graph(graph, document_ids, block_documents)

        Tracer.set_attributes([
          {"sheaf.mention_target_count", length(target_ids)},
          {"sheaf.mentioned_document_count", map_size(mentions)}
        ])

        mentions
      else
        {:error, reason} ->
          Tracer.set_attribute("sheaf.error", inspect(reason))
          %{}
      end
    end
  end

  @doc false
  def from_graph(%Graph{} = graph, document_ids, block_documents) do
    mentions = RDF.iri(DOC.mentions())

    graph
    |> Graph.triples()
    |> Enum.reduce(%{}, fn
      {source, ^mentions, target}, index ->
        target_id = Id.id_from_iri(target)

        document_id =
          if MapSet.member?(document_ids, target_id),
            do: target_id,
            else: Map.get(block_documents, target_id)

        case document_id do
          nil ->
            index

          document_id ->
            mention_context = context(graph, source)

            Map.update(
              index,
              document_id,
              [mention_context],
              &[mention_context | &1]
            )
        end

      _triple, index ->
        index
    end)
    |> Map.new(fn {document_id, contexts} ->
      contexts =
        contexts
        |> Enum.group_by(& &1.path)
        |> Enum.map(fn {_path, contexts} -> conversation(contexts) end)
        |> Enum.sort_by(&sort_key/1, :desc)

      {document_id, contexts}
    end)
  end

  defp mention_target_ids(graph) do
    mentions = RDF.iri(DOC.mentions())

    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {_source, ^mentions, target} -> [Id.id_from_iri(target)]
      _triple -> []
    end)
    |> Enum.uniq()
  end

  defp context(graph, source) do
    description = Graph.description(graph, source)
    session = Description.first(description, AS.context())
    resource = session || source
    resource_id = Id.id_from_iri(resource)
    thread_title = context_title(graph, session)
    note_title = first_value(description, RDFS.label())

    %{
      id: resource_id,
      path: "/#{resource_id}",
      source_id: Id.id_from_iri(source),
      title: display_title(thread_title, note_title),
      published_at: first_value(description, AS.published())
    }
  end

  defp display_title("Assistant conversation" <> _suffix, note_title)
       when is_binary(note_title),
       do: note_title

  defp display_title(thread_title, _note_title), do: thread_title

  defp conversation(contexts) do
    newest = Enum.max_by(contexts, &sort_key/1)

    newest
    |> Map.drop([:source_id])
    |> Map.put(
      :mention_count,
      contexts |> Enum.map(& &1.source_id) |> Enum.uniq() |> length()
    )
  end

  defp context_title(_graph, nil), do: "Assistant conversation"

  defp context_title(graph, session) do
    graph
    |> Graph.description(session)
    |> first_value(RDFS.label())
    |> case do
      nil -> "Assistant conversation"
      title -> title
    end
  end

  defp sort_key(%{published_at: %DateTime{} = value}),
    do: DateTime.to_unix(value)

  defp sort_key(%{published_at: nil}), do: 0
  defp sort_key(%{published_at: value}), do: to_string(value)

  defp first_value(nil, _predicate), do: nil

  defp first_value(description, predicate) do
    description
    |> Description.first(predicate)
    |> term_value()
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end
end
