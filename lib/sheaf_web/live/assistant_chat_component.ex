defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Corpus-aware assistant chat component.

  The component renders and controls a selected `Sheaf.Assistant.Chat`
  process. Conversation state lives in OTP processes so reloads and multiple
  LiveViews can subscribe to the same chat.
  """

  use SheafWeb, :live_component

  alias Sheaf.BlockRefs
  alias Sheaf.Assistant.{Chat, Chats, CorpusTools}
  alias Sheaf.{Document, Id}

  @mdex_opts [
    extension: [
      strikethrough: true,
      autolink: true,
      table: true,
      tasklist: true
    ],
    render: [unsafe_: false, hardbreaks: true],
    parse: [smart: true]
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:chats, [])
     |> assign(:chat, empty_chat())
     |> assign(:selected_chat_id, nil)
     |> assign(:subscribed_chat_id, nil)
     |> assign(:chats_subscribed?, false)
     |> assign(:mode, "quick")
     |> assign(:form, chat_form())}
  end

  @impl true
  def update(%{chat_snapshot: snapshot}, socket) do
    socket =
      if socket.assigns.selected_chat_id == snapshot.id do
        socket
        |> assign(:chat, snapshot)
        |> maybe_refresh_chat_list()
      else
        maybe_refresh_chat_list(socket)
      end

    {:ok, socket}
  end

  def update(%{assistant_chats: chats}, socket) do
    socket =
      socket
      |> assign(:chats, chats)

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:model, fn -> Sheaf.LLM.default_model() end)
      |> assign_new(:llm_options, fn -> [] end)
      |> assign_new(:variant, fn -> :full end)
      |> maybe_ensure_chat_index_subscription()
      |> maybe_ensure_selected_chat()

    {:ok, socket}
  end

  @impl true
  def handle_event("select_chat", %{"id" => id}, socket) do
    socket =
      if chat_listed?(socket.assigns.chats, id) do
        select_chat(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("set_mode", %{"chat" => %{"mode" => mode}}, socket) do
    mode = normalize_mode(mode)
    {:noreply, socket |> assign(:mode, mode) |> assign(:form, chat_form(mode))}
  end

  def handle_event("send", %{"chat" => %{"message" => message} = chat_params}, socket) do
    mode = Map.get(chat_params, "mode", socket.assigns.mode)
    message = String.trim(message)
    mode = normalize_mode(mode)

    cond do
      message == "" ->
        {:noreply, socket |> assign(:mode, mode) |> assign(:form, chat_form(mode))}

      socket.assigns.chat.pending ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> assign(:mode, mode)
          |> ensure_sendable_chat(mode)

        socket =
          if is_nil(socket.assigns.selected_chat_id) do
            put_local_error(socket, "No assistant chat is selected.")
          else
            case Chat.send_user_message(
                   socket.assigns.selected_chat_id,
                   message,
                   turn_context(socket.assigns)
                 ) do
              :ok ->
                assign(socket, :form, chat_form(mode))

              {:error, :busy} ->
                socket

              {:error, :empty_message} ->
                assign(socket, :form, chat_form(mode))

              {:error, reason} ->
                put_local_error(socket, "Assistant error: #{inspect(reason)}")
            end
          end

        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class={assistant_section_class(@variant, @selected_chat_id)}>
      <.form
        for={@form}
        phx-change="set_mode"
        phx-submit="send"
        phx-target={@myself}
        class="space-y-2"
      >
        <textarea
          name="chat[message]"
          rows="1"
          class="block max-h-40 min-h-9 w-full resize-none overflow-y-auto rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm leading-5 text-stone-950 outline-none transition-colors [field-sizing:content] placeholder:text-stone-400 focus:border-stone-500 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:placeholder:text-stone-500 dark:focus:border-stone-500"
          placeholder={input_placeholder(@mode)}
          disabled={@chat.pending}
        ></textarea>
        <div class="flex items-center justify-between gap-3">
          <div class="inline-flex items-center gap-1 font-sans text-xs">
            <label class={mode_label_class(@mode, "quick")}>
              <input
                type="radio"
                name="chat[mode]"
                value="quick"
                checked={@mode == "quick"}
                class="sr-only"
              />
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-3.5" />
              <span>Quick</span>
            </label>
            <label class={mode_label_class(@mode, "research")}>
              <input
                type="radio"
                name="chat[mode]"
                value="research"
                checked={@mode == "research"}
                class="sr-only"
              />
              <.icon name="hero-beaker" class="size-3.5" />
              <span>Research</span>
            </label>
          </div>
          <button
            type="submit"
            class="grid size-8 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 disabled:cursor-not-allowed disabled:text-stone-300 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50 dark:disabled:text-stone-700"
            title="Send"
            aria-label="Send"
            disabled={@chat.pending}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </.form>

      <div
        :if={not inline?(@variant) and @selected_chat_id}
        class="mt-3 max-h-80 min-h-0 space-y-2 overflow-y-auto pr-1 text-sm"
      >
        <.chat_message
          :for={message <- @chat.messages}
          message={message}
          titles={Map.get(@chat, :titles, %{})}
        />

        <div
          :if={@chat.pending}
          class="flex items-center gap-2 px-1 py-2 text-sm leading-5 text-stone-500 dark:text-stone-400"
        >
          <span class="size-2.5 shrink-0 animate-pulse rounded-full bg-stone-500 dark:bg-stone-300">
          </span>
          <span class="min-w-0 flex-1 truncate">{@chat.status_line || "Thinking"}</span>
        </div>
      </div>
    </section>
    """
  end

  attr :message, :map, required: true
  attr :titles, :map, default: %{}

  defp chat_message(%{message: %{role: :user}} = assigns) do
    ~H"""
    <div class="rounded-sm bg-stone-200/70 px-3 py-1.5 text-sm leading-snug text-stone-950 dark:bg-stone-800 dark:text-stone-50">
      <div class="whitespace-pre-line break-words">{@message.text}</div>
    </div>
    """
  end

  defp chat_message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="assistant-prose break-words px-1 text-xs text-stone-900 dark:text-stone-100">
      {raw(render_markdown(@message.text))}
    </div>
    """
  end

  defp chat_message(%{message: %{role: :tool}} = assigns) do
    assigns = assign(assigns, :tool_view, tool_view(assigns.message, assigns.titles))

    ~H"""
    <div class="flex gap-2 px-1 py-1 text-xs ">
      <span class="mt-0.5 w-5 shrink-0 text-center text-base ">
        {@tool_view.icon}
      </span>
      <div class="min-w-0 flex-1">
        <div class={["text-stone-700 dark:text-stone-300", @tool_view.status_class]}>
          <span>{@tool_view.action}</span>
          <span :if={@tool_view.target != ""}>{@tool_view.target}</span>
          <span :if={@tool_view.scope != ""}> in <em>{@tool_view.scope}</em></span>
        </div>
        <div
          :if={@tool_view.detail != ""}
          class="mt-0.5 pl-0 text-xs  text-stone-500 dark:text-stone-400"
        >
          {@tool_view.detail}
        </div>
      </div>
    </div>
    """
  end

  defp chat_message(%{message: %{role: :status}} = assigns) do
    ~H"""
    <div class="px-1 py-0.5 font-sans text-[11px] italic leading-5 text-stone-500 dark:text-stone-400">
      {@message.text}
    </div>
    """
  end

  defp chat_message(%{message: %{role: :error}} = assigns) do
    ~H"""
    <div class="rounded-sm bg-red-50/70 px-3 py-1 text-xs leading-5 text-red-800 dark:bg-red-950/30 dark:text-red-300">
      {@message.text}
    </div>
    """
  end

  defp chat_message(assigns), do: ~H""

  defp tool_view(%{tool: "list_documents"} = message, _titles) do
    tool_view("📚", "Checking", "the library", "", message)
  end

  defp tool_view(%{tool: "get_document", input: input} = message, titles) do
    id = tool_arg(input, :id)
    target = "the outline"
    scope = title_or_id(id, titles)

    tool_view("📖", "Reading", target, scope, message)
  end

  defp tool_view(%{tool: "get_block", input: input} = message, titles) do
    doc_id = tool_arg(input, :document_id)
    block_ids = tool_block_ids(input)

    target =
      case block_ids do
        [block_id] -> "block ##{block_id}"
        ids when ids != [] -> "#{length(ids)} blocks"
        _ids -> "a block"
      end

    scope = title_or_id(doc_id, titles)

    tool_view("📄", "Reading", target, scope, message)
  end

  defp tool_view(%{tool: "search_text", input: input} = message, titles) do
    query = tool_arg(input, :query) || ""
    scope = tool_arg(input, :document_id)
    target = "“#{query}”"
    scope = if scope, do: title_or_id(scope, titles), else: "the corpus"

    tool_view("🔍", "Searching for", target, scope, message)
  end

  defp tool_view(%{tool: "write_note", input: input} = message, _titles) do
    title = tool_arg(input, :title) || tool_arg(input, :text)

    target =
      if is_binary(title) and String.trim(title) != "",
        do: "“#{ellipsize(title, 60)}”",
        else: "a research note"

    tool_view("📝", "Saving", target, "", message)
  end

  defp tool_view(%{tool: tool} = message, _titles) when is_binary(tool) do
    tool_view("⚙️", "Using", String.replace(tool, "_", " "), "", message)
  end

  defp tool_view(message, _titles), do: tool_view("⚙️", "Using", "a tool", "", message)

  defp tool_view(icon, action, target, scope, message) do
    %{
      icon: icon,
      action: action,
      target: target || "",
      scope: scope || "",
      detail: tool_detail(message),
      status_class: tool_phrase_class(Map.get(message, :status))
    }
  end

  defp tool_detail(%{status: :pending}), do: "working…"
  defp tool_detail(%{status: :ok, summary: summary}) when summary in [nil, ""], do: "done"
  defp tool_detail(%{status: :ok, summary: summary}), do: detail_text(summary)
  defp tool_detail(%{status: :error, summary: summary}) when summary in [nil, ""], do: "error"
  defp tool_detail(%{status: :error, summary: summary}), do: detail_text(summary)
  defp tool_detail(_), do: ""

  defp detail_text("“" <> _ = summary), do: summary
  defp detail_text(summary), do: "(" <> summary <> ")"

  defp tool_phrase_class(:error), do: "text-red-700 dark:text-red-300"
  defp tool_phrase_class(_), do: ""

  defp title_or_id(nil, _titles), do: ""

  defp title_or_id(id, titles) do
    case Map.get(titles, id) do
      nil -> "##{id}"
      title -> ellipsize(title, 60)
    end
  end

  defp tool_arg(input, key) when is_map(input) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  defp tool_arg(_, _), do: nil

  defp tool_block_ids(input) do
    ids =
      case tool_arg(input, :block_ids) do
        ids when is_list(ids) -> ids
        id when is_binary(id) -> [id]
        _other -> []
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case ids do
      [] ->
        input
        |> tool_arg(:block_id)
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      ids ->
        ids
    end
  end

  defp ellipsize(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp maybe_refresh_chat_list(socket) do
    if history_enabled?(socket.assigns) do
      assign(socket, :chats, Chats.list())
    else
      socket
    end
  end

  defp maybe_ensure_chat_index_subscription(socket) do
    if history_enabled?(socket.assigns) do
      ensure_chat_index_subscription(socket)
    else
      socket
    end
  end

  defp maybe_ensure_selected_chat(socket), do: socket

  defp ensure_chat_index_subscription(%{assigns: %{chats_subscribed?: true}} = socket), do: socket

  defp ensure_chat_index_subscription(socket) do
    socket
    |> assign(:chats, Chats.subscribe(self(), __MODULE__, socket.assigns.id))
    |> assign(:chats_subscribed?, true)
  end

  defp ensure_sendable_chat(%{assigns: %{selected_chat_id: id}} = socket, _mode)
       when is_binary(id),
       do: socket

  defp ensure_sendable_chat(socket, mode), do: create_conversation_for_send(socket, mode)

  defp create_conversation_for_send(socket, mode) do
    kind = mode_kind(mode)

    case Chats.create(
           Keyword.put(chat_options(socket, kind), :listed?, history_enabled?(socket.assigns))
         ) do
      %{id: id} ->
        socket
        |> assign(:chats, Chats.list())
        |> select_chat(id)

      {:error, reason} ->
        put_local_error(socket, "Could not start assistant chat: #{inspect(reason)}")
    end
  end

  defp select_chat(socket, id) do
    socket
    |> unsubscribe_from_previous_chat(id)
    |> assign(:selected_chat_id, id)
    |> subscribe_to_chat(id)
  end

  defp subscribe_to_chat(socket, id) do
    snapshot = Chat.subscribe(id, self(), __MODULE__, socket.assigns.id)

    socket
    |> assign(:subscribed_chat_id, id)
    |> assign(:chat, snapshot)
    |> assign(:mode, chat_mode(snapshot))
  end

  defp unsubscribe_from_previous_chat(%{assigns: %{subscribed_chat_id: old_id}} = socket, new_id)
       when is_binary(old_id) and old_id != new_id do
    Chat.unsubscribe(old_id, self(), __MODULE__, socket.assigns.id)
    socket
  end

  defp unsubscribe_from_previous_chat(socket, _new_id), do: socket

  defp chat_options(socket, kind) do
    options = [
      kind: kind,
      model: socket.assigns.model,
      llm_options: socket.assigns.llm_options
    ]

    case assistant_allow_notes(socket.assigns, kind) do
      {:ok, allow_notes?} -> Keyword.put(options, :allow_notes, allow_notes?)
      :error -> options
    end
  end

  defp assistant_allow_notes(assigns, kind) do
    case Map.fetch(assigns, :allow_notes) do
      {:ok, allow_notes?} -> {:ok, allow_notes?}
      :error -> Map.fetch(assigns, :allow_notes?)
    end
    |> case do
      :error -> {:ok, kind == :research}
      other -> other
    end
  end

  defp history_enabled?(assigns), do: not inline?(assigns.variant)

  defp inline?(:inline), do: true
  defp inline?(:compact), do: true
  defp inline?("inline"), do: true
  defp inline?("compact"), do: true
  defp inline?(_variant), do: false

  defp assistant_section_class(variant, selected_chat_id) do
    cond do
      inline?(variant) and is_nil(selected_chat_id) ->
        "py-3"

      inline?(variant) ->
        "flex flex-col py-3"

      true ->
        "flex flex-col pt-2"
    end
  end

  defp normalize_mode("research"), do: "research"
  defp normalize_mode(_mode), do: "quick"

  defp mode_kind("research"), do: :research
  defp mode_kind(_mode), do: :chat

  defp mode_label_class(selected_mode, mode) do
    [
      "inline-flex cursor-pointer items-center gap-1.5 rounded-sm px-2 py-1 transition-colors",
      selected_mode == mode &&
        "text-stone-900 ring-1 ring-inset ring-stone-400/70 dark:text-stone-50 dark:ring-stone-500/80",
      selected_mode != mode &&
        "text-stone-500 hover:bg-stone-200/70 hover:text-stone-900 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
    ]
  end

  defp chat_listed?(chats, id), do: Enum.any?(chats, &(&1.id == id))

  defp chat_kind(%{kind: :research}), do: :research
  defp chat_kind(%{kind: "research"}), do: :research
  defp chat_kind(_chat), do: :chat

  defp chat_mode(chat) do
    case chat_kind(chat) do
      :research -> "research"
      _kind -> "quick"
    end
  end

  defp input_placeholder("research"), do: "Give the assistant a research task"
  defp input_placeholder(_mode), do: "Ask a quick question"

  defp turn_context(assigns) do
    %{}
    |> maybe_put_open_document(assigns)
    |> maybe_put_selected(assigns)
    |> maybe_put_selected_block_context(assigns)
  end

  defp maybe_put_open_document(context, %{graph: graph, root: root})
       when not is_nil(graph) and not is_nil(root) do
    document = %{
      title: Document.title(graph, root),
      kind: Document.kind(graph, root),
      id: Id.id_from_iri(root)
    }

    context
    |> Map.put(:working_document, document)
    |> Map.put(:open_document, document)
  end

  defp maybe_put_open_document(context, _assigns), do: context

  defp maybe_put_selected(context, %{selected_id: selected_id})
       when is_binary(selected_id) and selected_id != "" do
    Map.put(context, :selected_id, selected_id)
  end

  defp maybe_put_selected(context, _assigns), do: context

  defp maybe_put_selected_block_context(
         context,
         %{graph: graph, root: root, selected_id: selected_id}
       )
       when not is_nil(graph) and not is_nil(root) and is_binary(selected_id) and
              selected_id != "" do
    case CorpusTools.selected_block_context_text(graph, root, selected_id) do
      {:ok, text} -> Map.put(context, :selected_block_context, text)
      {:error, _reason} -> context
    end
  end

  defp maybe_put_selected_block_context(context, _assigns), do: context

  defp put_local_error(socket, text) do
    update(socket, :chat, fn chat ->
      Map.update!(chat, :messages, &(&1 ++ [%{role: :error, text: text}]))
      |> Map.put(:pending, false)
    end)
  end

  defp render_markdown(text) do
    text
    |> BlockRefs.linkify_markdown()
    |> MDEx.to_html!(@mdex_opts)
  end

  defp chat_form(mode \\ "quick"), do: to_form(%{"message" => "", "mode" => mode}, as: :chat)

  defp empty_chat do
    %{
      id: nil,
      title: "Assistant conversation",
      kind: :chat,
      messages: [],
      pending: false,
      active_tool: nil,
      status_line: nil,
      error: nil
    }
  end
end
