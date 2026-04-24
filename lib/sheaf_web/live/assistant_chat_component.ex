defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Corpus-aware assistant chat component.

  The component renders and controls a selected `Sheaf.Assistant.Chat`
  process. Conversation state lives in OTP processes so reloads and multiple
  LiveViews can subscribe to the same chat.
  """

  use SheafWeb, :live_component

  alias Sheaf.BlockRefs
  alias Sheaf.Assistant.{Chat, Chats}
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
     |> assign(:form, chat_form())}
  end

  @impl true
  def update(%{chat_snapshot: snapshot}, socket) do
    socket =
      if socket.assigns.selected_chat_id == snapshot.id do
        socket
        |> assign(:chat, snapshot)
        |> assign(:chats, Chats.list())
      else
        assign(socket, :chats, Chats.list())
      end

    {:ok, socket}
  end

  def update(%{assistant_chats: chats}, socket) do
    socket =
      socket
      |> assign(:chats, chats)
      |> ensure_selected_chat()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:model, fn -> Sheaf.LLM.default_model() end)
      |> assign_new(:llm_options, fn -> [] end)
      |> ensure_chat_index_subscription()
      |> ensure_selected_chat()

    {:ok, socket}
  end

  @impl true
  def handle_event("new_chat", _params, socket) do
    {:noreply, create_chat(socket, :chat)}
  end

  def handle_event("new_research", _params, socket) do
    {:noreply, create_chat(socket, :research)}
  end

  def handle_event("select_chat", %{"id" => id}, socket) do
    socket =
      if chat_listed?(socket.assigns.chats, id) do
        select_chat(socket, id)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("send", %{"chat" => %{"message" => message}}, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, assign(socket, :form, chat_form())}

      socket.assigns.chat.pending ->
        {:noreply, socket}

      is_nil(socket.assigns.selected_chat_id) ->
        {:noreply, put_local_error(socket, "No assistant chat is selected.")}

      true ->
        socket =
          case Chat.send_user_message(
                 socket.assigns.selected_chat_id,
                 message,
                 turn_context(socket.assigns)
               ) do
            :ok ->
              assign(socket, :form, chat_form())

            {:error, :busy} ->
              socket

            {:error, :empty_message} ->
              assign(socket, :form, chat_form())

            {:error, reason} ->
              put_local_error(socket, "Assistant error: #{inspect(reason)}")
          end

        {:noreply, socket}
    end
  end

  defp create_chat(socket, kind) do
    case Chats.create(chat_options(socket, kind)) do
      %{id: id} ->
        socket
        |> assign(:chats, Chats.list())
        |> select_chat(id)

      {:error, reason} ->
        put_local_error(socket, "Could not start chat: #{inspect(reason)}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="flex min-h-[24rem] flex-col border-t border-stone-200/80 pt-2 dark:border-stone-800/80">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400">
          Assistant
        </h2>
        <div class="flex items-center gap-2">
          <button
            type="button"
            class="grid size-7 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
            title="New chat"
            aria-label="New chat"
            phx-click="new_chat"
            phx-target={@myself}
          >
            <.icon name="hero-plus" class="size-4" />
          </button>
          <button
            type="button"
            class="grid size-7 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
            title="New research session"
            aria-label="New research session"
            phx-click="new_research"
            phx-target={@myself}
          >
            <.icon name="hero-beaker" class="size-4" />
          </button>
        </div>
      </div>

      <nav
        :if={@chats != []}
        class="mt-3 max-h-28 space-y-1 overflow-y-auto border-y border-stone-200/80 py-2 dark:border-stone-800/80"
      >
        <button
          :for={chat <- @chats}
          type="button"
          class={chat_button_class(chat.id, @selected_chat_id)}
          phx-click="select_chat"
          phx-value-id={chat.id}
          phx-target={@myself}
          title={chat_title(chat)}
        >
          <.icon name={chat_kind_icon(chat)} class={chat_kind_icon_class(chat)} />
          <span class="min-w-0 flex-1 truncate">{chat.title}</span>
          <span
            :if={chat_kind(chat) == :research}
            class="ml-2 shrink-0 rounded-sm border border-emerald-200 px-1.5 py-0.5 text-[0.625rem] uppercase leading-none text-emerald-700 dark:border-emerald-900 dark:text-emerald-300"
          >
            Research
          </span>
        </button>
      </nav>

      <div class="mt-3 min-h-0 flex-1 space-y-2 overflow-y-auto pr-1 text-sm">
        <p :if={@chat.messages == []} class="leading-6 text-stone-500 dark:text-stone-400">
          No messages yet.
        </p>

        <.chat_message
          :for={message <- @chat.messages}
          message={message}
          titles={Map.get(@chat, :titles, %{})}
        />

        <div
          :if={@chat.pending}
          class="flex items-center gap-2 px-1 py-2 text-sm leading-5 text-stone-500 dark:text-stone-400"
        >
          <span class="size-3 shrink-0 animate-spin rounded-full border-2 border-stone-300 border-t-stone-700 dark:border-stone-700 dark:border-t-stone-200">
          </span>
          <span class="min-w-0 flex-1 truncate">{@chat.status_line || "Thinking"}</span>
        </div>
      </div>

      <.form for={@form} phx-submit="send" phx-target={@myself} class="mt-3 space-y-2">
        <textarea
          name="chat[message]"
          rows="3"
          class="block w-full resize-none rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm leading-5 text-stone-950 outline-none transition-colors placeholder:text-stone-400 focus:border-stone-500 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:placeholder:text-stone-500 dark:focus:border-stone-500"
          placeholder={input_placeholder(@chat)}
          disabled={@chat.pending or is_nil(@selected_chat_id)}
        ></textarea>
        <div class="flex justify-end">
          <button
            type="submit"
            class="grid size-8 place-items-center rounded-sm bg-stone-950 text-stone-50 transition-colors hover:bg-stone-700 disabled:cursor-not-allowed disabled:bg-stone-300 disabled:text-stone-500 dark:bg-stone-50 dark:text-stone-950 dark:hover:bg-stone-300 dark:disabled:bg-stone-800 dark:disabled:text-stone-500"
            title="Send"
            aria-label="Send"
            disabled={@chat.pending or is_nil(@selected_chat_id)}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </.form>
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
    <div class="rounded-sm border-l-2 border-red-500 bg-red-50/70 px-3 py-1 text-xs leading-5 text-red-800 dark:bg-red-950/30 dark:text-red-300">
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
    block_id = tool_arg(input, :block_id)
    target = "block ##{block_id || "?"}"
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

  defp ellipsize(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp ensure_chat_index_subscription(%{assigns: %{chats_subscribed?: true}} = socket), do: socket

  defp ensure_chat_index_subscription(socket) do
    socket
    |> assign(:chats, Chats.subscribe(self(), __MODULE__, socket.assigns.id))
    |> assign(:chats_subscribed?, true)
  end

  defp ensure_selected_chat(%{assigns: %{selected_chat_id: id, chats: chats}} = socket)
       when is_binary(id) do
    if chat_listed?(chats, id) do
      subscribe_to_chat(socket, id)
    else
      select_default_chat(socket)
    end
  end

  defp ensure_selected_chat(socket), do: select_default_chat(socket)

  defp select_default_chat(socket) do
    case Chats.ensure_default(chat_options(socket, :chat)) do
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
  end

  defp unsubscribe_from_previous_chat(%{assigns: %{subscribed_chat_id: old_id}} = socket, new_id)
       when is_binary(old_id) and old_id != new_id do
    Chat.unsubscribe(old_id, self(), __MODULE__, socket.assigns.id)
    socket
  end

  defp unsubscribe_from_previous_chat(socket, _new_id), do: socket

  defp chat_options(socket, kind) do
    [
      kind: kind,
      model: socket.assigns.model,
      llm_options: socket.assigns.llm_options
    ]
  end

  defp chat_listed?(chats, id), do: Enum.any?(chats, &(&1.id == id))

  defp chat_button_class(id, selected_id) do
    [
      "flex h-8 w-full items-center gap-2 rounded-sm px-2 text-left font-sans text-xs transition-colors",
      "hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
      id == selected_id && "bg-stone-200/70 text-stone-950 dark:bg-stone-800 dark:text-stone-50",
      id != selected_id && "text-stone-600 dark:text-stone-400"
    ]
  end

  defp chat_title(chat) do
    case chat_kind(chat) do
      :research -> "Research session: #{chat.title}"
      _kind -> chat.title
    end
  end

  defp chat_kind(%{kind: :research}), do: :research
  defp chat_kind(%{kind: "research"}), do: :research
  defp chat_kind(_chat), do: :chat

  defp chat_kind_icon(chat) do
    case chat_kind(chat) do
      :research -> "hero-beaker"
      _kind -> "hero-chat-bubble-left-ellipsis"
    end
  end

  defp chat_kind_icon_class(chat) do
    [
      "size-3.5 shrink-0",
      chat_kind(chat) == :research && "text-emerald-600 dark:text-emerald-300"
    ]
  end

  defp input_placeholder(%{kind: :research}), do: "Give this research session a question"
  defp input_placeholder(%{kind: "research"}), do: "Give this research session a question"
  defp input_placeholder(_chat), do: "Ask about the thesis or the papers"

  defp turn_context(assigns) do
    %{}
    |> maybe_put_open_document(assigns)
    |> maybe_put_selected(assigns)
  end

  defp maybe_put_open_document(context, %{graph: graph, root: root})
       when not is_nil(graph) and not is_nil(root) do
    Map.put(context, :open_document, %{
      title: Document.title(graph, root),
      kind: Document.kind(graph, root),
      id: Id.id_from_iri(root)
    })
  end

  defp maybe_put_open_document(context, _assigns), do: context

  defp maybe_put_selected(context, %{selected_id: selected_id})
       when is_binary(selected_id) and selected_id != "" do
    Map.put(context, :selected_id, selected_id)
  end

  defp maybe_put_selected(context, _assigns), do: context

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

  defp chat_form, do: to_form(%{"message" => ""}, as: :chat)

  defp empty_chat do
    %{
      id: nil,
      title: "New chat",
      kind: :chat,
      messages: [],
      pending: false,
      active_tool: nil,
      status_line: nil,
      error: nil
    }
  end
end
