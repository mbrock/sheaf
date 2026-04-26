defmodule SheafWeb.DocumentLive do
  @moduledoc """
  Live document reader with outline navigation, block selection, and assistant context.
  """

  use SheafWeb, :live_view

  alias Sheaf.Corpus
  alias Sheaf.Document
  alias Sheaf.Documents
  alias Sheaf.Id
  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantHistoryComponents
  import SheafWeb.DocumentEntryComponents, only: [document_entry: 1]

  # Knuth-Plass justification is O(n^2) per paragraph and snapshots every
  # paragraph in the article on mount/resize. Disable it for documents whose
  # paragraph count would make that too expensive.
  @knuth_plass_block_limit 800

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    with {:ok, socket} <- load_document(socket, id, params["block"]) do
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    selected_block_id = selected_block_id(params)
    document_changed? = Map.get(socket.assigns, :document_id) != id

    socket =
      if document_changed? do
        case load_document(socket, id, selected_block_id) do
          {:ok, socket} ->
            socket

          {:error, reason} ->
            put_flash(socket, :error, "Could not load document #{id}: #{inspect(reason)}")
        end
      else
        assign(socket, :selected_block_id, selected_block_id)
      end

    {:noreply, maybe_scroll_reader(socket, document_changed?)}
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
  def render(assigns) do
    blocks = document_blocks(assigns.graph, assigns.root)

    assigns =
      assigns
      |> assign(:blocks, blocks)
      |> assign(:toc, Document.toc(assigns.graph, assigns.root))
      |> assign(:knuth_plass?, paragraph_block_count(blocks) <= @knuth_plass_block_limit)

    ~H"""
    <div
      id="document-reader"
      class="grid h-dvh grid-rows-[auto_minmax(0,16rem)_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-[auto_minmax(0,1fr)] xl:grid-cols-[24rem_minmax(0,1fr)_30rem] dark:bg-stone-950 dark:text-stone-50"
      phx-hook="DocumentBreadcrumb"
    >
      <AppChrome.toolbar
        section={:document}
        breadcrumb_id="document-breadcrumb"
        copy_markdown?={true}
      />

      <aside class="min-h-0 overflow-y-auto p-4 lg:col-start-1 lg:row-start-2">
        <h1 class="font-bold text-lg">{document_title(@graph, @root)}</h1>
        <.block_outline entries={@toc} emit_active_data class="mt-4 text-sm" />
      </aside>

      <article
        id="document-start"
        class="min-h-0 min-w-0 overflow-y-auto px-12 pb-4 sm:px-8 lg:col-start-2 lg:row-start-2 [&_p]:text-justify [&_p]:hyphens-manual"
        phx-hook={if @knuth_plass?, do: "KnuthPlass"}
      >
        <div class="mx-auto w-full max-w-prose pt-4">
          <.reader_blocks
            graph={@graph}
            blocks={@blocks}
            selected_id={@selected_block_id}
            references_by_block={@references_by_block}
          />
        </div>
      </article>

      <AppChrome.right_sidebar
        assistant_id="document-assistant"
        graph={@graph}
        root={@root}
        selected_id={@selected_block_id}
      >
        <AssistantHistoryComponents.note_history
          notes={@notes}
          notes_graph={@notes_graph}
          notes_error={@notes_error}
          research_session_titles={@research_session_titles}
        />
      </AppChrome.right_sidebar>
    </div>
    """
  end

  attr :blocks, :list, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil
  attr :references_by_block, :map, default: %{}

  defp reader_blocks(assigns) do
    ~H"""
    <div class="space-y-4">
      <.reader_block
        :for={block <- @blocks}
        graph={@graph}
        block={block}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
      />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil
  attr :references_by_block, :map, default: %{}

  defp reader_block(%{block: %{type: :document}} = assigns) do
    ~H"""
    <section id={"block-#{Document.id(@block.iri)}"} class="space-y-6">
      <h1
        class={[
          "cursor-pointer rounded-sm font-sans text-2xl font-bold",
          selected_class(@block, @selected_id)
        ]}
        phx-click="inspect_block"
        phx-value-id={Document.id(@block.iri)}
      >
        {document_title(@graph, @block.iri)}
      </h1>

      <.reader_blocks
        graph={@graph}
        blocks={@block.children}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
      />
    </section>
    """
  end

  defp reader_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details
      id={"block-#{Document.id(@block.iri)}"}
      class="space-y-3 [&:not([open])>summary]:text-stone-500 [&:not([open])>summary]:dark:text-stone-500 [&[open]>summary]:pb-2 [&[open]>summary]:text-stone-900 [&[open]>summary]:dark:text-stone-100 [&>summary::-webkit-details-marker]:hidden"
      open={true}
    >
      <summary
        class={[
          "cursor-pointer list-none rounded-sm",
          selected_class(@block, @selected_id)
        ]}
        phx-click="inspect_block"
        phx-value-id={Document.id(@block.iri)}
      >
        <h2 class="font-sans text-lg font-semibold">
          {section_title(@block.number, Document.heading(@graph, @block.iri))}
        </h2>
      </summary>

      <.reader_blocks
        graph={@graph}
        blocks={@block.children}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
      />
    </details>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <article id={"block-#{Document.id(@block.iri)}"} class="relative max-w-prose">
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        §{@block.number}
      </span>

      <p
        id={"text-#{Document.id(@block.iri)}"}
        class={[
          "cursor-pointer rounded-sm font-serif leading-7",
          selected_class(@block, @selected_id)
        ]}
        phx-click="inspect_block"
        phx-value-id={Document.id(@block.iri)}
        phx-update="ignore"
      >
        {Document.paragraph_text(@graph, @block.iri)}
      </p>

      <div
        :if={reference_documents(@references_by_block, @block.iri) != []}
        class="mt-2 space-y-1 pl-4 font-sans"
      >
        <.document_entry
          :for={document <- reference_documents(@references_by_block, @block.iri)}
          document={document}
          nested
        />
      </div>
    </article>
    """
  end

  defp reader_block(%{block: %{type: :row}} = assigns) do
    ~H"""
    <article
      id={"block-#{Document.id(@block.iri)}"}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm py-1",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Document.id(@block.iri)}
    >
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        §{@block.number}
      </span>

      <div class="mb-1 flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1 font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        <span
          :if={Document.code_category(@graph, @block.iri) != ""}
          class="shrink-0 font-semibold text-stone-700 dark:text-stone-300"
        >
          {Document.code_category(@graph, @block.iri)}
        </span>
        <span
          :if={Document.code_category_title(@graph, @block.iri) != ""}
          class="min-w-0 flex-1 truncate"
          title={Document.code_category_title(@graph, @block.iri)}
        >
          {Document.code_category_title(@graph, @block.iri)}
        </span>
      </div>

      <p
        id={"text-#{Document.id(@block.iri)}"}
        class="font-serif leading-7"
        phx-update="ignore"
      >
        {Document.text(@graph, @block.iri)}
      </p>
    </article>
    """
  end

  defp reader_block(%{block: %{type: :extracted, source_type: "Text"}} = assigns) do
    ~H"""
    <div
      id={"block-#{Document.id(@block.iri)}"}
      data-source-type={@block.source_type}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm font-serif leading-7",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Document.id(@block.iri)}
    >
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        §{@block.number}
      </span>
      <div
        id={"text-#{Document.id(@block.iri)}"}
        class={["block" | extracted_text_block_classes()]}
        phx-update="ignore"
      >
        {raw(Document.source_html(@graph, @block.iri))}
      </div>
    </div>
    """
  end

  defp reader_block(%{block: %{type: :extracted}} = assigns) do
    ~H"""
    <div
      id={"block-#{Document.id(@block.iri)}"}
      data-source-type={@block.source_type}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm font-sans text-sm leading-6 text-stone-700 dark:text-stone-300",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Document.id(@block.iri)}
    >
      <div id={"text-#{Document.id(@block.iri)}"} class={extracted_other_block_classes()}>
        {raw(Document.source_html(@graph, @block.iri))}
      </div>
    </div>
    """
  end

  @doc false
  def paragraph_block_count(blocks) do
    Enum.reduce(blocks, 0, fn
      %{type: :document, children: children}, acc -> acc + paragraph_block_count(children)
      %{type: :section, children: children}, acc -> acc + paragraph_block_count(children)
      %{type: :paragraph}, acc -> acc + 1
      %{type: :row}, acc -> acc + 1
      %{type: :extracted, source_type: "Text"}, acc -> acc + 1
      _other, acc -> acc
    end)
  end

  @doc false
  def document_blocks(graph, root) do
    children =
      graph
      |> Document.children(root)
      |> number_blocks(graph, [])

    [%{type: :document, iri: root, children: children}]
  end

  defp number_blocks(blocks, graph, prefix) do
    blocks
    |> Enum.map_reduce({0, 0}, fn iri, {section_index, paragraph_index} ->
      case Document.block_type(graph, iri) do
        :section ->
          number = prefix ++ [section_index + 1]
          children = number_blocks(Document.children(graph, iri), graph, number)

          {%{type: :section, iri: iri, number: number, children: children},
           {section_index + 1, paragraph_index}}

        :paragraph ->
          number = paragraph_index + 1
          {%{type: :paragraph, iri: iri, number: number}, {section_index, number}}

        :row ->
          number = paragraph_index + 1
          {%{type: :row, iri: iri, number: number}, {section_index, number}}

        :extracted ->
          source_type = Document.source_block_type(graph, iri)

          if source_type == "Text" do
            number = paragraph_index + 1

            {%{type: :extracted, iri: iri, source_type: source_type, number: number},
             {section_index, number}}
          else
            {%{type: :extracted, iri: iri, source_type: source_type},
             {section_index, paragraph_index}}
          end
      end
    end)
    |> elem(0)
  end

  defp section_title(number, heading) do
    "#{Enum.join(number, ".")}. #{heading}"
  end

  defp selected_class(block, selected_id) do
    if Document.id(block.iri) == selected_id do
      "bg-stone-200/70 dark:bg-stone-800/80"
    end
  end

  defp extracted_text_block_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline",
      "[&_p]:mb-4"
    ]
  end

  defp extracted_other_block_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline",
      "[&_h1]:mb-2 [&_h1]:text-base [&_h1]:font-semibold",
      "[&_h2]:mb-2 [&_h2]:text-sm [&_h2]:font-semibold",
      "[&_h3]:mb-2 [&_h3]:text-sm [&_h3]:font-semibold",
      "[&_h4]:mb-1 [&_h4]:text-sm [&_h4]:font-semibold",
      "[&_img]:my-4 [&_img]:max-h-96 [&_img]:max-w-full",
      "[&_li]:my-1 [&_ol]:list-decimal [&_ol]:pl-5 [&_p]:mb-2 [&_ul]:list-disc [&_ul]:pl-5",
      "[&_table]:my-4 [&_table]:w-full [&_table]:border-collapse [&_td]:border [&_td]:border-stone-300 [&_td]:p-1.5 [&_th]:border [&_th]:border-stone-300 [&_th]:p-1.5"
    ]
  end

  defp page_title(graph, root), do: document_title(graph, root)

  defp document_title(graph, root), do: Document.title(graph, root)

  defp load_document(socket, id, selected_block_id) do
    root = Id.iri(id)

    with {:ok, graph} <- Sheaf.fetch_graph(root),
         {:ok, references_by_block} <- Documents.references_for_document(root) do
      {notes, notes_graph, notes_error} = AssistantHistoryComponents.fetch_notes()

      socket =
        socket
        |> assign(:page_title, page_title(graph, root))
        |> assign(:document_id, id)
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

  defp reference_documents(references_by_block, iri) do
    Map.get(references_by_block, Document.id(iri), [])
  end

  defp selected_block_id(%{"block" => block_id}) when is_binary(block_id) and block_id != "" do
    block_id
  end

  defp selected_block_id(_params), do: nil

  defp maybe_scroll_reader(
         %{assigns: %{selected_block_id: block_id}} = socket,
         _document_changed?
       )
       when is_binary(block_id) and block_id != "" do
    push_event(socket, "scroll-to-block", %{id: block_id})
  end

  defp maybe_scroll_reader(socket, true), do: push_event(socket, "scroll-reader-to-top", %{})
  defp maybe_scroll_reader(socket, false), do: socket

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
