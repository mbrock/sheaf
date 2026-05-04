defmodule SheafWeb.ResourceLive do
  @moduledoc """
  Type-dispatched resource route for short Sheaf ids.
  """

  use SheafWeb, :live_view

  alias Sheaf.{Corpus, Document, Documents, Id, ResourceResolver}
  alias Sheaf.Assistant.QueryResults
  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  alias SheafWeb.AssistantHistoryComponents
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
    case target_document_id(block_id, socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Block #{block_id} was not found.")}

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
    <main class="grid h-dvh grid-rows-[auto_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <section class="min-h-0">
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
    <main class="grid min-h-dvh grid-rows-[auto_1fr] bg-stone-100 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <section class="w-full py-5">
        <div class="mb-4 flex flex-col gap-3 px-4 sm:flex-row sm:items-end sm:justify-between sm:px-6 lg:px-8">
          <div>
            <p class="font-mono text-[11px] font-semibold uppercase tracking-wide text-stone-500 dark:text-stone-400">
              Spreadsheet query result
            </p>
            <h1 class="mt-1 font-sans text-2xl font-semibold tracking-normal text-stone-950 dark:text-stone-50">
              {@resource_id}
            </h1>
          </div>

          <div class="flex items-center gap-2">
            <span class="rounded-sm border border-stone-300 bg-white px-2.5 py-1 font-mono text-xs text-stone-700 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-300">
              {@query_result_returned} rows
            </span>
            <span class="font-mono text-xs text-stone-500 dark:text-stone-400">
              from {@query_result_row_count}
            </span>
          </div>
        </div>

        <details class="group mx-4 mb-5 overflow-hidden rounded-md border border-stone-300 bg-white sm:mx-6 lg:mx-8 dark:border-stone-800 dark:bg-stone-900">
          <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-2.5 font-sans text-sm font-semibold text-stone-800 marker:hidden dark:text-stone-100">
            <span>SQL</span>
            <.icon
              name="hero-chevron-right"
              class="size-4 text-stone-500 transition-transform group-open:rotate-90 dark:text-stone-400"
            />
          </summary>
          <pre class="overflow-x-auto border-t border-stone-200 bg-stone-50 p-4 font-mono text-xs leading-5 text-stone-800 dark:border-stone-800 dark:bg-stone-950 dark:text-stone-100"><code>{@query_result_sql}</code></pre>
        </details>

        <section>
          <div class="overflow-hidden border-y border-stone-300 bg-white dark:border-stone-800 dark:bg-stone-900">
            <div class="flex items-center justify-between gap-3 border-b border-stone-200 bg-white px-4 py-2.5 sm:px-6 lg:px-8 dark:border-stone-800 dark:bg-stone-900">
              <h2 class="font-sans text-sm font-semibold text-stone-950 dark:text-stone-50">Rows</h2>
              <span class="font-mono text-xs text-stone-500 dark:text-stone-400">
                {length(@query_result_columns)} columns
              </span>
            </div>

            <div class="overflow-x-auto">
              <table class="w-full min-w-[56rem] table-fixed border-separate border-spacing-0 text-left text-[11px]">
                <colgroup>
                  <col
                    :for={column <- @query_result_columns}
                    class={query_result_column_width_class(@query_result_column_kinds[column])}
                  />
                </colgroup>
                <thead class="text-stone-600 dark:text-stone-300">
                  <tr>
                    <th
                      :for={column <- @query_result_columns}
                      class={[
                        "sticky top-0 z-10 h-18 border-b border-stone-300 bg-stone-100 p-0 align-bottom dark:border-stone-700 dark:bg-stone-800",
                        "relative",
                        "first:pl-4 last:pr-4 lg:first:pl-6 lg:last:pr-6"
                      ]}
                      title={column}
                    >
                      <span class="absolute bottom-2 left-5 origin-bottom-left -rotate-45 whitespace-nowrap font-mono text-[10px] font-semibold uppercase tracking-wide">
                        {column}
                      </span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={row <- @query_result_rows}
                    class="group odd:bg-white even:bg-stone-50/70 hover:bg-amber-50/80 dark:odd:bg-stone-900 dark:even:bg-stone-900/60 dark:hover:bg-stone-800/70"
                  >
                    <td
                      :for={column <- @query_result_columns}
                      class={[
                        "border-b border-stone-200/80 px-2 py-1 align-middle text-stone-800 dark:border-stone-800 dark:text-stone-100",
                        "first:pl-4 last:pr-4 lg:first:pl-6 lg:last:pr-6",
                        query_result_cell_class(@query_result_column_kinds[column])
                      ]}
                    >
                      <div
                        :if={query_result_list_values(row, column) == []}
                        class="truncate whitespace-nowrap"
                        title={query_result_cell(row, column)}
                      >
                        {query_result_cell(row, column)}
                      </div>

                      <div
                        :if={query_result_list_values(row, column) != []}
                        class="flex flex-nowrap justify-end gap-1 overflow-hidden"
                      >
                        <span
                          :for={value <- query_result_list_values(row, column)}
                          class="shrink-0 truncate rounded-sm border border-stone-300 bg-stone-100 px-1 py-0 font-mono text-[10px] leading-4 text-stone-700 dark:border-stone-700 dark:bg-stone-800 dark:text-stone-200"
                          title={value}
                        >
                          {value}
                        </span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </section>
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
         |> assign(
           :query_result_column_kinds,
           query_result_column_kinds(result.columns, result.rows)
         )
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
         {:ok, references_by_block} <- Documents.references_for_document(root, graph) do
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

  defp query_result_cell(row, column) do
    case Map.get(row, column) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp query_result_column_kinds(columns, rows) do
    Map.new(columns, fn column ->
      {column, query_result_column_kind(column, rows)}
    end)
  end

  defp query_result_column_kind(column, rows) do
    values =
      rows
      |> Enum.map(&Map.get(&1, column))
      |> Enum.reject(&blank_query_result_value?/1)

    cond do
      query_result_identifier_column?(column) ->
        :identifier

      values != [] and Enum.all?(values, &query_result_number?/1) ->
        :number

      query_result_list_column?(column) ->
        :list

      true ->
        :text
    end
  end

  defp query_result_identifier_column?(column) do
    column == "id" or String.ends_with?(column, "_id") or String.ends_with?(column, "_iri")
  end

  defp query_result_list_column?(column) do
    String.ends_with?(column, "_types") or String.ends_with?(column, "_tags")
  end

  defp query_result_number?(value) when is_integer(value) or is_float(value), do: true

  defp query_result_number?(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {_number, ""} -> true
      _ -> false
    end
  end

  defp query_result_number?(_value), do: false

  defp blank_query_result_value?(nil), do: true
  defp blank_query_result_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_query_result_value?(_value), do: false

  defp query_result_cell_class(:identifier),
    do: "font-mono text-xs text-stone-700 dark:text-stone-300"

  defp query_result_cell_class(:number), do: "text-right font-mono text-xs tabular-nums"
  defp query_result_cell_class(:list), do: "text-right"
  defp query_result_cell_class(_kind), do: "text-left"

  defp query_result_column_width_class(:identifier), do: "w-20"
  defp query_result_column_width_class(:number), do: "w-16"
  defp query_result_column_width_class(:list), do: "w-76"
  defp query_result_column_width_class(_kind), do: "w-32"

  defp query_result_list_values(row, column) do
    value = query_result_cell(row, column)

    if query_result_list_column?(column) and String.contains?(value, ",") do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end
end
