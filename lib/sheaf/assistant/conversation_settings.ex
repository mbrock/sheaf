defmodule Sheaf.Assistant.ConversationSettings do
  @moduledoc """
  Persists and restores the routing configuration of an assistant conversation.

  Older conversations are restored from their conversation mode and most
  recent assistant actor, whose model was already recorded by `Activity`.
  """

  alias RDF.{Dataset, Description, Graph}
  alias Sheaf.Assistant.ContextCodec
  alias Sheaf.NS.{AS, DOC}

  require OpenTelemetry.Tracer, as: Tracer

  @known_option_keys ~w(reasoning_effort max_tokens receive_timeout provider_options)a

  def read(id) when is_binary(id) do
    Tracer.with_span "Sheaf.Assistant.ConversationSettings.read", %{
      kind: :internal,
      attributes: [{"sheaf.assistant.conversation_id", id}]
    } do
      iri = Sheaf.Id.iri(id)

      with {:ok, graph} <- workspace_graph(iri) do
        description = Graph.description(graph, iri) || Description.new(iri)

        case json_value(description, DOC.assistantConfiguration()) do
          %{} = configuration -> {:ok, decode(configuration)}
          _other -> {:ok, legacy_settings(graph, description)}
        end
      end
    end
  end

  def write(id, settings) when is_binary(id) and is_map(settings) do
    Tracer.with_span "Sheaf.Assistant.ConversationSettings.write", %{
      kind: :internal,
      attributes: [
        {"sheaf.assistant.conversation_id", id},
        {"sheaf.assistant.model", to_string(settings.model)},
        {"sheaf.assistant.mode", to_string(settings.kind)}
      ]
    } do
      iri = Sheaf.Id.iri(id)
      workspace = RDF.iri(Sheaf.Workspace.graph())

      with {:ok, graph} <- workspace_graph(iri) do
        retract =
          predication_graph(graph, iri, [
            DOC.assistantConfiguration(),
            DOC.conversationMode()
          ])

        configuration = %{
          model: settings.model,
          kind: settings.kind,
          llm_options: settings.llm_options || []
        }

        assert =
          Graph.new(
            [
              {iri, RDF.type(), DOC.AssistantConversation},
              {iri, DOC.conversationMode(), conversation_mode(settings.kind)},
              {iri, DOC.assistantConfiguration(),
               RDF.json(ContextCodec.encode_json_value(configuration))}
            ],
            name: workspace
          )

        changes =
          [{:retract, retract}, {:assert, assert}]
          |> Enum.reject(fn {_operation, change} -> Graph.empty?(change) end)

        Sheaf.Repo.transact("assistant configuration #{id}", changes)
      end
    end
  end

  def merge_options(id, options) when is_binary(id) and is_list(options) do
    case read(id) do
      {:ok, settings} ->
        options
        |> put_present(:kind, settings.kind)
        |> put_present(:model, settings.model)
        |> put_present(:llm_options, settings.llm_options)

      {:error, _reason} ->
        options
    end
  end

  defp legacy_settings(graph, description) do
    kind = legacy_kind(description)

    model = latest_model(graph, description)

    %{
      kind: kind,
      model: model,
      llm_options:
        if(model, do: Sheaf.LLM.assistant_llm_options(model, kind), else: nil)
    }
  end

  defp legacy_kind(description) do
    modes =
      description
      |> Description.get(DOC.conversationMode(), [])
      |> Enum.map(&RDF.Literal.value/1)

    cond do
      "import" in modes -> :import
      "research" in modes -> :research
      "edit" in modes -> :edit
      Enum.any?(modes, &(&1 in ["chat", "quick"])) -> :chat
      true -> nil
    end
  end

  defp latest_model(graph, description) do
    description
    |> Description.get(AS.items(), [])
    |> Enum.map(fn message_iri ->
      message =
        Graph.description(graph, message_iri) || Description.new(message_iri)

      actor = Description.first(message, AS.attributedTo())

      model =
        case actor do
          nil ->
            nil

          actor ->
            graph
            |> Graph.description(actor)
            |> case do
              %Description{} = actor ->
                literal_value(actor, DOC.assistantModelName())

              _other ->
                nil
            end
        end

      {published_value(message), model}
    end)
    |> Enum.reject(fn {_published, model} -> is_nil(model) end)
    |> Enum.max_by(fn {published, _model} -> published end, fn ->
      {nil, nil}
    end)
    |> elem(1)
  end

  defp decode(configuration) do
    kind = configuration |> value("kind") |> normalize_kind()
    model = value(configuration, "model")

    %{
      kind: kind,
      model: model,
      llm_options: decode_options(value(configuration, "llm_options"))
    }
  end

  defp decode_options(%{} = options) do
    options
    |> Enum.flat_map(fn {key, value} ->
      case Enum.find(
             @known_option_keys,
             &(Atom.to_string(&1) == to_string(key))
           ) do
        nil -> []
        atom -> [{atom, decode_option_value(atom, value)}]
      end
    end)
  end

  defp decode_options(_options), do: nil

  defp decode_option_value(:reasoning_effort, value) when is_binary(value),
    do: String.to_existing_atom(value)

  defp decode_option_value(:provider_options, %{} = options),
    do: decode_nested_options(options)

  defp decode_option_value(_key, value), do: value

  defp decode_nested_options(options) do
    Enum.map(options, fn {key, value} ->
      key =
        try do
          String.to_existing_atom(to_string(key))
        rescue
          ArgumentError -> to_string(key)
        end

      value =
        if is_binary(value) and
             value in ~w(none low medium high xhigh max auto),
           do: String.to_existing_atom(value),
           else: value

      {key, value}
    end)
  end

  defp normalize_kind(kind) when kind in [:chat, :edit, :research, :import],
    do: kind

  defp normalize_kind(kind) when kind in ~w(chat edit research import),
    do: String.to_existing_atom(kind)

  defp normalize_kind(_kind), do: nil

  defp conversation_mode(:chat), do: "quick"
  defp conversation_mode(kind), do: to_string(kind)

  defp workspace_graph(iri) do
    workspace = RDF.iri(Sheaf.Workspace.graph())

    with :ok <- Sheaf.Repo.load_once({iri, nil, nil, workspace}) do
      {:ok,
       Sheaf.Repo.ask(fn dataset ->
         Dataset.graph(dataset, workspace) || Graph.new(name: workspace)
       end)}
    end
  end

  defp predication_graph(graph, subject, predicates) do
    graph
    |> Graph.triples()
    |> Enum.filter(fn {s, p, _object} -> s == subject and p in predicates end)
    |> Graph.new(name: Graph.name(graph))
  end

  defp json_value(description, predicate) do
    case Description.first(description, predicate) do
      nil -> nil
      literal -> RDF.Literal.value(literal)
    end
  end

  defp literal_value(nil, _predicate), do: nil

  defp literal_value(description, predicate) do
    case Description.first(description, predicate) do
      nil -> nil
      literal -> RDF.Literal.value(literal)
    end
  end

  defp published_value(description) do
    literal_value(description, AS.published()) || ~U[1970-01-01 00:00:00Z]
  end

  defp value(map, key),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp put_present(options, _key, nil), do: options
  defp put_present(options, key, value), do: Keyword.put(options, key, value)
end
