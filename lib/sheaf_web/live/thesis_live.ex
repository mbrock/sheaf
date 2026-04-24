defmodule SheafWeb.ThesisLive do
  use SheafWeb, :live_view

  alias Sheaf.Id
  alias Sheaf.Thesis

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    root = Id.iri(id)

    with {:ok, graph} <- Sheaf.fetch_graph(root) do
      socket =
        socket
        |> assign(:page_title, page_title(graph, root))
        |> assign(:graph, graph)
        |> assign(:root, root)
        |> assign(:selected_block_id, nil)

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("inspect_block", %{"id" => id}, socket) do
    {:noreply, assign(socket, :selected_block_id, id)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :blocks, document_blocks(assigns.graph, assigns.root))

    ~H"""
    <div
      id="thesis-reader"
      class="grid h-dvh grid-rows-[minmax(0,16rem)_auto_minmax(0,1fr)_minmax(0,14rem)] overflow-hidden bg-stone-50 text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)_20rem] lg:grid-rows-[auto_minmax(0,1fr)] dark:bg-stone-950 dark:text-stone-50"
      phx-hook="ThesisBreadcrumb"
    >
      <aside class="min-h-0 overflow-y-auto p-4 lg:col-start-1 lg:row-span-2">
        <h1 class="font-bold text-lg">{document_title(@graph, @root)}</h1>
        <.toc graph={@graph} blocks={toc_blocks(@blocks)} />
      </aside>

      <div class="min-w-0 border-b border-stone-200/80 bg-stone-50/90 px-12 py-2 backdrop-blur sm:px-8 lg:col-start-2 lg:row-start-1 dark:border-stone-800/80 dark:bg-stone-950/90">
        <div class="mx-auto flex min-h-7 w-full max-w-prose items-center gap-3 overflow-hidden">
          <span
            id="thesis-breadcrumb"
            class="min-w-0 flex-1 truncate font-serif text-lg lowercase text-stone-500 [font-variant-caps:small-caps] dark:text-stone-400"
          >
          </span>
          <button
            id="copy-markdown"
            type="button"
            class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
            title="Copy markdown"
            aria-label="Copy markdown"
          >
            <.icon name="hero-clipboard-document" class="size-4" />
          </button>
        </div>
      </div>

      <article
        id="document-start"
        class="min-h-0 min-w-0 overflow-y-auto px-12 pb-4 sm:px-8 lg:col-start-2 lg:row-start-2"
      >
        <div class="mx-auto w-full max-w-prose pt-4">
          <.reader_blocks graph={@graph} blocks={@blocks} selected_id={@selected_block_id} />
        </div>
      </article>

      <aside class="min-h-0 overflow-y-auto border-t border-stone-200/80 p-4 lg:col-start-3 lg:row-span-2 lg:row-start-1 lg:border-l lg:border-t-0 dark:border-stone-800/80">
        <.inspector graph={@graph} root={@root} selected_id={@selected_block_id} />
      </aside>
    </div>
    """
  end

  attr :blocks, :list, required: true
  attr :graph, :any, required: true

  defp toc(assigns) do
    ~H"""
    <nav class="text-sm">
      <.toc_list graph={@graph} blocks={@blocks} />
    </nav>
    """
  end

  defp toc_blocks([%{type: :document, children: children}]), do: children
  defp toc_blocks(blocks), do: blocks

  attr :blocks, :list, required: true
  attr :graph, :any, required: true
  attr :class, :string, default: "space-y-1"

  defp toc_list(assigns) do
    ~H"""
    <ol class={@class}>
      <li :for={%{type: :section} = block <- @blocks}>
        <a
          href={"#block-#{Thesis.id(block.iri)}"}
          data-toc-link={"block-#{Thesis.id(block.iri)}"}
          class={[
            "-mx-1 flex items-baseline rounded-sm border-l-2 border-transparent py-0.5 pl-2 pr-1 transition-colors data-[current=true]:border-stone-950 data-[current=true]:bg-stone-200/70 data-[current=true]:text-stone-950 dark:data-[current=true]:border-stone-100 dark:data-[current=true]:bg-stone-800/80 dark:data-[current=true]:text-stone-50",
            if(length(block.number) == 1,
              do: "text-stone-950 dark:text-stone-50",
              else: "text-stone-600 dark:text-stone-400"
            )
          ]}
        >
          <span class="min-w-0 flex-1 text-balance leading-5">
            {section_title(block.number, Thesis.heading(@graph, block.iri))}
          </span>
        </a>

        <.toc_list
          :if={block.children != []}
          graph={@graph}
          blocks={block.children}
          class="ml-4 mt-1 space-y-1"
        />
      </li>
    </ol>
    """
  end

  attr :blocks, :list, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil

  defp reader_blocks(assigns) do
    ~H"""
    <div class="space-y-4">
      <.reader_block
        :for={block <- @blocks}
        graph={@graph}
        block={block}
        selected_id={@selected_id}
      />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :graph, :any, required: true
  attr :selected_id, :string, default: nil

  defp reader_block(%{block: %{type: :document}} = assigns) do
    ~H"""
    <section id={"block-#{Thesis.id(@block.iri)}"} class="space-y-6">
      <h1
        class={[
          "cursor-pointer rounded-sm font-sans text-2xl font-bold transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
          selected_class(@block, @selected_id)
        ]}
        phx-click="inspect_block"
        phx-value-id={Thesis.id(@block.iri)}
      >
        {document_title(@graph, @block.iri)}
      </h1>

      <.reader_blocks graph={@graph} blocks={@block.children} selected_id={@selected_id} />
    </section>
    """
  end

  defp reader_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details
      id={"block-#{Thesis.id(@block.iri)}"}
      class="space-y-3 [&:not([open])>summary]:text-stone-500 [&:not([open])>summary]:dark:text-stone-500 [&[open]>summary]:pb-2 [&[open]>summary]:text-stone-900 [&[open]>summary]:dark:text-stone-100 [&>summary::-webkit-details-marker]:hidden"
      open={true}
    >
      <summary
        class={[
          "cursor-pointer list-none rounded-sm transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
          selected_class(@block, @selected_id)
        ]}
        phx-click="inspect_block"
        phx-value-id={Thesis.id(@block.iri)}
      >
        <h2 class="font-sans text-lg font-semibold">
          {section_title(@block.number, Thesis.heading(@graph, @block.iri))}
        </h2>
      </summary>

      <.reader_blocks graph={@graph} blocks={@block.children} selected_id={@selected_id} />
    </details>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <p
      id={"block-#{Thesis.id(@block.iri)}"}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm font-serif leading-7 transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Thesis.id(@block.iri)}
    >
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        §{@block.number}
      </span>
      <span
        id={"text-#{Thesis.id(@block.iri)}"}
        class="block"
        phx-hook="PretextParagraph"
        phx-update="ignore"
        data-pretext-text
      >
        {Thesis.paragraph_text(@graph, @block.iri)}
      </span>
    </p>
    """
  end

  defp reader_block(%{block: %{type: :extracted, source_type: "Text"}} = assigns) do
    ~H"""
    <div
      id={"block-#{Thesis.id(@block.iri)}"}
      data-source-type={@block.source_type}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm font-serif leading-7 transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Thesis.id(@block.iri)}
    >
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400">
        §{@block.number}
      </span>
      <div
        id={"text-#{Thesis.id(@block.iri)}"}
        class={["block" | extracted_text_block_classes()]}
        phx-hook="PretextParagraph"
        phx-update="ignore"
        data-pretext-text
      >
        {raw(Thesis.source_html(@graph, @block.iri))}
      </div>
    </div>
    """
  end

  defp reader_block(%{block: %{type: :extracted}} = assigns) do
    ~H"""
    <div
      id={"block-#{Thesis.id(@block.iri)}"}
      data-source-type={@block.source_type}
      class={[
        "relative max-w-prose cursor-pointer rounded-sm font-sans text-sm leading-6 text-stone-700 transition-colors hover:bg-stone-200/70 dark:text-stone-300 dark:hover:bg-stone-800/80",
        selected_class(@block, @selected_id)
      ]}
      phx-click="inspect_block"
      phx-value-id={Thesis.id(@block.iri)}
    >
      <div id={"text-#{Thesis.id(@block.iri)}"} class={extracted_other_block_classes()}>
        {raw(Thesis.source_html(@graph, @block.iri))}
      </div>
    </div>
    """
  end

  attr :graph, :any, required: true
  attr :root, :any, required: true
  attr :selected_id, :string, default: nil

  defp inspector(assigns) do
    assigns = assign(assigns, :selected_iri, selected_iri(assigns.selected_id))

    ~H"""
    <div class="space-y-4">
      <h2 class="font-sans text-sm font-semibold uppercase tracking-wide text-stone-500 dark:text-stone-400">
        Inspector
      </h2>

      <p :if={is_nil(@selected_iri)} class="text-sm leading-6 text-stone-500 dark:text-stone-400">
        Select a block.
      </p>

      <dl :if={@selected_iri} class="space-y-3 text-sm">
        <div :for={{label, value} <- block_metadata(@graph, @root, @selected_iri)}>
          <dt class="font-sans text-xs uppercase tracking-wide text-stone-500 dark:text-stone-400">
            {label}
          </dt>
          <dd class="mt-1 break-words font-mono text-xs leading-5 text-stone-900 dark:text-stone-100">
            {value}
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc false
  def document_blocks(graph, root) do
    children =
      graph
      |> Thesis.children(root)
      |> number_blocks(graph, [])

    [%{type: :document, iri: root, children: children}]
  end

  defp number_blocks(blocks, graph, prefix) do
    blocks
    |> Enum.map_reduce({0, 0}, fn iri, {section_index, paragraph_index} ->
      case Thesis.block_type(graph, iri) do
        :section ->
          number = prefix ++ [section_index + 1]
          children = number_blocks(Thesis.children(graph, iri), graph, number)

          {%{type: :section, iri: iri, number: number, children: children},
           {section_index + 1, paragraph_index}}

        :paragraph ->
          number = paragraph_index + 1
          {%{type: :paragraph, iri: iri, number: number}, {section_index, number}}

        :extracted ->
          source_type = Thesis.source_block_type(graph, iri)

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

  defp selected_iri(nil), do: nil
  defp selected_iri(id), do: Id.iri(id)

  defp selected_class(block, selected_id) do
    if Thesis.id(block.iri) == selected_id do
      "bg-stone-200/70 dark:bg-stone-800/80"
    end
  end

  defp block_metadata(graph, root, iri) do
    type = Thesis.block_type(graph, iri)

    [
      {"ID", Thesis.id(iri)},
      {"Kind", metadata_kind(graph, root, iri, type)},
      {"Title", metadata_title(graph, root, iri, type)},
      {"Source type", Thesis.source_block_type(graph, iri)},
      {"Source key", Thesis.source_key(graph, iri)},
      {"Source page", source_page_value(graph, iri)},
      {"IRI", to_string(iri)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp metadata_kind(graph, root, iri, nil) do
    if iri == root, do: graph |> Thesis.kind(iri) |> Atom.to_string(), else: "unknown"
  end

  defp metadata_kind(_graph, _root, _iri, type), do: Atom.to_string(type)

  defp metadata_title(graph, root, iri, nil) do
    if iri == root, do: document_title(graph, iri)
  end

  defp metadata_title(graph, _root, iri, :section), do: Thesis.heading(graph, iri)
  defp metadata_title(_graph, _root, _iri, _type), do: nil

  defp source_page_value(graph, iri) do
    case Thesis.source_page(graph, iri) do
      nil -> nil
      page when is_integer(page) -> to_string(page + 1)
      page -> to_string(page)
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

  defp document_title(graph, root), do: Thesis.title(graph, root)
end
