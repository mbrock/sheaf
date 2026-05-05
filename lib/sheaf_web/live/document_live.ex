defmodule SheafWeb.DocumentLive do
  @moduledoc """
  Live document reader with outline navigation and block selection.
  """

  use SheafWeb, :live_view

  require Logger

  alias Sheaf.BlockTags
  alias Sheaf.Corpus
  alias Sheaf.Document
  alias Sheaf.DocumentEdits
  alias Sheaf.Documents
  alias Sheaf.Id
  alias Sheaf.SearchMaintenance
  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  import SheafWeb.DocumentEntryComponents, only: [document_entry: 1, document_metadata_heading: 1]

  # Knuth-Plass justification is useful for short documents, but large imported
  # books can make client-side paragraph rewriting feel sluggish.
  @knuth_plass? false
  @knuth_plass_max_blocks 500

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

  def handle_event("clear_block_selection", _params, socket) do
    {:noreply, clear_block_selection(socket)}
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
    {:noreply, start_paragraph_edit(socket, id)}
  end

  def handle_event("toggle_block_tag", %{"id" => id, "tag" => tag}, socket) do
    {:noreply, toggle_block_tag(socket, id, tag)}
  end

  def handle_event("insert_block_after", %{"id" => id}, socket) do
    {:noreply, insert_document_block_after(socket, id)}
  end

  def handle_event("move_block", %{"id" => id, "direction" => direction}, socket) do
    {:noreply, move_document_block(socket, id, direction)}
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    {:noreply, delete_document_block(socket, id)}
  end

  def handle_event("cancel_paragraph_edit", _params, socket) do
    {:noreply, clear_paragraph_edit(socket)}
  end

  def handle_event("save_paragraph_edit", %{"id" => id, "text" => text}, socket) do
    {:noreply, save_paragraph_edit(socket, id, text)}
  end

  def handle_event("save_paragraph_edit", %{"id" => id, "markup" => markup}, socket) do
    {:noreply, save_paragraph_markup_edit(socket, id, markup)}
  end

  def handle_event("save_paragraph_edit", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:document_changed, %{document_id: document_id}},
        %{assigns: %{document_id: document_id}} = socket
      ) do
    {:noreply, reload_document_assigns(socket)}
  end

  def handle_info({:document_changed, _event}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:tags_by_block, fn -> %{} end)
      |> assign_new(:editing_block_id, fn -> nil end)
      |> assign_new(:blocks, fn -> document_blocks(assigns.graph, assigns.root) end)

    assigns =
      assigns
      |> assign_new(:toc, fn ->
        assigns.graph
        |> Document.toc(assigns.root)
        |> tagged_toc_entries(assigns.graph, assigns.tags_by_block)
      end)
      |> assign_new(:knuth_plass?, fn -> knuth_plass?(assigns.blocks) end)
      |> assign(:selected_paragraph_id, selected_paragraph_id(assigns))

    ~H"""
    <div
      id="document-reader"
      class="grid min-h-dvh bg-white text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-[auto_auto] dark:bg-stone-950 dark:text-stone-50"
      phx-hook="DocumentBreadcrumb"
      data-selected-block-id={@selected_block_id || ""}
    >
      <AppChrome.toolbar
        section={:document}
        copy_markdown?={true}
        pdf_export_path={~p"/api/documents/#{@document_id}/pdf"}
      >
        <.document_metadata_heading document={@document} show_open?={false} />
      </AppChrome.toolbar>

      <aside class="hidden border-r border-stone-200/80 bg-stone-50/80 p-3 lg:sticky lg:top-10 lg:col-start-1 lg:row-start-2 lg:flex lg:max-h-[calc(100dvh-2.5rem)] lg:flex-col lg:overflow-hidden dark:border-stone-800/80 dark:bg-stone-950">
        <div class="min-h-0 flex-1 overflow-y-auto pr-1">
          <.block_outline
            entries={@toc}
            emit_active_data
            class="text-xs"
          />
        </div>

        <section
          :if={@selected_paragraph_id}
          class="mt-3 shrink-0 border-t border-stone-200 pt-3 dark:border-stone-800"
          data-selected-block-context
        >
          <div class="mb-2 flex min-w-0 items-center gap-2 font-sans text-xs">
            <span class="min-w-0 flex-1 truncate uppercase text-stone-500 dark:text-stone-400">
              Assistant
            </span>
            <span class="shrink-0 border border-stone-300 bg-white px-1.5 py-0.5 font-mono text-[10px] font-medium text-stone-700 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-200">
              {"##{@selected_paragraph_id}"}
            </span>
          </div>
          <.live_component
            module={AssistantChatComponent}
            id={"document-block-assistant-#{@document_id}"}
            variant={:document_sidebar}
            graph={@graph}
            root={@root}
            selected_id={@selected_paragraph_id}
          />
        </section>
      </aside>

      <article
        id="document-start"
        class="document-print-root min-w-0 bg-white px-4 pb-4 focus:outline-none lg:col-start-2 lg:row-span-2 lg:row-start-2 lg:px-10 lg:pb-10 dark:bg-stone-950 [&_p]:text-base lg:[&_p]:text-lg [&_p]:text-justify [&_p]:hyphens-manual"
        tabindex="0"
        data-scroll-target="window"
        phx-hook={if @knuth_plass?, do: "KnuthPlass"}
      >
        <div class="document-print-page mx-auto w-full max-w-prose pt-4 lg:py-10">
          <.reader_blocks
            graph={@graph}
            blocks={@blocks}
            selected_id={@selected_block_id}
            references_by_block={@references_by_block}
            tags_by_block={@tags_by_block}
            editing_block_id={@editing_block_id}
          />
        </div>
      </article>
    </div>
    """
  end

  attr :blocks, :list, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil
  attr :references_by_block, :map, default: %{}
  attr :tags_by_block, :map, default: %{}
  attr :editing_block_id, :string, default: nil

  defp reader_blocks(assigns) do
    ~H"""
    <div class="document-print-flow space-y-5">
      <.reader_block
        :for={block <- @blocks}
        graph={@graph}
        block={block}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
        tags_by_block={@tags_by_block}
        editing_block_id={@editing_block_id}
      />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil
  attr :references_by_block, :map, default: %{}
  attr :tags_by_block, :map, default: %{}
  attr :editing_block_id, :string, default: nil

  defp reader_block(%{block: %{type: :document}} = assigns) do
    ~H"""
    <section
      id={"block-#{Document.id(@block.iri)}"}
      class="document-print-document scroll-mt-6 space-y-8"
    >
      <h1
        class={[
          "small-caps cursor-pointer rounded-sm text-3xl font-semibold leading-tight",
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
        tags_by_block={@tags_by_block}
        editing_block_id={@editing_block_id}
      />
    </section>
    """
  end

  defp reader_block(%{block: %{type: :section}} = assigns) do
    block_id = Document.id(assigns.block.iri)
    editing? = assigns.editing_block_id == block_id
    selected? = assigns.selected_id == block_id

    assigns =
      assigns
      |> assign(:block_id, block_id)
      |> assign(:editing?, editing?)
      |> assign(:selected?, selected?)

    ~H"""
    <section
      id={"block-#{@block_id}"}
      class="document-print-section relative scroll-mt-6 space-y-4 pt-2"
    >
      <.block_toolbar
        :if={@selected? and !@editing?}
        block_id={@block_id}
        editable?={true}
        tags={[]}
        show_tags?={false}
      />
      <header
        class="cursor-pointer px-3 py-2"
        phx-click={unless @editing?, do: "inspect_block"}
        phx-value-id={unless @editing?, do: @block_id}
      >
        <.text_block_editor
          :if={@editing?}
          graph={@graph}
          block={@block}
        />

        <h2
          :if={!@editing?}
          class={["small-caps font-semibold leading-tight", section_heading_class(@block.number)]}
        >
          <span class="text-stone-500 dark:text-stone-400">{section_number(@block.number)}</span>
          <span class="ml-2">{Document.heading(@graph, @block.iri)}</span>
        </h2>
      </header>

      <.reader_blocks
        graph={@graph}
        blocks={@block.children}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
        tags_by_block={@tags_by_block}
        editing_block_id={@editing_block_id}
      />
    </section>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    block_id = Document.id(assigns.block.iri)
    editing? = assigns.editing_block_id == block_id
    selected? = assigns.selected_id == block_id
    editable? = editable_text_block?(assigns.graph, assigns.block.iri)
    tags = block_tags(assigns.tags_by_block, assigns.block.iri)

    assigns =
      assigns
      |> assign(:block_id, block_id)
      |> assign(:editing?, editing?)
      |> assign(:selected?, selected?)
      |> assign(:editable?, editable?)
      |> assign(:tags, tags)

    ~H"""
    <article
      id={"block-#{@block_id}"}
      class={paragraph_article_class(@selected?, @editing?)}
      phx-click={unless @editing?, do: "inspect_block"}
      phx-value-id={unless @editing?, do: @block_id}
    >
      <div
        :if={@tags != []}
        class="document-print-tags pointer-events-none absolute inset-y-2 left-0 flex w-1.5 flex-col gap-0.5"
        aria-hidden="true"
      >
        <.writing_tag :for={tag <- @tags} tag={tag} />
      </div>
      <div class="min-w-0">
        <.text_block_editor
          :if={@editing?}
          graph={@graph}
          block={@block}
        />

        <div :if={!@editing?} class="min-w-0">
          <.block_toolbar
            :if={@selected?}
            block_id={@block_id}
            editable?={@editable?}
            tags={@tags}
            show_tags?={true}
          />

          <p
            id={"text-#{@block_id}"}
            class={[
              "document-print-text min-w-0 font-text leading-normal",
              paragraph_markup_classes()
            ]}
          >
            <%= if markup = Document.paragraph_markup(@graph, @block.iri) do %>
              {raw(markup)}
            <% else %>
              {Document.paragraph_text(@graph, @block.iri)}
            <% end %>
          </p>
        </div>
      </div>

      <.footnote_blocks
        footnotes={Document.footnotes(@graph, @block.iri)}
        selected_id={@selected_id}
      />

      <div
        :if={reference_documents(@references_by_block, @block.iri) != []}
        class="document-print-references mt-2 space-y-1 pl-4 font-sans"
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
        "document-print-row cursor-pointer rounded-sm py-1",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Document.id(@block.iri)}
    >
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
        class="document-print-text min-w-0 font-text leading-normal"
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
        "document-print-excerpt cursor-pointer rounded-sm font-text leading-normal",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Document.id(@block.iri)}
    >
      <div
        id={"text-#{Document.id(@block.iri)}"}
        class={["document-print-text min-w-0" | extracted_text_block_classes()]}
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
        "document-print-media relative cursor-pointer rounded-sm font-sans text-sm leading-6 text-stone-700 dark:text-stone-300",
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

  attr :block, :map, required: true
  attr :graph, :any, required: true

  defp text_block_editor(assigns) do
    block_id = Document.id(assigns.block.iri)

    assigns =
      assigns
      |> assign(:block_id, block_id)
      |> assign(:text, editable_block_text(assigns.graph, assigns.block.iri))
      |> assign(:markup, editable_block_markup(assigns.graph, assigns.block.iri) || "")
      |> assign(:format, editable_block_format(assigns.graph, assigns.block.iri))

    ~H"""
    <div
      id={"paragraph-editor-#{@block_id}"}
      class="document-paragraph-editor rounded-sm border border-stone-300 bg-stone-50 p-2 shadow-sm dark:border-stone-700 dark:bg-stone-900"
      phx-hook="ParagraphEditor"
      phx-update="ignore"
      data-block-id={@block_id}
      data-text={@text}
      data-markup={@markup}
      data-format={@format}
    >
      <div
        id={"paragraph-editor-surface-#{@block_id}"}
        data-paragraph-editor-surface
        class="document-paragraph-editor-surface min-h-24 font-text text-lg leading-normal"
      >
      </div>
      <div class="mt-2 flex items-center justify-end gap-2 font-sans">
        <button
          type="button"
          class="inline-flex h-8 items-center gap-1.5 rounded-sm border border-stone-300 bg-white px-2 text-xs font-medium text-stone-700 transition hover:border-stone-400 hover:text-stone-950 dark:border-stone-700 dark:bg-stone-950 dark:text-stone-200 dark:hover:text-stone-50"
          data-paragraph-editor-cancel
        >
          <.icon name="hero-x-mark" class="size-4" /> Cancel
        </button>
        <button
          type="button"
          class="inline-flex h-8 items-center gap-1.5 rounded-sm bg-stone-900 px-2.5 text-xs font-medium text-white transition hover:bg-stone-700 dark:bg-stone-100 dark:text-stone-950 dark:hover:bg-stone-300"
          data-paragraph-editor-save
        >
          <.icon name="hero-check" class="size-4" /> Save
        </button>
      </div>
    </div>
    """
  end

  attr :block_id, :string, required: true
  attr :editable?, :boolean, default: false
  attr :tags, :list, default: []
  attr :show_tags?, :boolean, default: false

  defp block_toolbar(assigns) do
    ~H"""
    <div class="absolute bottom-full left-0 z-10 flex h-6 items-center gap-px border border-stone-300 bg-white p-px font-sans dark:border-stone-700 dark:bg-stone-950">
      <div class="flex items-center gap-px">
        <button
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent font-mono text-[0.68rem] font-semibold leading-none text-stone-500 transition-colors hover:border-stone-300 hover:bg-stone-50 hover:text-stone-950 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-400 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
          title={"Copy ##{@block_id}"}
          aria-label={"Copy ##{@block_id}"}
          phx-click={
            JS.dispatch("sheaf:copy-text", detail: %{text: "##{@block_id}"})
            |> JS.push("clear_block_selection")
          }
        >
          #
        </button>
        <button
          :if={@editable?}
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent text-stone-600 transition-colors hover:border-stone-300 hover:bg-white hover:text-stone-950 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-300 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
          title="Edit block"
          aria-label="Edit block"
          phx-click="edit_paragraph"
          phx-value-id={@block_id}
        >
          <.icon name="hero-pencil-square" class="size-3.5" />
        </button>
        <button
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent text-stone-600 transition-colors hover:border-stone-300 hover:bg-white hover:text-stone-950 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-300 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
          title="Create block below"
          aria-label="Create block below"
          phx-click="insert_block_after"
          phx-value-id={@block_id}
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
        <button
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent text-stone-600 transition-colors hover:border-stone-300 hover:bg-white hover:text-stone-950 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-300 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
          title="Move block up"
          aria-label="Move block up"
          phx-click="move_block"
          phx-value-id={@block_id}
          phx-value-direction="up"
        >
          <.icon name="hero-arrow-up" class="size-3.5" />
        </button>
        <button
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent text-stone-600 transition-colors hover:border-stone-300 hover:bg-white hover:text-stone-950 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-300 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
          title="Move block down"
          aria-label="Move block down"
          phx-click="move_block"
          phx-value-id={@block_id}
          phx-value-direction="down"
        >
          <.icon name="hero-arrow-down" class="size-3.5" />
        </button>
        <button
          type="button"
          class="grid size-5 shrink-0 place-items-center border border-transparent text-stone-600 transition-colors hover:border-rose-300 hover:bg-white hover:text-rose-700 focus:outline-none focus:ring-2 focus:ring-rose-300 dark:text-stone-300 dark:hover:border-rose-800 dark:hover:bg-stone-900 dark:hover:text-rose-200"
          title="Delete block"
          aria-label="Delete block"
          phx-click="delete_block"
          phx-value-id={@block_id}
        >
          <.icon name="hero-trash" class="size-3.5" />
        </button>
      </div>
      <div :if={@show_tags?} class="h-4 w-px bg-stone-300 dark:bg-stone-700"></div>
      <div :if={@show_tags?} class="flex items-center gap-px">
        <button
          :for={tag <- writing_tag_options()}
          type="button"
          class={toolbar_tag_button_class(active_tag?(@tags, tag.name))}
          title={"Toggle #{tag.label}"}
          aria-label={"Toggle #{tag.label}"}
          aria-pressed={active_tag?(@tags, tag.name)}
          phx-click="toggle_block_tag"
          phx-value-id={@block_id}
          phx-value-tag={tag.name}
        >
          <span class={toolbar_tag_dot_class(tag.name)}></span>
          <span class="sr-only">{tag.label}</span>
        </button>
      </div>
    </div>
    """
  end

  attr :footnotes, :list, required: true
  attr :selected_id, :string, default: nil

  defp footnote_blocks(assigns) do
    ~H"""
    <ol
      :if={@footnotes != []}
      class="document-print-footnotes mt-2 space-y-1 border-t border-stone-200/70 pt-2 font-micro text-sm leading-snug text-stone-700 dark:border-stone-800/80 dark:text-stone-300"
    >
      <li
        :for={footnote <- @footnotes}
        id={"block-#{footnote.id}"}
        class={[
          "scroll-mt-6 rounded-sm",
          selected_class(%{iri: footnote.iri}, @selected_id)
        ]}
      >
        <div class="flex gap-2">
          <span class="shrink-0 font-micro text-[0.72rem] leading-5 text-stone-500 dark:text-stone-400">
            {footnote.id}
          </span>
          <div class="min-w-0 flex-1">
            <%= if footnote.markup do %>
              {raw(footnote.markup)}
            <% else %>
              {footnote.text}
            <% end %>
          </div>
        </div>
      </li>
    </ol>
    """
  end

  attr :tag, :map, required: true

  defp writing_tag(assigns) do
    ~H"""
    <span
      title={@tag.label}
      class={[
        "block min-h-3 flex-1",
        writing_tag_class(@tag.name)
      ]}
    >
      <span class="sr-only">{@tag.label}</span>
    </span>
    """
  end

  defp writing_tag_options do
    Enum.map(BlockTags.tag_names(), fn name -> %{name: name, label: BlockTags.label(name)} end)
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

  defp section_number(number), do: "#{Enum.join(number, ".")}."

  defp section_heading_class([_]), do: "text-2xl"
  defp section_heading_class([_, _]), do: "text-xl"
  defp section_heading_class(_number), do: "text-lg"

  defp knuth_plass?(blocks) do
    @knuth_plass? and paragraph_block_count(blocks) <= @knuth_plass_max_blocks
  end

  @doc false
  def tagged_toc_entries(entries, graph, tags_by_block) do
    Enum.map(entries, &tagged_toc_entry(&1, graph, tags_by_block))
  end

  defp tagged_toc_entry(entry, graph, tags_by_block) do
    children = tagged_toc_entries(entry.children, graph, tags_by_block)

    entry
    |> Map.put(:children, children)
    |> Map.put(:tags, section_tags(graph, entry.iri, tags_by_block))
  end

  defp section_tags(graph, section, tags_by_block) do
    graph
    |> descendant_blocks(section)
    |> Enum.flat_map(&block_tags(tags_by_block, &1))
    |> unique_tags()
  end

  defp descendant_blocks(graph, block) do
    graph
    |> Document.children(block)
    |> Enum.flat_map(fn child -> [child | descendant_blocks(graph, child)] end)
  end

  defp block_tags(tags_by_block, iri) do
    Map.get(tags_by_block, Document.id(iri), [])
  end

  defp unique_tags(tags) do
    order = Map.new(Enum.with_index(BlockTags.tag_names()))

    tags
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(&Map.get(order, &1.name, 999))
  end

  defp selected_class(block, selected_id) do
    if Document.id(block.iri) == selected_id, do: nil
  end

  defp active_tag?(tags, name), do: Enum.any?(tags, &(&1.name == name))

  defp toolbar_tag_button_class(true) do
    [
      "grid size-5 place-items-center border transition-colors",
      "border-stone-300 bg-stone-100 dark:border-stone-600 dark:bg-stone-800"
    ]
  end

  defp toolbar_tag_button_class(false) do
    [
      "grid size-5 place-items-center border border-transparent transition-colors",
      "hover:border-stone-300 hover:bg-white dark:hover:border-stone-600 dark:hover:bg-stone-900"
    ]
  end

  defp toolbar_tag_dot_class("placeholder"), do: "size-1.5 rounded-full bg-amber-500"
  defp toolbar_tag_dot_class("needs_evidence"), do: "size-1.5 rounded-full bg-sky-500"
  defp toolbar_tag_dot_class("needs_revision"), do: "size-1.5 rounded-full bg-rose-500"
  defp toolbar_tag_dot_class("fragment"), do: "size-1.5 rounded-full bg-violet-500"
  defp toolbar_tag_dot_class(_name), do: "size-1.5 rounded-full bg-stone-400"

  defp paragraph_article_class(_selected?, editing?) do
    [
      "document-print-paragraph group/paragraph relative -mx-3 scroll-mt-6 px-3 py-2",
      unless(editing?, do: "cursor-pointer")
    ]
  end

  defp editable_text_block?(graph, iri) do
    case Document.block_type(graph, iri) do
      :section -> true
      :paragraph -> true
      _ -> false
    end
  end

  defp editable_markup_block?(graph, iri) do
    Document.block_type(graph, iri) == :paragraph and
      not is_nil(Document.paragraph_markup(graph, iri))
  end

  defp editable_block_text(graph, iri) do
    case Document.block_type(graph, iri) do
      :section -> Document.heading(graph, iri)
      :paragraph -> Document.paragraph_text(graph, iri)
      _ -> ""
    end
  end

  defp editable_block_markup(graph, iri) do
    case Document.block_type(graph, iri) do
      :paragraph -> Document.paragraph_markup(graph, iri)
      _ -> nil
    end
  end

  defp editable_block_format(graph, iri) do
    if editable_markup_block?(graph, iri), do: "markup", else: "text"
  end

  defp extracted_text_block_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline",
      "[&_p]:mb-4"
    ]
  end

  defp paragraph_markup_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline dark:[&_a]:text-sky-200",
      "[&_code]:rounded-sm [&_code]:bg-stone-100 [&_code]:px-1 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-[0.9em] dark:[&_code]:bg-stone-800",
      "[&_em]:italic [&_i]:italic",
      "[&_mark]:bg-yellow-200/50 [&_mark]:px-0.5 [&_mark]:text-inherit dark:[&_mark]:bg-yellow-400/25",
      "[&_strong]:font-bold [&_b]:font-bold",
      "[&_sub]:text-[0.72em] [&_sup]:text-[0.72em]",
      "[&_span[data-footnote]]:ml-0.5 [&_span[data-footnote]]:opacity-60",
      "[&_u]:underline"
    ]
  end

  defp writing_tag_class("placeholder") do
    "bg-amber-500 dark:bg-amber-400"
  end

  defp writing_tag_class("needs_evidence") do
    "bg-sky-500 dark:bg-sky-400"
  end

  defp writing_tag_class("needs_revision") do
    "bg-rose-500 dark:bg-rose-400"
  end

  defp writing_tag_class("fragment") do
    "bg-violet-500 dark:bg-violet-400"
  end

  defp writing_tag_class(_name) do
    "bg-stone-500 dark:bg-stone-400"
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

  @doc false
  def start_paragraph_edit(socket, block_id) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)

    if editable_text_block?(socket.assigns.graph, block) do
      socket
      |> assign(:editing_block_id, block_id)
      |> assign(:selected_block_id, block_id)
    else
      put_flash(
        socket,
        :error,
        "Only section headings and paragraph blocks can be edited here."
      )
    end
  end

  @doc false
  def toggle_block_tag(socket, block_id, tag) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)

    cond do
      Document.block_type(socket.assigns.graph, block) != :paragraph ->
        put_flash(socket, :error, "Only paragraph blocks can be tagged here.")

      true ->
        case BlockTags.toggle(block_id, tag) do
          {:ok, _result} ->
            socket
            |> reload_document_assigns()
            |> assign(:selected_block_id, block_id)

          {:error, reason} when is_binary(reason) ->
            put_flash(socket, :error, "Could not toggle tag: #{reason}")

          {:error, reason} ->
            put_flash(socket, :error, "Could not toggle tag: #{inspect(reason)}")
        end
    end
  end

  @doc false
  def insert_document_block_after(socket, block_id) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)

    cond do
      Document.block_type(socket.assigns.graph, block) == nil ->
        put_flash(socket, :error, "Block #{block_id} was not found.")

      true ->
        case DocumentEdits.insert_paragraph(block_id, "after", "") do
          {:ok, result} ->
            if Map.get(socket.assigns, :refresh_search_indexes?, true) do
              refresh_search_indexes_async(result.affected_blocks)
            end

            socket
            |> reload_document_assigns()
            |> assign(:editing_block_id, result.block_id)
            |> assign(:selected_block_id, result.block_id)
            |> push_event("scroll-to-block", %{id: result.block_id})

          {:error, reason} when is_binary(reason) ->
            put_flash(socket, :error, "Could not create block: #{reason}")

          {:error, reason} ->
            put_flash(socket, :error, "Could not create block: #{inspect(reason)}")
        end
    end
  end

  @doc false
  def move_document_block(socket, block_id, direction) do
    block_id = normalize_block_id(block_id)

    with {:ok, target_id, position} <- adjacent_move(socket.assigns.blocks, block_id, direction),
         {:ok, result} <- DocumentEdits.move_block(block_id, target_id, position) do
      if Map.get(socket.assigns, :refresh_search_indexes?, true) do
        refresh_search_indexes_async(result.affected_blocks)
      end

      socket
      |> reload_document_assigns()
      |> assign(:editing_block_id, nil)
      |> assign(:selected_block_id, block_id)
      |> push_event("scroll-to-block", %{id: block_id})
    else
      {:error, :no_adjacent_sibling} ->
        put_flash(socket, :error, "That block cannot move farther in this section.")

      {:error, reason} when is_binary(reason) ->
        put_flash(socket, :error, "Could not move block: #{reason}")

      {:error, reason} ->
        put_flash(socket, :error, "Could not move block: #{inspect(reason)}")
    end
  end

  @doc false
  def delete_document_block(socket, block_id) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)

    cond do
      Document.block_type(socket.assigns.graph, block) == nil ->
        put_flash(socket, :error, "Block #{block_id} was not found.")

      true ->
        case DocumentEdits.delete_block(block_id) do
          {:ok, result} ->
            if Map.get(socket.assigns, :refresh_search_indexes?, true) do
              refresh_search_indexes_async(result.affected_blocks)
            end

            socket
            |> reload_document_assigns()
            |> assign(:editing_block_id, nil)
            |> assign(:selected_block_id, nil)
            |> put_flash(:info, "Block deleted.")

          {:error, reason} when is_binary(reason) ->
            put_flash(socket, :error, "Could not delete block: #{reason}")

          {:error, reason} ->
            put_flash(socket, :error, "Could not delete block: #{inspect(reason)}")
        end
    end
  end

  @doc false
  def clear_paragraph_edit(socket), do: assign(socket, :editing_block_id, nil)

  @doc false
  def clear_block_selection(socket) do
    socket
    |> assign(:selected_block_id, nil)
    |> assign(:editing_block_id, nil)
  end

  @doc false
  def save_paragraph_edit(socket, block_id, text) when is_binary(text) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)
    text = normalize_editor_text(text)

    cond do
      Map.get(socket.assigns, :editing_block_id) != block_id ->
        socket

      not editable_text_block?(socket.assigns.graph, block) ->
        put_flash(
          socket,
          :error,
          "Only section headings and paragraph blocks can be edited here."
        )

      text == editable_block_text(socket.assigns.graph, block) ->
        clear_paragraph_edit(socket)

      true ->
        case DocumentEdits.replace_block_text(block_id, text) do
          {:ok, result} ->
            if Map.get(socket.assigns, :refresh_search_indexes?, true) do
              refresh_search_indexes_async(result.affected_blocks)
            end

            socket
            |> reload_document_assigns()
            |> assign(:editing_block_id, nil)
            |> assign(:selected_block_id, block_id)
            |> put_flash(:info, "Paragraph saved.")

          {:error, reason} when is_binary(reason) ->
            put_flash(socket, :error, "Could not save paragraph: #{reason}")

          {:error, reason} ->
            put_flash(socket, :error, "Could not save paragraph: #{inspect(reason)}")
        end
    end
  end

  def save_paragraph_edit(socket, _block_id, _text), do: socket

  @doc false
  def save_paragraph_markup_edit(socket, block_id, markup) when is_binary(markup) do
    block_id = normalize_block_id(block_id)
    block = Id.iri(block_id)
    markup = Document.sanitize_inline_markup(markup)

    cond do
      Map.get(socket.assigns, :editing_block_id) != block_id ->
        socket

      not editable_markup_block?(socket.assigns.graph, block) ->
        put_flash(socket, :error, "Only markup paragraph blocks can be edited as markup.")

      markup == (Document.paragraph_markup(socket.assigns.graph, block) || "") ->
        clear_paragraph_edit(socket)

      true ->
        case DocumentEdits.replace_block_markup(block_id, markup) do
          {:ok, result} ->
            if Map.get(socket.assigns, :refresh_search_indexes?, true) do
              refresh_search_indexes_async(result.affected_blocks)
            end

            socket
            |> reload_document_assigns()
            |> assign(:editing_block_id, nil)
            |> assign(:selected_block_id, block_id)
            |> put_flash(:info, "Paragraph saved.")

          {:error, reason} when is_binary(reason) ->
            put_flash(socket, :error, "Could not save paragraph: #{reason}")

          {:error, reason} ->
            put_flash(socket, :error, "Could not save paragraph: #{inspect(reason)}")
        end
    end
  end

  def save_paragraph_markup_edit(socket, _block_id, _markup), do: socket

  @doc false
  def reload_document_assigns(%{assigns: %{document_id: document_id}} = socket) do
    root = Id.iri(document_id)

    with {:ok, graph} <- Sheaf.fetch_graph(root),
         {:ok, references_by_block} <- Documents.references_for_document(root, graph),
         {:ok, tags_by_block} <- BlockTags.for_document(graph, root) do
      socket
      |> assign(:page_title, page_title(graph, root))
      |> assign(:document, sidebar_document(document_id, root, graph))
      |> assign(:graph, graph)
      |> assign(:root, root)
      |> assign(:references_by_block, references_by_block)
      |> assign(:tags_by_block, tags_by_block)
      |> assign_document_view(graph, root, tags_by_block)
    else
      {:error, reason} ->
        put_flash(socket, :error, "Could not reload document #{document_id}: #{inspect(reason)}")
    end
  end

  defp load_document(socket, id, selected_block_id) do
    root = Id.iri(id)

    with {:ok, graph} <- Sheaf.fetch_graph(root),
         {:ok, references_by_block} <- Documents.references_for_document(root, graph),
         {:ok, tags_by_block} <- BlockTags.for_document(graph, root) do
      document = sidebar_document(id, root, graph)

      socket =
        socket
        |> assign(:page_title, page_title(graph, root))
        |> assign(:document_id, id)
        |> assign(:document, document)
        |> assign(:graph, graph)
        |> assign(:root, root)
        |> assign(:references_by_block, references_by_block)
        |> assign(:tags_by_block, tags_by_block)
        |> assign_document_view(graph, root, tags_by_block)
        |> assign(:selected_block_id, selected_block_id)
        |> assign(:editing_block_id, nil)
        |> subscribe_document_changes(id)

      {:ok, socket}
    end
  end

  @doc false
  def subscribe_document_changes(socket, document_id) do
    subscribed_id = Map.get(socket.assigns, :document_change_subscription_id)

    if connected?(socket) and subscribed_id != document_id do
      if is_binary(subscribed_id) do
        Phoenix.PubSub.unsubscribe(Sheaf.PubSub, DocumentEdits.topic(subscribed_id))
      end

      Phoenix.PubSub.subscribe(Sheaf.PubSub, DocumentEdits.topic(document_id))
      assign(socket, :document_change_subscription_id, document_id)
    else
      assign_new(socket, :document_change_subscription_id, fn -> subscribed_id end)
    end
  end

  @doc false
  def assign_document_view(socket, graph, root, tags_by_block) do
    blocks = document_blocks(graph, root)

    socket
    |> assign(:blocks, blocks)
    |> assign(:toc, graph |> Document.toc(root) |> tagged_toc_entries(graph, tags_by_block))
    |> assign(:knuth_plass?, knuth_plass?(blocks))
  end

  defp normalize_block_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> Id.id_from_iri()
  end

  defp normalize_block_id(%RDF.IRI{} = iri), do: Id.id_from_iri(iri)
  defp normalize_block_id(_value), do: ""

  defp selected_paragraph_id(%{selected_block_id: id, graph: graph})
       when is_binary(id) and id != "" do
    iri = Id.iri(id)

    case Document.block_type(graph, iri) do
      :paragraph -> id
      _type -> nil
    end
  end

  defp selected_paragraph_id(_assigns), do: nil

  defp adjacent_move(blocks, block_id, "up") do
    blocks
    |> sibling_ids(block_id)
    |> adjacent_before(block_id)
    |> case do
      nil -> {:error, :no_adjacent_sibling}
      target_id -> {:ok, target_id, "before"}
    end
  end

  defp adjacent_move(blocks, block_id, "down") do
    blocks
    |> sibling_ids(block_id)
    |> adjacent_after(block_id)
    |> case do
      nil -> {:error, :no_adjacent_sibling}
      target_id -> {:ok, target_id, "after"}
    end
  end

  defp adjacent_move(_blocks, _block_id, _direction), do: {:error, "unknown move direction"}

  defp sibling_ids(blocks, block_id) do
    Enum.find_value(blocks, fn block ->
      children = Map.get(block, :children, [])
      child_ids = Enum.map(children, &Document.id(&1.iri))

      cond do
        block_id in child_ids -> child_ids
        children == [] -> nil
        true -> sibling_ids(children, block_id)
      end
    end)
  end

  defp adjacent_before(nil, _block_id), do: nil

  defp adjacent_before([], _block_id), do: nil

  defp adjacent_before([block_id | _rest], block_id), do: nil

  defp adjacent_before([previous_id, block_id | _rest], block_id), do: previous_id

  defp adjacent_before([_id | rest], block_id), do: adjacent_before(rest, block_id)

  defp adjacent_after(nil, _block_id), do: nil

  defp adjacent_after([], _block_id), do: nil

  defp adjacent_after([block_id, next_id | _rest], block_id), do: next_id

  defp adjacent_after([_id | rest], block_id), do: adjacent_after(rest, block_id)

  defp normalize_editor_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.trim()
  end

  defp refresh_search_indexes_async(block_ids) do
    if Process.whereis(Sheaf.Assistant.TaskSupervisor) do
      Task.Supervisor.start_child(Sheaf.Assistant.TaskSupervisor, fn ->
        refresh_search_indexes(block_ids)
      end)
    else
      Task.start(fn -> refresh_search_indexes(block_ids) end)
    end

    :ok
  end

  defp refresh_search_indexes(block_ids) do
    case SearchMaintenance.refresh_blocks(block_ids) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("Paragraph edit search index refresh failed: #{inspect(reason)}")
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
          title: document_title(graph, root),
          kind: Document.kind(graph, root),
          metadata: %{},
          cited?: false,
          excluded?: false,
          has_document?: true
        }
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
