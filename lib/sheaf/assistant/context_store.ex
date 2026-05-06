defmodule Sheaf.Assistant.ContextStore do
  @moduledoc """
  RDF-backed store for ReqLLM assistant contexts.

  The graph is intentionally operational: each ReqLLM message is stored as an
  `rdf:JSON` payload plus an append index. Domain artifacts created by tools
  should still be represented in the workspace graph.
  """

  alias RDF.{Description, Graph}
  alias ReqLLM.Context
  alias Sheaf.Assistant.ContextCodec
  alias Sheaf.NS.DOC

  require OpenTelemetry.Tracer, as: Tracer
  require RDF.Graph

  @graph "https://less.rest/sheaf/llm-context"

  def graph, do: @graph

  @doc """
  Appends missing messages from `context` to the context graph.
  """
  def write(session_iri, %Context{} = context, opts \\ []) do
    Tracer.with_span "Sheaf.Assistant.ContextStore.write", %{
      kind: :internal,
      attributes: [
        {"sheaf.assistant.session", term_value(session_iri)},
        {"sheaf.graph", @graph},
        {"sheaf.llm_context.message_count", length(context.messages)}
      ]
    } do
      context_iri = context_iri(session_iri)

      with {:ok, existing_indices} <- existing_indices(context_iri, opts),
           %Graph{} = graph <-
             build_append_graph(
               context_iri,
               session_iri,
               context,
               existing_indices
             ),
           :ok <- persist(graph, opts) do
        Tracer.set_attribute(
          "sheaf.statement_count",
          RDF.Data.statement_count(graph)
        )

        :ok
      end
    end
  end

  @doc """
  Reads a persisted ReqLLM context for `session_iri`.
  """
  def read(session_iri, opts \\ []) do
    Tracer.with_span "Sheaf.Assistant.ContextStore.read", %{
      kind: :internal,
      attributes: [
        {"sheaf.assistant.session", term_value(session_iri)},
        {"sheaf.graph", @graph}
      ]
    } do
      context_iri = context_iri(session_iri)

      with {:ok, graph} <- context_graph(opts),
           messages when messages != [] <- graph_messages(graph, context_iri) do
        Tracer.set_attribute(
          "sheaf.llm_context.message_count",
          length(messages)
        )

        payload = %{
          "messages" => Enum.map(messages, & &1.payload),
          "tools" => []
        }

        ContextCodec.decode_context(payload)
      else
        [] -> {:error, :not_found}
        nil -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end
  end

  def context_iri(session_iri) do
    session_iri
    |> normalize_iri!()
    |> to_string()
    |> Kernel.<>("/llm-context")
    |> RDF.iri()
  end

  defp build_append_graph(
         context_iri,
         session_iri,
         %Context{} = context,
         existing_indices
       ) do
    context_graph = RDF.iri(@graph)
    session_iri = normalize_iri!(session_iri)

    messages =
      context.messages
      |> Enum.with_index()
      |> Enum.reject(fn {_message, index} ->
        MapSet.member?(existing_indices, index)
      end)

    if messages == [] do
      Graph.new(name: context_graph)
    else
      messages
      |> Enum.reduce(
        context_base_graph(context_graph, context_iri, session_iri, context),
        fn
          {message, index}, graph ->
            message_node = RDF.bnode()
            payload = ContextCodec.encode_message(message)

            graph
            |> add(context_iri, DOC.hasContextMessage(), message_node)
            |> add(message_node, RDF.type(), DOC.LLMContextMessage)
            |> add(message_node, DOC.messageIndex(), index)
            |> add(message_node, DOC.reqLLMMessage(), RDF.json(payload))
        end
      )
    end
  end

  defp context_base_graph(
         context_graph,
         context_iri,
         session_iri,
         %Context{} = context
       ) do
    Graph.new(name: context_graph)
    |> add(context_iri, RDF.type(), DOC.LLMContext)
    |> add(context_iri, DOC.forAssistantConversation(), session_iri)
    |> add_tool_schema_list(context_iri, context.tools || [])
  end

  defp add_tool_schema_list(graph, _context_iri, []), do: graph

  defp add_tool_schema_list(graph, context_iri, tools) when is_list(tools) do
    case ContextCodec.encode_tool_schemas(tools) do
      [] ->
        graph

      schemas ->
        add(graph, context_iri, DOC.toolSchemaList(), RDF.json(schemas))
    end
  end

  defp existing_indices(context_iri, opts) do
    with {:ok, graph} <- context_graph(opts) do
      indices =
        graph
        |> graph_messages(context_iri)
        |> Enum.map(& &1.index)
        |> MapSet.new()

      {:ok, indices}
    else
      {:error, :not_found} -> {:ok, MapSet.new()}
      {:error, _reason} = error -> error
    end
  end

  defp graph_messages(%Graph{} = graph, context_iri) do
    graph
    |> Graph.description(context_iri)
    |> case do
      %Description{} = context ->
        context
        |> Description.get(DOC.hasContextMessage(), [])
        |> Enum.map(&message_from_description(graph, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.index)

      nil ->
        []
    end
  end

  defp message_from_description(graph, node) do
    with %Description{} = message <- Graph.description(graph, node),
         index when is_integer(index) <-
           first_value(message, DOC.messageIndex()),
         %RDF.Literal{} = payload <-
           Description.first(message, DOC.reqLLMMessage()) do
      %{index: index, payload: RDF.Term.value(payload)}
    else
      _other -> nil
    end
  end

  defp context_graph(opts) do
    case Keyword.fetch(opts, :graph) do
      {:ok, %Graph{} = graph} ->
        {:ok, graph}

      :error ->
        if Process.whereis(Sheaf.Repo) do
          graph_name = RDF.iri(@graph)

          with :ok <- Sheaf.Repo.load_once({nil, nil, nil, graph_name}) do
            graph =
              Sheaf.Repo.ask(fn dataset ->
                RDF.Dataset.graph(dataset, graph_name) ||
                  Graph.new(name: graph_name)
              end)

            {:ok, graph}
          end
        else
          {:error, :repo_not_started}
        end
    end
  end

  defp persist(%Graph{} = graph, opts) do
    if RDF.Data.statement_count(graph) == 0 do
      :ok
    else
      persist = Keyword.get(opts, :persist)

      cond do
        is_function(persist, 1) ->
          do_persist(persist, graph)

        Process.whereis(Sheaf.Repo) ->
          do_persist(&Sheaf.Repo.assert/1, graph)

        true ->
          {:error, :repo_not_started}
      end
    end
  end

  defp do_persist(persist, graph) do
    case persist.(graph) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_persist_result, other}}
    end
  end

  defp add(%Graph{} = graph, _subject, _predicate, nil), do: graph

  defp add(%Graph{} = graph, subject, predicate, object) do
    Graph.add(graph, {subject, predicate, object})
  end

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> case do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp normalize_iri!(%RDF.IRI{} = iri), do: iri
  defp normalize_iri!(value) when is_binary(value), do: RDF.iri(value)

  defp term_value(%RDF.IRI{} = iri), do: RDF.Term.value(iri)
  defp term_value(value), do: to_string(value)
end
