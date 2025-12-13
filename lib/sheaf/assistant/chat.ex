defmodule Sheaf.Assistant.Chat do
  @moduledoc """
  Long-lived assistant chat session.

  A chat owns the assistant process, visible message log, current pending
  status, and LiveComponent subscriptions. The LiveView can disconnect or
  reload without losing this process-local conversation state.
  """

  use GenServer

  alias ReqLLM.{Context, Response}
  alias Sheaf.Assistant
  alias Sheaf.Assistant.{Activity, Chats, CorpusTools}
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
    titles: %{}
  ]

  @type snapshot :: %{
          id: String.t(),
          title: String.t(),
          kind: :chat | :research,
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
    titles = Keyword.get_lazy(opts, :titles, &CorpusTools.titles/0)
    session_iri = Keyword.get_lazy(opts, :session_iri, fn -> Id.iri(id) end)
    agent_iri = Keyword.get_lazy(opts, :agent_iri, &Sheaf.mint/0)
    activity_writer = Keyword.get(opts, :activity_writer, Activity)

    workspace_instructions =
      Keyword.get_lazy(opts, :workspace_instructions, &workspace_instructions/0)

    allow_notes? =
      Keyword.get(opts, :allow_notes?, Keyword.get(opts, :allow_notes, kind == :research))

    context =
      Context.new([Context.system(system_prompt(kind, allow_notes?, workspace_instructions))])

    tools =
      CorpusTools.tools(
        include_notes?: allow_notes?,
        notify: fn event -> GenServer.cast(chat, {:assistant_event, event}) end,
        note_context: %{
          agent_iri: agent_iri,
          agent_label: "Sheaf research assistant",
          session_iri: session_iri,
          session_label: session_label(kind, id),
          conversation_mode: conversation_mode(kind, allow_notes?)
        }
      )

    case Assistant.start_link(
           model: model,
           context: context,
           tools: tools,
           max_tool_rounds: max_tool_rounds,
           llm_options: llm_options,
           task_supervisor: task_supervisor,
           generate_text: generate_text
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
           allow_notes?: allow_notes?,
           model: model,
           llm_options: llm_options,
           max_tool_rounds: max_tool_rounds,
           task_supervisor: task_supervisor,
           generate_text: generate_text,
           titles: titles
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_from_state(state), state}
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
    state = maybe_title_from(state, text)
    state = persist_user_message(state, text)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           result = safe_run(assistant, input)
           send(chat, {:assistant_result, ref, result})
         end) do
      {:ok, _pid} ->
        state
        |> Map.put(:pending_ref, ref)
        |> Map.put(:status_line, "Thinking")
        |> append_message(:user, text)
        |> touch_index()
        |> broadcast_snapshot()

      {:error, reason} ->
        state
        |> append_message(:error, "Could not start assistant turn: #{inspect(reason)}")
        |> broadcast_snapshot()
    end
  end

  defp safe_run(assistant, input) do
    Assistant.run(assistant, input)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp handle_assistant_result(state, {:ok, %Response{} = response}) do
    text = Response.text(response) |> blank_to_default()

    state
    |> persist_assistant_message(text)
    |> Map.put(:pending_ref, nil)
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, nil)
    |> append_message(:assistant, text)
    |> touch_index()
    |> broadcast_snapshot()
  end

  defp handle_assistant_result(state, {:error, reason}) do
    state
    |> Map.put(:pending_ref, nil)
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, nil)
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

    state
    |> Map.put(:active_tool, nil)
    |> Map.put(:status_line, "Thinking")
    |> update_last_pending_tool(name, status, summary)
    |> broadcast_snapshot()
  end

  defp handle_assistant_event(state, _event), do: state

  defp append_message(state, role, text) do
    %{state | messages: state.messages ++ [%{role: role, text: text}]}
  end

  defp append_raw_message(state, message) do
    %{state | messages: state.messages ++ [message]}
  end

  defp update_last_pending_tool(state, name, status, summary) do
    {messages, _updated?} =
      state.messages
      |> Enum.reverse()
      |> Enum.map_reduce(false, fn msg, updated? ->
        if not updated? and tool_pending?(msg, name) do
          {Map.merge(msg, %{status: status, summary: summary}), true}
        else
          {msg, updated?}
        end
      end)

    %{state | messages: Enum.reverse(messages)}
  end

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

  defp default_title(_kind), do: "Assistant conversation"

  defp session_label(_kind, id), do: "Assistant conversation #{id}"

  defp conversation_mode(:research, _allow_notes?), do: "research"
  defp conversation_mode(_kind, true), do: "research"
  defp conversation_mode(_kind, _allow_notes?), do: "quick"

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

  defp truncate(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 3) <> "..."
  end

  defp user_input(text, turn_context) do
    context_sections =
      []
      |> maybe_add_working_document(turn_context)
      |> maybe_add_open_document(turn_context)
      |> maybe_add_selected(turn_context)

    case context_sections do
      [] ->
        Context.user(text)

      sections ->
        Context.user("""
        [context for this turn]
        #{Enum.join(sections, "\n\n")}

        #{text}
        """)
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
      messages: state.messages,
      pending: not is_nil(state.pending_ref),
      active_tool: state.active_tool,
      status_line: state.status_line,
      titles: state.titles,
      error: state.error
    }
  end

  defp server_ref(pid) when is_pid(pid), do: pid
  defp server_ref(id) when is_binary(id), do: via(id)

  defp system_prompt(kind, allow_notes?, workspace_instructions) do
    """
    You are a research assistant embedded in Sheaf, a reading and writing
    environment for a thesis project. Be concrete and help the user move the
    work forward.

    Project context:
    #{workspace_instructions}

    Every document, section, paragraph, and extracted block has
    a stable 6-character id like HCFU75. These are block ids. Your responses are
    rendered as markdown and Sheaf automatically links plain block references.
    When you reference a block, use a simple inline id such as #HCFU75 or
    (HCFU75); do not write explicit markdown links.

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
        document or document_kind to scope to a document type.
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
      * When you cite, use simple block ids: "(Evans 2020, #4C3K1P)" for
        papers, "(#4C3K1P)" for her own prose, or "(4C3K1P)" when the hash
        would read awkwardly.

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
