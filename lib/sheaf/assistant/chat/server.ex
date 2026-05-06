defmodule Sheaf.Assistant.Chat.Server do
  @moduledoc """
  Long-lived assistant chat session.

  A chat owns the assistant process, visible message log, current pending
  status, and LiveComponent subscriptions. The LiveView can disconnect or
  reload without losing this process-local conversation state.
  """

  use GenServer

  alias ReqLLM.{Context, Response}
  alias Sheaf.Assistant

  alias Sheaf.Assistant.{
    Activity,
    Chats,
    ContextStore,
    CorpusTools,
    Notes,
    SpreadsheetSession,
    StreamBuffer
  }

  alias Sheaf.Id

  @registry Sheaf.Assistant.ChatRegistry
  @default_title "Assistant conversation"
  @default_kind :chat
  @default_max_tool_rounds 500

  defstruct [
    :id,
    :assistant,
    :pending_ref,
    :active_tool,
    :status_line,
    :error,
    :agent_iri,
    :session_iri,
    :last_user_message_iri,
    :activity_writer,
    :context_store,
    :stream_buffer,
    title: @default_title,
    kind: @default_kind,
    messages: [],
    subscribers: %{},
    allow_notes?: false,
    model: nil,
    llm_options: [],
    max_tool_rounds: @default_max_tool_rounds,
    task_supervisor: Sheaf.Assistant.TaskSupervisor,
    generate_text: nil,
    stream_text: nil,
    stream?: false,
    titles: %{}
  ]

  @type snapshot :: %{
          id: String.t(),
          title: String.t(),
          kind: :chat | :research | :edit,
          messages: [map()],
          pending: boolean(),
          active_tool: String.t() | nil,
          status_line: String.t() | nil,
          error: term()
        }

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  def exists?(id) when is_binary(id) do
    Registry.lookup(@registry, id) != []
  end

  def snapshot(server) do
    GenServer.call(server_ref(server), :snapshot)
  end

  def send_user_message(server, text, turn_context \\ %{}) do
    GenServer.call(server_ref(server), {:send_user_message, text, turn_context})
  end

  def put_model(server, model) do
    GenServer.call(server_ref(server), {:put_model, model})
  end

  def put_llm_options(server, opts) when is_list(opts) do
    GenServer.call(server_ref(server), {:put_llm_options, opts})
  end

  def subscribe(server, live_view, component, component_id) do
    GenServer.call(server_ref(server), {:subscribe, live_view, component, component_id})
  end

  def unsubscribe(server, live_view, component, component_id) do
    GenServer.cast(server_ref(server), {:unsubscribe, live_view, component, component_id})
  end

  @impl true
  def init(opts) do
    chat = self()
    id = Keyword.fetch!(opts, :id)
    kind = opts |> Keyword.get(:kind, @default_kind) |> normalize_kind()
    title = Keyword.get_lazy(opts, :title, fn -> default_title(kind) end)
    model = Keyword.get(opts, :model, Sheaf.LLM.default_model())
    llm_options = Keyword.get(opts, :llm_options, [])
    max_tool_rounds = Keyword.get(opts, :max_tool_rounds, @default_max_tool_rounds)
    task_supervisor = Keyword.get(opts, :task_supervisor, Sheaf.Assistant.TaskSupervisor)
    generate_text = Keyword.get(opts, :generate_text, &ReqLLM.generate_text/3)
    stream_text = Keyword.get(opts, :stream_text, &ReqLLM.stream_text/3)
    stream? = Keyword.get(opts, :stream?, false)
    titles = Keyword.get_lazy(opts, :titles, &CorpusTools.titles/0)
    session_iri = Keyword.get_lazy(opts, :session_iri, fn -> Id.iri(id) end)
    agent_iri = Keyword.get_lazy(opts, :agent_iri, &Sheaf.mint/0)
    activity_writer = Keyword.get(opts, :activity_writer, Activity)
    context_store = Keyword.get(opts, :context_store, ContextStore)

    spreadsheet_session =
      Keyword.get_lazy(opts, :spreadsheet_session, fn -> SpreadsheetSession.via(id) end)

    workspace_instructions =
      Keyword.get_lazy(opts, :workspace_instructions, &workspace_instructions/0)

    allow_notes? =
      Keyword.get(opts, :allow_notes?, Keyword.get(opts, :allow_notes, kind == :research))

    context =
      Keyword.get(opts, :context) ||
        persisted_context(context_store, session_iri) ||
        Context.new([Context.system(system_prompt(kind, allow_notes?, workspace_instructions))])

    messages = visible_messages_from_context(context, titles)
    title = maybe_title_from_context(title, kind, messages)

    tools =
      CorpusTools.tools(
        tool_set: tool_set(kind),
        include_notes?: allow_notes?,
        notify: fn event -> GenServer.cast(chat, {:assistant_event, event}) end,
        note_context: %{
          agent_iri: agent_iri,
          agent_label: agent_label(kind),
          session_iri: session_iri,
          session_label: session_label(kind, id),
          conversation_mode: conversation_mode(kind, allow_notes?)
        },
        query_result_context: [
          agent_iri: agent_iri,
          session_iri: session_iri
        ],
        spreadsheet_session: spreadsheet_session
      )

    context = put_context_tools(context, tools)

    case Assistant.start_link(
           model: model,
           context: context,
           tools: tools,
           max_tool_rounds: max_tool_rounds,
           llm_options: llm_options,
           task_supervisor: task_supervisor,
           generate_text: generate_text,
           stream_text: stream_text
         ) do
      {:ok, assistant} ->
        {:ok,
         %__MODULE__{
           id: id,
           title: title,
           kind: kind,
           assistant: assistant,
           agent_iri: agent_iri,
           session_iri: session_iri,
           activity_writer: activity_writer,
           context_store: context_store,
           allow_notes?: allow_notes?,
           model: model,
           llm_options: llm_options,
           max_tool_rounds: max_tool_rounds,
           task_supervisor: task_supervisor,
           generate_text: generate_text,
           stream_text: stream_text,
           stream?: stream?,
           titles: titles,
           messages: messages
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
  end

  def handle_call(:persist_context, _from, state) do
    state = persist_context(state)
    {:reply, :ok, state}
  end

  def handle_call({:send_user_message, text, _turn_context}, _from, state)
      when not is_binary(text) do
    {:reply, {:error, :invalid_message}, state}
  end

  def handle_call({:send_user_message, text, _turn_context}, _from, %{pending_ref: ref} = state)
      when not is_nil(ref) do
    if String.trim(text) == "" do
      {:reply, {:error, :empty_message}, state}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:send_user_message, text, turn_context}, _from, state) do
    text = String.trim(text)

    if text == "" do
      {:reply, {:error, :empty_message}, state}
    else
      {:reply, :ok, start_turn(state, text, turn_context)}
    end
  end

  def handle_call({:promote_assistant_message, index}, _from, state) do
    case promote_assistant_message(state, index) do
      {:ok, note, state} ->
        {:reply, {:ok, note}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_model, _model}, _from, %{pending_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:put_model, model}, _from, state) do
    case Assistant.put_model(state.assistant, model) do
      :ok -> {:reply, :ok, %{state | model: model}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_llm_options, _opts}, _from, %{pending_ref: ref} = state)
      when not is_nil(ref) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:put_llm_options, opts}, _from, state) do
    case Assistant.put_llm_options(state.assistant, opts) do
      :ok -> {:reply, :ok, %{state | llm_options: opts}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, live_view, component, component_id}, _from, state) do
    state = put_subscriber(state, live_view, component, component_id)
    {:reply, snapshot_from_state(state), state}
  end

  @impl true
  def handle_cast({:unsubscribe, live_view, component, component_id}, state) do
    {:noreply, delete_subscriber(state, {live_view, component, component_id})}
  end

  def handle_cast({:assistant_event, event}, state) do
    {:noreply, handle_assistant_event(state, event)}
  end

  @impl true
  def handle_info({:assistant_result, ref, result}, %{pending_ref: ref} = state) do
    {:noreply, handle_assistant_result(state, result)}
  end

  def handle_info({:assistant_result, _ref, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.reject(fn {_key, ref} -> ref == monitor_ref end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp start_turn(state, text, turn_context) do
    ref = make_ref()
    chat = self()
    assistant = state.assistant
    input = user_input(text, turn_context)
    run_options = assistant_run_options(state, chat, ref)
    state = maybe_title_from(state, text)
    state = persist_user_message(state, text)
    state = persist_context_with_input(state, input)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           result = safe_run(assistant, input, run_options)
           send(chat, {:assistant_result, ref, result})
         end) do
      {:ok, _pid} ->
        state
        |> Map.put(:pending_ref, ref)
        |> Map.put(:status_line, "Thinking")
        |> Map.put(:stream_buffer, StreamBuffer.new())
        |> append_message(:user, text)
        |> touch_index()
        |> broadcast_snapshot()

      {:error, reason} ->
        state
        |> append_message(:error, "Could not start assistant turn: #{inspect(reason)}")
        |> broadcast_snapshot()
    end
  end

  defp safe_run(assistant, input, opts) do
    Assistant.run(assistant, input, opts)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp handle_assistant_result(state, {:ok, %Response{} = response}) do
    text = Response.text(response) |> blank_to_default()

    state
    |> persist_assistant_message(text)
    |> persist_context()
    |> Map.put(:pending_ref, nil)
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, nil)
    |> Map.put(:stream_buffer, nil)
    |> put_final_assistant_message(text)
    |> touch_index()
    |> broadcast_snapshot()
  end

  defp handle_assistant_result(state, {:error, reason}) do
    state
    |> persist_context()
    |> Map.put(:pending_ref, nil)
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, nil)
    |> Map.put(:stream_buffer, nil)
    |> append_message(:error, "Assistant error: #{inspect(reason)}")
    |> touch_index()
    |> broadcast_snapshot()
  end

  defp handle_assistant_event(state, {:tool_started, name, args}) do
    line = CorpusTools.humanize(name, args, state.titles)

    state
    |> Map.put(:active_tool, name)
    |> Map.put(:status_line, line)
    |> append_raw_message(%{
      role: :tool,
      tool: name,
      input: args,
      status: :pending,
      summary: nil
    })
    |> broadcast_snapshot()
  end

  defp handle_assistant_event(state, {:tool_finished, name, result}) do
    status = if match?({:error, _}, result), do: :error, else: :ok
    summary = CorpusTools.result_summary(name, result)
    visible_result = visible_tool_result(result)

    state
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, "Thinking")
    |> update_last_pending_tool(name, status, summary, visible_result)
    |> broadcast_snapshot()
  end

  defp handle_assistant_event(state, {:text_delta, ref, text})
       when is_reference(ref) and is_binary(text) do
    if state.pending_ref == ref do
      {chunks, stream_buffer} = StreamBuffer.push(Map.get(state, :stream_buffer), text)
      state = Map.put(state, :stream_buffer, stream_buffer)

      case chunks do
        [] ->
          state

        chunks ->
          state
          |> Map.put(:status_line, "Writing")
          |> append_assistant_delta(IO.iodata_to_binary(chunks))
          |> broadcast_snapshot()
      end
    else
      state
    end
  end

  defp handle_assistant_event(state, _event), do: state

  defp assistant_run_options(%{stream?: true}, chat, ref) do
    [
      stream: true,
      on_text_delta: fn text ->
        GenServer.cast(chat, {:assistant_event, {:text_delta, ref, text}})
      end
    ]
  end

  defp assistant_run_options(_state, _chat, _ref), do: []

  defp append_message(state, role, text) do
    %{state | messages: state.messages ++ [%{role: role, text: text}]}
  end

  defp append_raw_message(state, message) do
    %{state | messages: state.messages ++ [message]}
  end

  defp append_assistant_delta(state, text) do
    case List.pop_at(state.messages, -1) do
      {%{role: :assistant, streaming?: true} = message, messages} ->
        message = Map.update(message, :text, text, &(&1 <> text))
        %{state | messages: messages ++ [message]}

      {_other, _messages} ->
        append_raw_message(state, %{role: :assistant, text: text, streaming?: true})
    end
  end

  defp put_final_assistant_message(state, text) do
    case List.pop_at(state.messages, -1) do
      {%{role: :assistant, streaming?: true} = message, messages} ->
        message =
          message
          |> Map.put(:text, text)
          |> Map.delete(:streaming?)

        %{state | messages: messages ++ [message]}

      {_other, _messages} ->
        append_message(state, :assistant, text)
    end
  end

  defp promote_assistant_message(state, index) when is_integer(index) and index >= 0 do
    case Enum.at(state.messages, index) do
      %{role: :assistant, text: text} = message when is_binary(text) ->
        text = String.trim(text)

        if text == "" do
          {:error, :empty_message}
        else
          attrs = %{
            text: text,
            title: promoted_note_title(text),
            block_ids: Sheaf.BlockRefs.ids_from_text(text),
            agent_iri: state.agent_iri,
            agent_label: agent_label(state.kind),
            session_iri: state.session_iri,
            session_label: session_label(state.kind, state.id),
            conversation_mode: conversation_mode(state.kind, state.allow_notes?)
          }

          case Notes.write(attrs) do
            {:ok, note} ->
              _ = refresh_note_indexes_async(state, note)

              note_result = %{
                id: Id.id_from_iri(note),
                iri: to_string(note)
              }

              state =
                state
                |> update_message(index, Map.put(message, :promoted_note, note_result))
                |> broadcast_snapshot()

              {:ok, note_result, state}

            {:error, reason} ->
              {:error, reason}
          end
        end

      %{role: :assistant} ->
        {:error, :empty_message}

      _other ->
        {:error, :not_found}
    end
  end

  defp promote_assistant_message(_state, _index), do: {:error, :invalid_message_index}

  defp refresh_note_indexes_async(state, note) do
    if Process.whereis(state.task_supervisor) do
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        safe_refresh_note_indexes(note)
      end)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp safe_refresh_note_indexes(note) do
    Sheaf.SearchMaintenance.refresh_notes([note])
  catch
    :exit, _reason -> :ok
  end

  defp update_message(state, index, message) do
    messages = List.replace_at(state.messages, index, message)
    %{state | messages: messages}
  end

  defp promoted_note_title(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/^[#*\s]+/, "")
    |> String.trim()
    |> case do
      "" -> "Promoted assistant response"
      title -> if String.length(title) > 90, do: String.slice(title, 0, 87) <> "...", else: title
    end
  end

  defp update_last_pending_tool(state, name, status, summary, result) do
    {messages, _updated?} =
      state.messages
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn msg, updated? ->
        if not updated? and tool_pending?(msg, name) do
          {Map.merge(msg, %{status: status, summary: summary, result: result}), true}
        else
          {msg, updated?}
        end
      end)

    %{state | messages: Enum.reverse(messages)}
  end

  defp visible_tool_result({:ok, %ReqLLM.ToolResult{} = result}) do
    result
    |> Map.get(:metadata, %{})
    |> sheaf_result_from_metadata()
  end

  defp visible_tool_result({:ok, result}), do: result
  defp visible_tool_result(_result), do: nil

  defp tool_pending?(msg, name) do
    Map.get(msg, :role) == :tool and
      Map.get(msg, :tool) == name and
      Map.get(msg, :status) == :pending
  end

  defp maybe_title_from(%{messages: []} = state, text) do
    if state.title == default_title(state.kind) do
      %{state | title: title_from_text(text)}
    else
      state
    end
  end

  defp maybe_title_from(state, _text), do: state

  defp persist_user_message(state, text) do
    message_iri = Sheaf.mint()

    _result =
      write_activity(state.activity_writer, :write_user_message, %{
        message_iri: message_iri,
        session_iri: state.session_iri,
        session_label: session_label(state.kind, state.id),
        conversation_mode: conversation_mode(state.kind, state.allow_notes?),
        text: text
      })

    %{state | last_user_message_iri: message_iri}
  end

  defp persist_assistant_message(state, text) do
    _result =
      write_activity(state.activity_writer, :write_assistant_message, %{
        actor_iri: state.agent_iri,
        model_name: state.model,
        session_iri: state.session_iri,
        session_label: session_label(state.kind, state.id),
        conversation_mode: conversation_mode(state.kind, state.allow_notes?),
        in_reply_to: state.last_user_message_iri,
        text: text
      })

    state
  end

  defp write_activity(nil, _function, _attrs), do: :ok
  defp write_activity(false, _function, _attrs), do: :ok

  defp write_activity(writer, function, attrs) when is_atom(writer) do
    apply(writer, function, [attrs])
  end

  defp put_context_tools(%Context{} = context, tools) when is_list(tools) do
    %{context | tools: tools}
  end

  defp persisted_context(nil, _session_iri), do: nil
  defp persisted_context(false, _session_iri), do: nil

  defp persisted_context(store, session_iri) when is_atom(store) do
    case store.read(session_iri) do
      {:ok, %Context{} = context} -> context
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp persisted_context({store, opts}, session_iri) when is_atom(store) and is_list(opts) do
    case store.read(session_iri, opts) do
      {:ok, %Context{} = context} -> context
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp persist_context_with_input(state, input) do
    case Assistant.context(state.assistant) do
      %Context{} = context ->
        persist_context_value(state, Context.append(context, input))

      _other ->
        state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp persist_context(state) do
    state =
      case Assistant.context(state.assistant) do
        %Context{} = context -> persist_context_value(state, context)
        _other -> state
      end

    state
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp persist_context_value(state, context) do
    case context_store(state) do
      store when store in [nil, false] ->
        state

      store when is_atom(store) ->
        _ = store.write(state.session_iri, context)
        state

      {store, opts} when is_atom(store) and is_list(opts) ->
        _ = store.write(state.session_iri, context, opts)
        state
    end
  end

  defp context_store(state), do: Map.get(state, :context_store, ContextStore)

  defp default_title(_kind), do: "Assistant conversation"

  defp session_label(_kind, id), do: "Assistant conversation #{id}"

  defp agent_label(:edit), do: "Sheaf edit assistant"
  defp agent_label(_kind), do: "Sheaf research assistant"

  defp tool_set(:edit), do: :edit
  defp tool_set(_kind), do: :default

  defp conversation_mode(:edit, _allow_notes?), do: "edit"
  defp conversation_mode(:research, _allow_notes?), do: "research"
  defp conversation_mode(_kind, true), do: "research"
  defp conversation_mode(_kind, _allow_notes?), do: "quick"

  defp normalize_kind(:edit), do: :edit
  defp normalize_kind("edit"), do: :edit
  defp normalize_kind(:research), do: :research
  defp normalize_kind("research"), do: :research
  defp normalize_kind(_kind), do: :chat

  defp title_from_text(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> truncate(48)
  end

  defp maybe_title_from_context(title, kind, messages) do
    if title == default_title(kind) do
      messages
      |> Enum.find(&(Map.get(&1, :role) == :user))
      |> case do
        %{text: text} when is_binary(text) -> title_from_text(text)
        _other -> title
      end
    else
      title
    end
  end

  defp visible_messages_from_context(%Context{} = context, titles) do
    context.messages
    |> Enum.reduce([], &append_visible_message(&2, &1, titles))
  end

  defp append_visible_message(messages, %{role: :system}, _titles), do: messages

  defp append_visible_message(messages, %{role: :user} = message, _titles) do
    append_if_text(messages, :user, message_text(message))
  end

  defp append_visible_message(
         messages,
         %{role: :assistant, tool_calls: tool_calls} = message,
         titles
       )
       when is_list(tool_calls) do
    messages
    |> append_if_text(:assistant, message_text(message))
    |> then(fn messages ->
      Enum.reduce(tool_calls, messages, fn tool_call, messages ->
        {name, args, id} = tool_call_view(tool_call)

        messages ++
          [
            %{
              role: :tool,
              tool: name,
              input: args,
              status: :pending,
              summary: nil,
              tool_call_id: id,
              status_line: CorpusTools.humanize(name, args, titles)
            }
          ]
      end)
    end)
  end

  defp append_visible_message(messages, %{role: :assistant} = message, _titles) do
    append_if_text(messages, :assistant, message_text(message))
  end

  defp append_visible_message(messages, %{role: :tool} = message, _titles) do
    update_visible_tool_result(messages, message)
  end

  defp append_visible_message(messages, _message, _titles), do: messages

  defp append_if_text(messages, _role, ""), do: messages
  defp append_if_text(messages, role, text), do: messages ++ [%{role: role, text: text}]

  defp update_visible_tool_result(messages, message) do
    name = Map.get(message, :name)
    id = Map.get(message, :tool_call_id)
    result = message |> Map.get(:metadata, %{}) |> sheaf_result_from_metadata()
    summary = if name && result, do: CorpusTools.result_summary(name, {:ok, result})

    {messages, updated?} =
      messages
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn msg, updated? ->
        cond do
          updated? ->
            {msg, updated?}

          Map.get(msg, :role) == :tool and Map.get(msg, :tool_call_id) == id ->
            {Map.merge(msg, %{status: :ok, summary: summary, result: result}), true}

          true ->
            {msg, updated?}
        end
      end)

    messages = Enum.reverse(messages)

    if updated? do
      messages
    else
      messages ++
        [%{role: :tool, tool: name, input: %{}, status: :ok, summary: summary, result: result}]
    end
  end

  defp message_text(%{content: content} = message) when is_list(content) do
    case message_metadata_text(message) do
      text when is_binary(text) and text != "" ->
        text

      _other ->
        content
        |> Enum.filter(&(Map.get(&1, :type) == :text))
        |> Enum.map_join("", &(Map.get(&1, :text) || ""))
        |> String.trim()
    end
  end

  defp message_text(_message), do: ""

  defp message_metadata_text(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :sheaf_user_text) || Map.get(metadata, "sheaf_user_text")
  end

  defp message_metadata_text(_message), do: nil

  defp tool_call_view(%ReqLLM.ToolCall{} = tool_call) do
    {
      ReqLLM.ToolCall.name(tool_call),
      ReqLLM.ToolCall.args_map(tool_call) || %{},
      tool_call.id
    }
  end

  defp tool_call_view(%{id: id, name: name, arguments: args}) do
    {name, args || %{}, id}
  end

  defp tool_call_view(%{"id" => id, "name" => name, "arguments" => args}) do
    {name, args || %{}, id}
  end

  defp sheaf_result_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :sheaf_result) || Map.get(metadata, "sheaf_result")
  end

  defp sheaf_result_from_metadata(_metadata), do: nil

  defp truncate(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 3) <> "..."
  end

  defp user_input(text, turn_context) do
    metadata = %{
      sheaf_user_text: text,
      sheaf_turn_context: turn_context
    }

    context_sections =
      []
      |> maybe_add_working_document(turn_context)
      |> maybe_add_open_document(turn_context)
      |> maybe_add_selected(turn_context)

    case context_sections do
      [] ->
        Context.user(text, metadata)

      sections ->
        Context.user(
          """
          [context for this turn]
          #{Enum.join(sections, "\n\n")}

          #{text}
          """,
          metadata
        )
    end
  end

  defp maybe_add_working_document(lines, turn_context) do
    case context_document(turn_context, :working_document) ||
           context_document(turn_context, :open_document) do
      nil -> lines
      document -> lines ++ [working_document_context(document)]
    end
  end

  defp maybe_add_open_document(lines, turn_context) do
    open_document = context_document(turn_context, :open_document)
    working_document = context_document(turn_context, :working_document) || open_document

    cond do
      is_nil(open_document) ->
        lines

      same_document?(open_document, working_document) ->
        lines ++ ["The user has this document open."]

      true ->
        lines ++ [open_document_context(open_document)]
    end
  end

  defp working_document_context(%{title: title, kind: kind, id: id}) do
    """
    The user is working on:
      #{document_context_line(title, kind, id)}
    """
    |> String.trim()
  end

  defp open_document_context(%{title: title, kind: kind, id: id}) do
    """
    The user has open:
      #{document_context_line(title, kind, id)}
    """
    |> String.trim()
  end

  defp document_context_line(title, kind, id) do
    [title, "(##{id}, #{kind})"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp context_document(turn_context, key) do
    case context_value(turn_context, key) do
      %{title: _title, kind: _kind, id: _id} = document ->
        document

      %{"title" => title, "kind" => kind, "id" => id} ->
        %{title: title, kind: kind, id: id}

      _other ->
        nil
    end
  end

  defp same_document?(%{id: id}, %{id: id}), do: true
  defp same_document?(_left, _right), do: false

  defp maybe_add_selected(lines, %{selected_block_context: text})
       when is_binary(text) and text != "" do
    lines ++ [text]
  end

  defp maybe_add_selected(lines, %{"selected_block_context" => text})
       when is_binary(text) and text != "" do
    lines ++ [text]
  end

  defp maybe_add_selected(lines, %{selected_id: selected_id})
       when is_binary(selected_id) and selected_id != "" do
    lines ++ ["Selected block: ##{selected_id}"]
  end

  defp maybe_add_selected(lines, %{"selected_id" => selected_id})
       when is_binary(selected_id) and selected_id != "" do
    lines ++ ["Selected block: ##{selected_id}"]
  end

  defp maybe_add_selected(lines, _turn_context), do: lines

  defp context_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp context_value(_value, _key), do: nil

  defp blank_to_default(nil), do: "(no text response)"
  defp blank_to_default(""), do: "(no text response)"
  defp blank_to_default(text), do: text

  defp put_subscriber(state, live_view, component, component_id) do
    key = {live_view, component, component_id}

    if Map.has_key?(state.subscribers, key) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, key, Process.monitor(live_view))}
    end
  end

  defp delete_subscriber(state, key) do
    case Map.pop(state.subscribers, key) do
      {nil, _subscribers} ->
        state

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: subscribers}
    end
  end

  defp broadcast_snapshot(state) do
    snapshot = snapshot_from_state(state)

    Enum.each(state.subscribers, fn {{live_view, component, component_id}, _ref} ->
      Phoenix.LiveView.send_update(live_view, component,
        id: component_id,
        chat_snapshot: snapshot
      )
    end)

    state
  end

  defp touch_index(state) do
    if Process.whereis(Chats) do
      Chats.touch(state.id, title: state.title)
    end

    state
  end

  defp snapshot_from_state(state) do
    %{
      id: state.id,
      title: state.title,
      kind: state.kind,
      model: state.model,
      llm_options: state.llm_options,
      messages: snapshot_messages(state),
      pending: not is_nil(state.pending_ref),
      active_tool: state.active_tool,
      status_line: state.status_line,
      titles: state.titles,
      error: state.error
    }
  end

  defp snapshot_messages(%{pending_ref: nil, messages: messages} = state) do
    if missing_visible_tool_results?(messages) do
      case Assistant.context(state.assistant) do
        %Context{} = context -> visible_messages_from_context(context, state.titles)
        _other -> messages
      end
    else
      messages
    end
  rescue
    _exception -> state.messages
  catch
    _kind, _reason -> state.messages
  end

  defp snapshot_messages(state), do: state.messages

  defp missing_visible_tool_results?(messages) do
    Enum.any?(messages, fn message ->
      Map.get(message, :role) == :tool and Map.get(message, :status) == :ok and
        not Map.has_key?(message, :result)
    end)
  end

  defp server_ref(pid) when is_pid(pid), do: pid
  defp server_ref(id) when is_binary(id), do: via(id)

  defp system_prompt(kind, allow_notes?, workspace_instructions) do
    """
    You are an assistant embedded in Sheaf, a reading and writing environment
    for a thesis project. Be concrete and help the user move the work forward.

    Project context:
    #{workspace_instructions}

    Every document, section, paragraph, and extracted block has
    a stable 6-character id like HCFU75. These are block ids. Your responses are
    rendered as markdown and Sheaf automatically links block references.
    When you reference a block, use a simple inline hash id such as #HCFU75;
    do not write explicit markdown links.

    Block kinds:
      * section   — headed container; has a title but no direct text
      * paragraph — the author's own thesis prose
      * extracted — a block from a paper PDF; carries a source page number
      * row       — a coded spreadsheet excerpt imported as an RDF document block

    Tool guidance:
      * Use list_documents when you need to know what's in the corpus.
      * Use get_document before drilling into a document; it returns the
        outline so you can pick the right section.
      * Use read for one or more sections, paragraphs, extracted blocks, or
        RDF row blocks. Pass blocks as a list of block ids. Sections and
        documents return child handles by default; set expand=true to read
        their full descendant contents. Paragraphs, extracted blocks, and rows
        return text. Every block comes back with its ancestry or inline block
        tag so you can orient yourself and cite it.
      * Use search_text to find where a concept or phrase appears. It combines
        exact text matching with embedding search over the RDF document corpus,
        including imported coded rows; pass document_id to scope to one
        document or document_kind to scope to a document type such as thesis,
        literature, or spreadsheet.
      * Use tag_paragraphs to attach writing-attention tags to thesis paragraph
        blocks that are placeholders, fragments, need evidence, or need
        revision. Pass all relevant paragraph ids in blocks and choose from
        placeholder, needs_evidence, needs_revision, and fragment.
    #{edit_tool_prompt(kind)}
    #{note_tool_prompt(allow_notes?)}

    How to help:
      * Skim papers and report the argument, method, and relevance to the
        thesis so the user can decide whether to read in full.
      * When the user is stuck on a thesis paragraph, search for supporting or
        contrasting passages in the papers and propose concrete quotes with
        block ids.
      * Clarify concepts from the project's theoretical framework, grounded in
        the actual corpus when possible.
      * Keep answers short by default; go deeper only when she asks.
      * Do not end by offering optional follow-up help like "If you want, I can
        also...". Finish with the answer or the concrete next step already
        taken.
      * When you cite, use simple hash block ids: "(Evans 2020, #4C3K1P)" for
        papers, or "(#4C3K1P)" for her own prose.

    The user message may include a [context for this turn] block naming the
    document currently open and any block the user has selected. Treat
    this as a hint, not a scope restriction — you can navigate elsewhere.

    #{mode_prompt(kind, allow_notes?)}
    """
  end

  defp workspace_instructions do
    case Sheaf.Workspace.assistant_instructions() do
      {:ok, instructions} when is_binary(instructions) -> instructions
      _other -> default_workspace_instructions()
    end
  rescue
    _error -> default_workspace_instructions()
  end

  defp default_workspace_instructions do
    """
    The workspace contains a thesis draft and related research materials. Treat
    the current corpus as authoritative project context, use the Sheaf tools to
    inspect documents and blocks before making specific claims, and adapt your
    help to the document the user is actively working on.
    """
    |> String.trim()
  end

  defp note_tool_prompt(true) do
    """
      * Use write_note to persist durable research notes when you find an
        observation, quote candidate, conceptual link, paper summary, or
        reading-plan decision that should survive this chat. Put every related
        block id in block_ids, and also write those block ids inline in the note
        text using simple ids such as #HCFU75.
    """
  end

  defp note_tool_prompt(false), do: ""

  defp edit_tool_prompt(:edit) do
    """
      * Use update_block_text to replace a paragraph's full text or change a
        section heading title when the user asks for a concrete edit.
      * Use move_block to move or reparent an existing block. For example, use
        position=after to make one block the next sibling of another.
      * Use insert_paragraph to add a new paragraph block at a specified place.
      * Use delete_block to remove an existing block. Deleting a section also
        deletes all descendant blocks.
      * After update_block_text, move_block, insert_paragraph, or delete_block,
        call update_search_index with the edited, moved, inserted, or deleted
        affected block ids so embeddings and full-text search reflect the
        changed draft.
    """
  end

  defp edit_tool_prompt(_kind), do: ""

  defp mode_prompt(:edit, _allow_notes?) do
    """
    Edit mode:
      * Treat the user message as a specific editing instruction for an
        existing thesis draft, not as an open-ended research task.
      * If the target draft or block is ambiguous, inspect the documents and
        relevant block context before editing. The workspace may contain both a
        draft-tagged and a mikael-tagged active thesis draft.
      * Make only the requested edits. Do not rewrite neighboring paragraphs
        unless the user explicitly asks.
      * After applying edit tools and update_search_index, finish with a short
        confirmation naming the changed block ids.
    """
  end

  defp mode_prompt(:research, true) do
    """
    Research mode:
      * Treat the first user message as a research question, paper-reading
        assignment, or exploration brief.
      * Work through the corpus with the available tools and write durable
        notes for findings that should be kept.
      * It is fine to make several tool calls before answering. Keep the chat
        updated through tool status and finish with a concise progress report.
    """
  end

  defp mode_prompt(:research, false) do
    """
    Research mode:
      * Treat the first user message as a research question, paper-reading
        assignment, or exploration brief.
      * Work through the corpus with the available tools and finish with a
        concise progress report.
    """
  end

  defp mode_prompt(_kind, _allow_notes?) do
    """
    Chat mode:
      * Answer the user's immediate question directly.
    """
  end
end
