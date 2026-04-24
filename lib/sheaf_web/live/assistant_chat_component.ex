defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Reusable document-aware assistant chat component.
  """

  use SheafWeb, :live_component

  alias ReqLLM.{Context, Response, Tool}
  alias Sheaf.{Assistant, Document, Id}

  @default_model "anthropic:claude-sonnet-4-6"
  @default_max_tokens 4_096

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:assistant, nil)
     |> assign(:messages, [])
     |> assign(:pending_ref, nil)
     |> assign(:error, nil)
     |> assign(:form, chat_form())}
  end

  @impl true
  def update(%{assistant_result: {ref, result}}, socket) do
    socket =
      if socket.assigns.pending_ref == ref do
        handle_assistant_result(socket, result)
      else
        socket
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:model, fn -> @default_model end)
      |> assign_new(:llm_options, fn -> [max_tokens: @default_max_tokens] end)
      |> maybe_start_assistant()

    {:ok, socket}
  end

  @impl true
  def handle_event("send", %{"chat" => %{"message" => message}}, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, assign(socket, :form, chat_form())}

      socket.assigns.pending_ref ->
        {:noreply, socket}

      true ->
        {:noreply, start_turn(socket, message)}
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
        <span
          :if={@pending_ref}
          class="font-sans text-xs uppercase text-stone-500 dark:text-stone-400"
        >
          Thinking
        </span>
      </div>

      <div class="mt-3 min-h-0 flex-1 space-y-3 overflow-y-auto pr-1 text-sm">
        <p :if={@messages == []} class="leading-6 text-stone-500 dark:text-stone-400">
          No messages yet.
        </p>

        <div
          :for={message <- @messages}
          class={[
            "rounded-sm px-3 py-2 leading-6",
            message.role == :user &&
              "bg-stone-200/70 text-stone-950 dark:bg-stone-800 dark:text-stone-50",
            message.role == :assistant &&
              "bg-white text-stone-900 dark:bg-stone-900 dark:text-stone-100",
            message.role == :error && "bg-red-50 text-red-900 dark:bg-red-950/40 dark:text-red-100"
          ]}
        >
          <div class="whitespace-pre-wrap break-words">{message.text}</div>
        </div>
      </div>

      <.form for={@form} phx-submit="send" phx-target={@myself} class="mt-3 space-y-2">
        <textarea
          name="chat[message]"
          rows="3"
          class="block w-full resize-none rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm leading-5 text-stone-950 outline-none transition-colors placeholder:text-stone-400 focus:border-stone-500 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:placeholder:text-stone-500 dark:focus:border-stone-500"
          placeholder="Ask about this document"
          disabled={@pending_ref != nil}
        ></textarea>
        <div class="flex justify-end">
          <button
            type="submit"
            class="grid size-8 place-items-center rounded-sm bg-stone-950 text-stone-50 transition-colors hover:bg-stone-700 disabled:cursor-not-allowed disabled:bg-stone-300 disabled:text-stone-500 dark:bg-stone-50 dark:text-stone-950 dark:hover:bg-stone-300 dark:disabled:bg-stone-800 dark:disabled:text-stone-500"
            title="Send"
            aria-label="Send"
            disabled={@pending_ref != nil}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </.form>
    </section>
    """
  end

  defp maybe_start_assistant(%{assigns: %{assistant: nil, graph: graph, root: root}} = socket) do
    context = Context.new([Context.system(system_prompt(graph, root))])
    tools = document_tools(graph, root)

    case Assistant.start_link(
           model: socket.assigns.model,
           context: context,
           tools: tools,
           llm_options: socket.assigns.llm_options
         ) do
      {:ok, assistant} ->
        assign(socket, :assistant, assistant)

      {:error, reason} ->
        socket
        |> assign(:error, reason)
        |> append_message(:error, "Could not start assistant: #{inspect(reason)}")
    end
  end

  defp maybe_start_assistant(socket), do: socket

  defp start_turn(socket, text) do
    ref = make_ref()
    live_view = self()
    component = __MODULE__
    component_id = socket.assigns.id
    assistant = socket.assigns.assistant
    selected_id = socket.assigns[:selected_id]
    input = user_input(text, selected_id)

    case Task.Supervisor.start_child(Sheaf.Assistant.TaskSupervisor, fn ->
           result = safe_run(assistant, input)

           Phoenix.LiveView.send_update(live_view, component,
             id: component_id,
             assistant_result: {ref, result}
           )
         end) do
      {:ok, _pid} ->
        socket
        |> assign(:pending_ref, ref)
        |> assign(:form, chat_form())
        |> append_message(:user, text)

      {:error, reason} ->
        append_message(socket, :error, "Could not start assistant turn: #{inspect(reason)}")
    end
  end

  defp safe_run(assistant, input) do
    Assistant.run(assistant, input)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp handle_assistant_result(socket, {:ok, %Response{} = response}) do
    text = Response.text(response) |> blank_to_default()

    socket
    |> assign(:pending_ref, nil)
    |> assign(:form, chat_form())
    |> append_message(:assistant, text)
  end

  defp handle_assistant_result(socket, {:error, reason}) do
    socket
    |> assign(:pending_ref, nil)
    |> assign(:form, chat_form())
    |> append_message(:error, "Assistant error: #{inspect(reason)}")
  end

  defp chat_form do
    to_form(%{"message" => ""}, as: :chat)
  end

  defp append_message(socket, role, text) do
    update(socket, :messages, &(&1 ++ [%{role: role, text: text}]))
  end

  defp user_input(text, nil), do: Context.user(text)

  defp user_input(text, selected_id) do
    Context.user("""
    Current selected block id: #{selected_id}

    #{text}
    """)
  end

  defp blank_to_default(nil), do: "(no text response)"
  defp blank_to_default(""), do: "(no text response)"
  defp blank_to_default(text), do: text

  defp system_prompt(graph, root) do
    """
    You are a document assistant embedded in Sheaf.
    Answer questions about the current document.
    Use tools when you need document structure, block text, or text search.
    Keep answers concise and cite block ids when they matter.

    Current document:
    #{Document.title(graph, root)}
    """
  end

  defp document_tools(graph, root) do
    [
      Tool.new!(
        name: "get_document_summary",
        description: "Return the current document title, kind, id, and section outline.",
        callback: fn _args ->
          {:ok,
           %{
             id: Document.id(root),
             iri: to_string(root),
             title: Document.title(graph, root),
             kind: Document.kind(graph, root),
             outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
           }}
        end
      ),
      Tool.new!(
        name: "get_block",
        description: "Return text and metadata for a document block by id.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Block id, without the resource-base prefix"]
        ],
        callback: fn %{id: id} -> get_block(graph, root, id) end
      ),
      Tool.new!(
        name: "search_document_text",
        description: "Search readable document text chunks for a case-insensitive query.",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"],
          limit: [type: :integer, default: 5, doc: "Maximum number of matching chunks"]
        ],
        callback: fn args -> search_document_text(graph, root, args) end
      )
    ]
  end

  defp get_block(graph, root, id) do
    iri = Id.iri(id)

    cond do
      iri == root ->
        {:ok,
         %{
           id: Document.id(root),
           iri: to_string(root),
           type: :document,
           title: Document.title(graph, root),
           kind: Document.kind(graph, root)
         }}

      type = Document.block_type(graph, iri) ->
        {:ok,
         %{
           id: id,
           iri: to_string(iri),
           type: type,
           title: block_title(graph, iri, type),
           text: block_text(graph, iri, type),
           source: block_source(graph, iri),
           children: Enum.map(Document.children(graph, iri), &Document.id/1)
         }}

      true ->
        {:error, "block not found"}
    end
  end

  defp search_document_text(graph, root, %{query: query} = args) do
    query = String.downcase(String.trim(query))
    limit = args |> Map.get(:limit, 5) |> min(20) |> max(1)

    results =
      graph
      |> Document.text_chunks(root)
      |> Enum.filter(fn chunk -> String.contains?(String.downcase(chunk.text), query) end)
      |> Enum.take(limit)
      |> Enum.map(fn chunk ->
        %{
          id: chunk.id,
          type: chunk.type,
          text: String.slice(chunk.text, 0, 1_000),
          source: %{
            key: chunk.source_key,
            page: chunk.source_page,
            type: chunk.source_type
          }
        }
      end)

    {:ok, %{query: query, results: results}}
  end

  defp outline_entry(%{id: id, title: title, number: number, children: children}) do
    %{
      id: id,
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp block_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_title(_graph, _iri, _type), do: nil

  defp block_text(graph, iri, :paragraph), do: Document.paragraph_text(graph, iri)
  defp block_text(graph, iri, :extracted), do: plain_text(Document.source_html(graph, iri))
  defp block_text(_graph, _iri, _type), do: nil

  defp block_source(graph, iri) do
    %{
      key: Document.source_key(graph, iri),
      page: Document.source_page(graph, iri),
      type: Document.source_block_type(graph, iri)
    }
  end

  defp plain_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end
end
