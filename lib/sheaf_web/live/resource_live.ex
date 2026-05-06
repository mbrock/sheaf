defmodule SheafWeb.ResourceLive do
  @moduledoc """
  Type-dispatched resource route for short Sheaf ids.
  """

  use SheafWeb, :live_view

  alias Sheaf.{BlockTags, Corpus, Document, Documents, Id, ResourceResolver}
  alias Sheaf.Assistant.{Notes, QueryResults}
  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  alias SheafWeb.AssistantMarkdownComponents
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

  def handle_event("clear_block_selection", _params, socket) do
    {:noreply, DocumentLive.clear_block_selection(socket)}
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

  def handle_event("edit_paragraph", %{"id" => id}, socket) do
    {:noreply, DocumentLive.start_paragraph_edit(socket, id)}
  end

  def handle_event("toggle_block_tag", %{"id" => id, "tag" => tag}, socket) do
    {:noreply, DocumentLive.toggle_block_tag(socket, id, tag)}
  end

  def handle_event("insert_block_after", %{"id" => id}, socket) do
    {:noreply, DocumentLive.insert_document_block_after(socket, id)}
  end

  def handle_event("move_block", %{"id" => id, "direction" => direction}, socket) do
    {:noreply, DocumentLive.move_document_block(socket, id, direction)}
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    {:noreply, DocumentLive.delete_document_block(socket, id)}
  end

  def handle_event("cancel_paragraph_edit", _params, socket) do
    {:noreply, DocumentLive.clear_paragraph_edit(socket)}
  end

  def handle_event("save_paragraph_edit", %{"id" => id, "text" => text}, socket) do
    {:noreply, DocumentLive.save_paragraph_edit(socket, id, text)}
  end

  def handle_event("save_paragraph_edit", %{"id" => id, "markup" => markup}, socket) do
    {:noreply, DocumentLive.save_paragraph_markup_edit(socket, id, markup)}
  end

  def handle_event("save_paragraph_edit", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:document_changed, %{document_id: document_id}},
        %{assigns: %{resource_kind: :document, document_id: document_id}} = socket
      ) do
    {:noreply, DocumentLive.reload_document_assigns(socket)}
  end

  def handle_info({:document_changed, _event}, socket), do: {:noreply, socket}

  @impl true
  def render(%{resource_kind: :document} = assigns), do: DocumentLive.render(assigns)

  def render(%{resource_kind: :assistant_conversation} = assigns) do
    ~H"""
    <main class="min-h-dvh bg-white text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <section class="min-w-0">
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

  def render(%{resource_kind: :research_note} = assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:history} />

      <article class="mx-auto w-full max-w-prose px-4 py-8">
        <header class="mb-5 border-b border-stone-200 pb-3 dark:border-stone-800">
          <p class="font-sans text-xs font-semibold uppercase tracking-wide text-stone-500 dark:text-stone-400">
            Research note
          </p>
          <h1 class="mt-1 font-sans text-2xl font-semibold leading-tight text-stone-950 dark:text-stone-50">
            {@note_title}
          </h1>
          <time
            :if={@note_published_at}
            datetime={DateTime.to_iso8601(@note_published_at)}
            class="mt-2 block font-sans text-xs text-stone-500 dark:text-stone-400"
          >
            {Calendar.strftime(@note_published_at, "%b %-d, %Y %H:%M")}
          </time>
        </header>

        <div class="assistant-prose text-stone-900 dark:text-stone-100">
          <AssistantMarkdownComponents.markdown text={@note_text} resolve_block_previews={false} />
        </div>

        <footer :if={@note_mentions != []} class="mt-6 flex flex-wrap gap-1.5">
          <.link
            :for={mention <- @note_mentions}
            navigate={mention.path}
            class="inline-flex items-center gap-1 rounded-sm bg-stone-200/70 px-1.5 py-1 font-sans text-xs text-stone-600 hover:bg-stone-300/80 hover:text-stone-950 dark:bg-stone-800 dark:text-stone-300 dark:hover:bg-stone-700 dark:hover:text-stone-50"
          >
            <.icon name="hero-numbered-list" class="size-3" />
            <span>{mention.label}</span>
          </.link>
        </footer>
      </article>
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

      {:ok, %{kind: :research_note, id: note_id}} ->
        load_research_note(socket, id, note_id)

      {:error, reason} ->
        {:ok, assign_not_found(socket, id, reason)}
    end
  end

  defp load_research_note(socket, resource_id, note_id) do
    case Notes.get(note_id) do
      {:ok, note, graph} ->
        title = note_title(note) || "Research note #{note_id}"

        {:ok,
         socket
         |> assign(:page_title, title)
         |> assign(:resource_id, resource_id)
         |> assign(:resource_kind, :research_note)
         |> assign(:note_id, note_id)
         |> assign(:note_iri, to_string(note.subject))
         |> assign(:note_title, title)
         |> assign(:note_text, note_text(note))
         |> assign(:note_published_at, note_published_at(note))
         |> assign(:note_mentions, note_mentions(note, graph))
         |> assign(:selected_block_id, nil)}

      {:error, reason} ->
        {:ok, assign_not_found(socket, resource_id, reason)}
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
      document = sidebar_document(document_id, root, graph)

      socket =
        socket
        |> assign(:page_title, Document.title(graph, root))
        |> assign(:resource_id, resource_id)
        |> assign(:resource_kind, :document)
        |> assign(:document_id, document_id)
        |> assign(:document, document)
        |> assign(:graph, graph)
        |> assign(:root, root)
        |> assign(:references_by_block, references_by_block)
        |> assign(:tags_by_block, tags_by_block)
        |> DocumentLive.assign_document_view(graph, root, tags_by_block)
        |> assign(:selected_block_id, selected_block_id)
        |> assign(:editing_block_id, nil)
        |> DocumentLive.subscribe_document_changes(document_id)

      {:ok, socket}
    end
  end

  defp sidebar_document(id, root, graph) do
    with {:ok, documents} <- Documents.list(),
         document when not is_nil(document) <-
           Enum.find(documents, &(to_string(&1.iri) == to_string(root))) do
      document
    else
      _ ->
        %{
          id: id,
          iri: root,
          path: ~p"/#{id}",
          title: Document.title(graph, root),
          kind: Document.kind(graph, root),
          metadata: %{},
          cited?: false,
          excluded?: false,
          has_document?: true
        }
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

  defp note_title(note) do
    note
    |> RDF.Description.first(RDF.NS.RDFS.label())
    |> rdf_value()
  end

  defp note_text(note) do
    note
    |> RDF.Description.first(Sheaf.NS.AS.content())
    |> rdf_value()
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp note_published_at(note) do
    note
    |> RDF.Description.first(Sheaf.NS.AS.published())
    |> rdf_value()
    |> case do
      %DateTime{} = timestamp -> timestamp
      _other -> nil
    end
  end

  defp note_mentions(note, graph) do
    note
    |> RDF.Description.get(Sheaf.NS.DOC.mentions())
    |> List.wrap()
    |> Enum.map(fn iri ->
      id = Id.id_from_iri(iri)
      label = resource_label(graph, iri) || "##{id}"
      %{path: mention_path(id), label: label}
    end)
  end

  defp mention_path(id) do
    case ResourceResolver.resolve(id) do
      {:ok, %{kind: :block}} -> ~p"/b/#{id}"
      {:ok, %{kind: _kind}} -> ~p"/#{id}"
      {:error, _reason} -> ~p"/b/#{id}"
    end
  end

  defp resource_label(graph, iri) do
    graph
    |> RDF.Data.description(iri)
    |> RDF.Description.first(RDF.NS.RDFS.label())
    |> rdf_value()
  end

  defp rdf_value(nil), do: nil

  defp rdf_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

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
