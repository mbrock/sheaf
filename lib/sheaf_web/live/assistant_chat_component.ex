defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Corpus-aware assistant chat component.

  The component renders and controls a selected `Sheaf.Assistant.Chat`
  process. Conversation state lives in OTP processes so reloads and multiple
  LiveViews can subscribe to the same chat.
  """

  use SheafWeb, :live_component

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
    socket =
      case Chats.create(chat_options(socket)) do
        %{id: id} ->
          socket
          |> assign(:chats, Chats.list())
          |> select_chat(id)

        {:error, reason} ->
          put_local_error(socket, "Could not start chat: #{inspect(reason)}")
      end

    {:noreply, socket}
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

  @impl true
  def render(assigns) do
    ~H"""
    <section class="flex min-h-[24rem] flex-col border-t border-stone-200/80 pt-4 dark:border-stone-800/80">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400">
          Assistant
        </h2>
        <div class="flex items-center gap-2">
          <span
            :if={@chat.pending}
            class="max-w-36 truncate font-sans text-xs italic text-stone-500 dark:text-stone-400"
          >
            {@chat.status_line || "Thinking"}
          </span>
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
          title={chat.title}
        >
          <span class="truncate">{chat.title}</span>
        </button>
      </nav>

      <div class="mt-3 min-h-0 flex-1 space-y-3 overflow-y-auto pr-1 text-sm">
        <p :if={@chat.messages == []} class="leading-6 text-stone-500 dark:text-stone-400">
          No messages yet.
        </p>

        <div
          :for={message <- @chat.messages}
          class={[
            "rounded-sm px-3 py-2 leading-6",
            message.role == :user &&
              "bg-stone-200/70 text-stone-950 dark:bg-stone-800 dark:text-stone-50",
            message.role == :assistant &&
              "bg-white text-stone-900 dark:bg-stone-900 dark:text-stone-100",
            message.role == :status &&
              "border border-stone-200/80 bg-stone-100/60 font-sans text-xs italic text-stone-600 dark:border-stone-800 dark:bg-stone-900/50 dark:text-stone-400",
            message.role == :error && "bg-red-50 text-red-900 dark:bg-red-950/40 dark:text-red-100"
          ]}
        >
          <.message_body text={message.text} role={message.role} />
        </div>
      </div>

      <.form for={@form} phx-submit="send" phx-target={@myself} class="mt-3 space-y-2">
        <textarea
          name="chat[message]"
          rows="3"
          class="block w-full resize-none rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm leading-5 text-stone-950 outline-none transition-colors placeholder:text-stone-400 focus:border-stone-500 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:placeholder:text-stone-500 dark:focus:border-stone-500"
          placeholder="Ask about the thesis or the papers"
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

  attr :text, :string, required: true
  attr :role, :atom, required: true

  defp message_body(%{role: :assistant} = assigns) do
    ~H"""
    <div class="assistant-prose break-words">
      {raw(render_markdown(@text))}
    </div>
    """
  end

  defp message_body(assigns) do
    ~H"""
    <div class="break-words whitespace-pre-line">{@text}</div>
    """
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
    case Chats.ensure_default(chat_options(socket)) do
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

  defp chat_options(socket) do
    [
      model: socket.assigns.model,
      llm_options: socket.assigns.llm_options
    ]
  end

  defp chat_listed?(chats, id), do: Enum.any?(chats, &(&1.id == id))

  defp chat_button_class(id, selected_id) do
    [
      "flex h-8 w-full items-center rounded-sm px-2 text-left font-sans text-xs transition-colors",
      "hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
      id == selected_id && "bg-stone-200/70 text-stone-950 dark:bg-stone-800 dark:text-stone-50",
      id != selected_id && "text-stone-600 dark:text-stone-400"
    ]
  end

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
    MDEx.to_html!(text, @mdex_opts)
  end

  defp chat_form, do: to_form(%{"message" => ""}, as: :chat)

  defp empty_chat do
    %{
      id: nil,
      title: "New chat",
      messages: [],
      pending: false,
      active_tool: nil,
      status_line: nil,
      error: nil
    }
  end
end
