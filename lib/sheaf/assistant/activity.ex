defmodule Sheaf.Assistant.Activity do
  @moduledoc """
  Persistent ActivityStreams records for assistant chat turns.

  Chat state is still process-local for the live UI, but the semantic trace of an
  assistant conversation is appended to RDF: messages, contextual actors, and the
  session collection that groups them.
  """

  alias RDF.Graph
  require RDF.Graph

  @doc """
  Appends a user-authored message to RDF.

  User actors default to blank `as:Person` nodes.
  """
  def write_user_message(attrs, opts \\ []) when is_map(attrs) do
    write_message(:user, attrs, opts)
  end

  @doc """
  Appends an assistant-authored message to RDF.

  Assistant actors default to blank `prov:SoftwareAgent` nodes. Pass
  `:model_name` to describe the model used for the turn.
  """
  def write_assistant_message(attrs, opts \\ []) when is_map(attrs) do
    write_message(:assistant, attrs, opts)
  end

  defp write_message(actor_kind, attrs, opts) do
    with {:ok, graph} <- build_message(actor_kind, attrs, opts),
         [message | _] <- message_descriptions(graph),
         :ok <- persist(graph, opts) do
      {:ok, message.subject}
    else
      [] -> {:error, "activity graph did not contain a message"}
      error -> error
    end
  end

  def build_message(actor_kind, attrs, opts \\ [])
      when actor_kind in [:user, :assistant] do
    with {:ok, text} <- required_text(attrs),
         {:ok, message_iri} <- message_iri(attrs, opts),
         {:ok, actor} <- actor(attrs, actor_kind),
         {:ok, session_iri} <- required_iri(attrs, :session),
         {:ok, published_at} <- published_at(opts) do
      actor_type = actor_type(actor_kind)

      graph =
        RDF.Graph.build message: message_iri,
                        actor: actor,
                        session: session_iri,
                        text: text,
                        published_at: published_at,
                        actor_type: actor_type,
                        model_name: optional_text(attrs, :model_name),
                        session_label: optional_text(attrs, :session_label),
                        conversation_mode:
                          optional_text(attrs, :conversation_mode),
                        in_reply_to: optional_iri(attrs, :in_reply_to) do
          @prefix Sheaf.NS.AS
          @prefix Sheaf.NS.DOC
          @prefix RDF.NS.RDFS

          message
          |> a(DOC.Message)
          |> AS.attributedTo(actor)
          |> AS.context(session)
          |> AS.published(published_at)
          |> AS.content(text)
          |> AS.inReplyTo(in_reply_to)

          actor
          |> a(actor_type)
          |> DOC.assistantModelName(model_name)

          session
          |> a(DOC.AssistantConversation)
          |> a(AS.OrderedCollection)
          |> RDFS.label(session_label)
          |> AS.name(session_label)
          |> DOC.conversationMode(conversation_mode)
          |> AS.items(message)
        end

      {:ok, graph}
    end
  end

  def insert_data(%Graph{} = graph) do
    triples =
      graph
      |> RDF.NTriples.write_string!()
      |> String.trim()

    """
    INSERT DATA {
      GRAPH <#{Sheaf.Workspace.graph()}> {
    #{indent(triples, 4)}
      }
    }
    """
  end

  defp persist(%Graph{} = graph, opts) do
    graph = Graph.change_name(graph, Sheaf.Workspace.graph())
    persist = Keyword.get(opts, :persist, &Sheaf.Repo.assert/1)

    case persist.(graph) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_persist_result, other}}
    end
  end

  defp message_descriptions(%Graph{} = graph) do
    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(
      &RDF.Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.Message})
    )
  end

  defp actor_type(:assistant), do: Sheaf.NS.PROV.SoftwareAgent
  defp actor_type(:user), do: Sheaf.NS.AS.Person

  defp required_text(attrs) do
    case optional_text(attrs, :text) || optional_text(attrs, :content) do
      nil -> {:error, "message text is required"}
      text -> {:ok, text}
    end
  end

  defp optional_text(attrs, key) do
    attrs
    |> arg(key)
    |> case do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _other ->
        nil
    end
  end

  defp message_iri(attrs, opts) do
    case Keyword.get(opts, :message_iri) || arg(attrs, :message_iri) ||
           arg(attrs, :message_id) do
      nil -> {:ok, Sheaf.mint()}
      value -> normalize_iri(value, :message)
    end
  end

  defp actor(attrs, kind) do
    case arg(attrs, :actor_iri) || arg(attrs, :actor_id) do
      nil -> {:ok, RDF.bnode()}
      value -> normalize_iri(value, kind)
    end
  end

  defp required_iri(attrs, role) do
    iri_key = :"#{role}_iri"
    id_key = :"#{role}_id"

    case arg(attrs, iri_key) || arg(attrs, id_key) do
      nil -> {:error, "#{role} identity is required"}
      value -> normalize_iri(value, role)
    end
  end

  defp optional_iri(attrs, key) do
    case arg(attrs, key) do
      nil ->
        nil

      value ->
        value
        |> normalize_iri(key)
        |> case do
          {:ok, iri} -> iri
          {:error, _reason} -> nil
        end
    end
  end

  defp normalize_iri(%RDF.IRI{} = iri, _role), do: {:ok, iri}

  defp normalize_iri(value, role) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, "#{role} identity is required"}

      String.starts_with?(value, ["http://", "https://"]) ->
        {:ok, RDF.iri(value)}

      true ->
        {:ok, Sheaf.Id.iri(value)}
    end
  end

  defp normalize_iri(_value, role), do: {:error, "invalid #{role} identity"}

  defp published_at(opts) do
    case Keyword.get(opts, :published_at) do
      nil -> {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}
      %DateTime{} = timestamp -> {:ok, DateTime.truncate(timestamp, :second)}
      _other -> {:error, "published_at must be a DateTime"}
    end
  end

  defp indent(text, spaces)
  defp indent("", _spaces), do: ""

  defp indent(text, spaces) do
    padding = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(padding <> &1))
  end

  defp arg(attrs, key),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
