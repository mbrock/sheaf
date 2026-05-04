defmodule SheafWeb.ResourceLive do
  @moduledoc """
  Type-dispatched resource route for short Sheaf ids.
  """

  use SheafWeb, :live_view

  alias Sheaf.{BlockTags, Corpus, Document, Documents, Id, ResourceResolver}
  alias Sheaf.Assistant.QueryResults
  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  alias SheafWeb.AssistantHistoryComponents
  alias SheafWeb.DataTableComponents
  alias SheafWeb.DocumentLive

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    load_resource(socket, id, params)
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    current_id = Map.get(socket.assigns, :resource_id)
    selected_block_id = selected_block_id(params)
    resource_changed? = current_id != id

    socket =
      if resource_changed? do
        case load_resource(socket, id, params) do
          {:ok, socket} ->
            socket

          {:error, reason} ->
            socket
            |> assign_not_found(id)
            |> put_flash(:error, "Could not load #{id}: #{inspect(reason)}")
        end
      else
        assign(socket, :selected_block_id, selected_block_id)
      end

    {:noreply, maybe_scroll_reader(socket, resource_changed?)}
  end

  @impl true
  def handle_event("inspect_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_block_id, id)}
  end

  def handle_event("assistant_block_link", %{"id" => block_id}, socket)
      when is_binary(block_id) and block_id != "" do
    current_document_id = Map.get(socket.assigns, :document_id)

    case target_document_id(block_id, socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Block #{block_id} was not found.")}

      ^current_document_id ->
        {:noreply,
         socket
         |> assign(:selected_block_id, block_id)
         |> push_event("scroll-to-block", %{id: block_id})}

      doc_id when doc_id == block_id ->
        {:noreply, push_patch(socket, to: ~p"/#{doc_id}")}

      doc_id ->
        {:noreply, push_patch(socket, to: block_path(doc_id, block_id))}
    end
  end

  def handle_event("assistant_block_link", _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{resource_kind: :document} = assigns), do: DocumentLive.render(assigns)

  def render(%{resource_kind: :assistant_conversation} = assigns) do
    ~H"""
    <main class="grid h-dvh grid-cols-[minmax(0,1fr)] grid-rows-[auto_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <section class="min-h-0 min-w-0 overflow-hidden">
        <.live_component
          module={AssistantChatComponent}
          id={"assistant-conversation-#{@chat_id}"}
          chat_id={@chat_id}
          variant={:full_page}
        />
      </section>
    </main>
    """
  end

  def render(%{resource_kind: :spreadsheet_query_result} = assigns) do
    ~H"""
    <main class="grid min-h-dvh grid-rows-[auto_1fr_auto] bg-stone-100 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <section class="w-full py-5">
        <DataTableComponents.data_table columns={@query_result_columns} rows={@query_result_rows} />
      </section>

      <pre class="overflow-x-auto border-t border-stone-200 bg-stone-50 p-4 font-mono text-xs leading-5 text-stone-800 dark:border-stone-800 dark:bg-stone-950 dark:text-stone-100"><code>{@query_result_sql}</code></pre>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="grid min-h-dvh grid-rows-[auto_1fr] bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />
      <section class="grid place-items-center px-4 py-12">
        <div class="max-w-lg text-center">
          <h1 class="font-sans text-lg font-semibold">Resource not found</h1>
          <p class="mt-2 text-sm text-stone-500 dark:text-stone-400">
            {@resource_id || "Unknown resource"} could not be resolved.
          </p>
        </div>
      </section>
    </main>
    """
  end

  defp load_resource(socket, id, params) do
    case ResourceResolver.resolve(id) do
      {:ok, %{kind: :document, id: document_id}} ->
        load_document(socket, id, document_id, selected_block_id(params))

      {:ok, %{kind: :block, id: block_id, document_id: document_id}} ->
        load_document(socket, id, document_id, block_id)

      {:ok, %{kind: :assistant_conversation, id: chat_id}} ->
        {:ok,
         socket
         |> assign(:page_title, "Assistant conversation")
         |> assign(:resource_id, id)
         |> assign(:resource_kind, :assistant_conversation)
         |> assign(:chat_id, chat_id)
         |> assign(:selected_block_id, nil)}

      {:ok, %{kind: :spreadsheet_query_result, id: result_id}} ->
        load_spreadsheet_query_result(socket, id, result_id)

      {:error, reason} ->
        {:ok, assign_not_found(socket, id, reason)}
    end
  end

  defp load_spreadsheet_query_result(socket, resource_id, result_id) do
    case QueryResults.read(result_id, limit: 100) do
      {:ok, result} ->
        {:ok,
         socket
         |> assign(:page_title, "Spreadsheet query result #{result_id}")
         |> assign(:resource_id, resource_id)
         |> assign(:resource_kind, :spreadsheet_query_result)
         |> assign(:query_result_id, result.id)
         |> assign(:query_result_iri, result.iri)
         |> assign(:query_result_file_iri, result.file_iri)
         |> assign(:query_result_sql, result.sql || "")
         |> assign(:query_result_columns, result.columns)
         |> assign(:query_result_rows, result.rows)
         |> assign(:query_result_row_count, result.row_count)
         |> assign(:query_result_returned, length(result.rows))
         |> assign(:selected_block_id, nil)}

      {:error, reason} ->
        {:ok, assign_not_found(socket, resource_id, reason)}
    end
  end

  defp load_document(socket, resource_id, document_id, selected_block_id) do
    root = Id.iri(document_id)

    with {:ok, graph} <- Sheaf.fetch_graph(root),
         {:ok, references_by_block} <- Documents.references_for_document(root, graph),
         {:ok, tags_by_block} <- BlockTags.for_document(graph, root) do
      {notes, notes_graph, notes_error} = AssistantHistoryComponents.fetch_notes()

      socket =
        socket
        |> assign(:page_title, Document.title(graph, root))
        |> assign(:resource_id, resource_id)
        |> assign(:resource_kind, :document)
        |> assign(:document_id, document_id)
        |> assign(:graph, graph)
        |> assign(:root, root)
        |> assign(:references_by_block, references_by_block)
        |> assign(:tags_by_block, tags_by_block)
        |> assign(:selected_block_id, selected_block_id)
        |> assign(:notes, notes)
        |> assign(:notes_graph, notes_graph)
        |> assign(:notes_error, notes_error)
        |> assign(:research_session_titles, AssistantHistoryComponents.research_session_titles())

      {:ok, socket}
    end
  end

  defp assign_not_found(socket, id, reason \\ :not_found) do
    socket
    |> assign(:page_title, "Resource not found")
    |> assign(:resource_id, id)
    |> assign(:resource_kind, :not_found)
    |> assign(:not_found_reason, reason)
  end

  defp selected_block_id(%{"block" => block_id}) when is_binary(block_id) and block_id != "" do
    block_id
  end

  defp selected_block_id(_params), do: nil

  defp maybe_scroll_reader(
         %{assigns: %{resource_kind: :document, selected_block_id: block_id}} = socket,
         _resource_changed?
       )
       when is_binary(block_id) and block_id != "" do
    push_event(socket, "scroll-to-block", %{id: block_id})
  end

  defp maybe_scroll_reader(%{assigns: %{resource_kind: :document}} = socket, true),
    do: push_event(socket, "scroll-reader-to-top", %{})

  defp maybe_scroll_reader(socket, _resource_changed?), do: socket

  defp target_document_id(block_id, socket) do
    iri = Id.iri(block_id)

    cond do
      Map.get(socket.assigns, :root) == iri ->
        socket.assigns.document_id

      Map.has_key?(socket.assigns, :graph) and Document.block_type(socket.assigns.graph, iri) ->
        socket.assigns.document_id

      true ->
        Corpus.find_document(block_id)
    end
  end

  defp block_path(doc_id, block_id) do
    ~p"/#{doc_id}?block=#{block_id}" <> "#block-#{block_id}"
  end
end
