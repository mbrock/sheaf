defmodule SheafWeb.DocumentLive do
  @moduledoc """
  Live document reader with outline navigation and block selection.
  """

  use SheafWeb, :live_view

  alias Sheaf.BlockTags
  alias Sheaf.Corpus
  alias Sheaf.Document
  alias Sheaf.Documents
  alias Sheaf.Id
  alias SheafWeb.AppChrome
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
  def render(assigns) do
    blocks = document_blocks(assigns.graph, assigns.root)

    assigns =
      assigns
      |> assign_new(:tags_by_block, fn -> %{} end)
      |> assign(:blocks, blocks)
      |> assign(
        :toc,
        assigns.graph
        |> Document.toc(assigns.root)
        |> tagged_toc_entries(assigns.graph, assigns.tags_by_block)
      )
      |> assign(:knuth_plass?, knuth_plass?(blocks))

    ~H"""
    <div
      id="document-reader"
      class="grid min-h-dvh bg-white text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-[auto_auto] dark:bg-stone-950 dark:text-stone-50"
      phx-hook="DocumentBreadcrumb"
    >
      <AppChrome.toolbar
        section={:document}
        copy_markdown?={true}
      >
        <.document_metadata_heading document={@document} show_open?={false} />
      </AppChrome.toolbar>

      <aside class="hidden border-r border-stone-200/80 bg-stone-50/80 p-3 lg:sticky lg:top-10 lg:col-start-1 lg:row-start-2 lg:block lg:max-h-[calc(100dvh-2.5rem)] lg:overflow-y-auto dark:border-stone-800/80 dark:bg-stone-950">
        <.block_outline
          entries={@toc}
          emit_active_data
          class="text-xs"
        />
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
      />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil
  attr :references_by_block, :map, default: %{}
  attr :tags_by_block, :map, default: %{}

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
      />
    </section>
    """
  end

  defp reader_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details
      id={"block-#{Document.id(@block.iri)}"}
      open
      class="document-print-section scroll-mt-6 space-y-4 pt-2 [&:not([open])>summary]:text-stone-500 [&:not([open])>summary]:dark:text-stone-500 [&[open]>summary]:pb-3 [&[open]>summary]:text-stone-900 [&[open]>summary]:dark:text-stone-100 [&>summary::-webkit-details-marker]:hidden"
    >
      <summary class={[
        "cursor-pointer list-none rounded-sm",
        selected_class(@block, @selected_id)
      ]}>
        <h2 class={["small-caps font-semibold leading-tight", section_heading_class(@block.number)]}>
          <span class="text-stone-500 dark:text-stone-400">{section_number(@block.number)}</span>
          <span class="ml-2">{Document.heading(@graph, @block.iri)}</span>
        </h2>
      </summary>

      <.reader_blocks
        graph={@graph}
        blocks={@block.children}
        selected_id={@selected_id}
        references_by_block={@references_by_block}
        tags_by_block={@tags_by_block}
      />
    </details>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <article
      id={"block-#{Document.id(@block.iri)}"}
      class="document-print-paragraph"
    >
      <div class="min-w-0">
        <div
          :if={block_tags(@tags_by_block, @block.iri) != []}
          class="document-print-tags mb-1 flex min-w-0 flex-wrap gap-1"
        >
          <.writing_tag :for={tag <- block_tags(@tags_by_block, @block.iri)} tag={tag} />
        </div>

        <p
          id={"text-#{Document.id(@block.iri)}"}
          class={[
            "document-print-text min-w-0 font-text leading-normal",
            paragraph_markup_classes(),
            selected_class(@block, @selected_id)
          ]}
          phx-click="inspect_block"
          phx-value-id={Document.id(@block.iri)}
          phx-update="ignore"
        >
          <%= if markup = Document.paragraph_markup(@graph, @block.iri) do %>
            {raw(markup)}
          <% else %>
            {Document.paragraph_text(@graph, @block.iri)}
          <% end %>
        </p>
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
        "inline-flex h-5 max-w-full items-center rounded-sm border px-1.5 font-micro text-[0.68rem] font-medium leading-none",
        writing_tag_class(@tag.name)
      ]}
    >
      {@tag.label}
    </span>
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
    "border-amber-300 bg-amber-50 text-amber-800 dark:border-amber-700/70 dark:bg-amber-950/30 dark:text-amber-200"
  end

  defp writing_tag_class("needs_evidence") do
    "border-sky-300 bg-sky-50 text-sky-800 dark:border-sky-700/70 dark:bg-sky-950/30 dark:text-sky-200"
  end

  defp writing_tag_class("needs_revision") do
    "border-rose-300 bg-rose-50 text-rose-800 dark:border-rose-700/70 dark:bg-rose-950/30 dark:text-rose-200"
  end

  defp writing_tag_class("fragment") do
    "border-violet-300 bg-violet-50 text-violet-800 dark:border-violet-700/70 dark:bg-violet-950/30 dark:text-violet-200"
  end

  defp writing_tag_class(_name) do
    "border-stone-300 bg-stone-100 text-stone-700 dark:border-stone-700 dark:bg-stone-800 dark:text-stone-200"
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
        |> assign(:selected_block_id, selected_block_id)

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
