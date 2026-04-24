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

      {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :blocks, document_blocks(assigns.graph, assigns.root))

    ~H"""
    <div
      id="thesis-reader"
      class="grid h-dvh grid-rows-[minmax(0,16rem)_auto_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-[auto_minmax(0,1fr)] dark:bg-stone-950 dark:text-stone-50"
      phx-hook="ThesisBreadcrumb"
    >
      <aside class="min-h-0 overflow-y-auto p-4 lg:row-span-2">
        <h1 class="font-bold text-lg">{document_title(@graph, @root)}</h1>
        <.toc graph={@graph} blocks={toc_blocks(@blocks)} />
      </aside>

      <div class="min-w-0 border-b border-stone-200/80 bg-stone-50/90 px-12 py-2 backdrop-blur sm:px-8 dark:border-stone-800/80 dark:bg-stone-950/90">
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

      <article id="document-start" class="min-h-0 min-w-0 overflow-y-auto px-12 pb-4 sm:px-8">
        <div class="mx-auto w-full max-w-prose pt-4">
          <.reader_blocks graph={@graph} blocks={@blocks} />
        </div>
      </article>
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
          class={[
            "-mx-1 flex items-baseline rounded-sm px-1 py-0.5 transition-colors",
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

  defp reader_blocks(assigns) do
    ~H"""
    <div class="space-y-4">
      <.reader_block :for={block <- @blocks} graph={@graph} block={block} />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :graph, :any, required: true

  defp reader_block(%{block: %{type: :document}} = assigns) do
    ~H"""
    <section id={"block-#{Thesis.id(@block.iri)}"} class="space-y-6">
      <h1 class="font-sans text-2xl font-bold">
        {document_title(@graph, @block.iri)}
      </h1>

      <.reader_blocks graph={@graph} blocks={@block.children} />
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
      <summary class="cursor-pointer list-none rounded-sm transition-colors">
        <h2 class="font-sans text-lg font-semibold">
          {section_title(@block.number, Thesis.heading(@graph, @block.iri))}
        </h2>
      </summary>

      <.reader_blocks graph={@graph} blocks={@block.children} />
    </details>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <p
      id={"block-#{Thesis.id(@block.iri)}"}
      class="relative max-w-prose font-serif leading-7"
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

  defp reader_block(%{block: %{type: :extracted}} = assigns) do
    assigns = assign(assigns, :page, Thesis.source_page(assigns.graph, assigns.block.iri))

    ~H"""
    <div
      id={"block-#{Thesis.id(@block.iri)}"}
      class="relative max-w-prose font-serif leading-7"
    >
      <span
        :if={@page}
        class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500 dark:text-stone-400"
      >
        p{@page + 1}
      </span>
      <div class={extracted_block_classes()}>
        {raw(Thesis.source_html(@graph, @block.iri))}
      </div>
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
          {%{type: :extracted, iri: iri}, {section_index, paragraph_index}}
      end
    end)
    |> elem(0)
  end

  defp section_title(number, heading) do
    "#{Enum.join(number, ".")}. #{heading}"
  end

  defp extracted_block_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline",
      "[&_h1]:mb-4 [&_h1]:font-sans [&_h1]:text-2xl [&_h1]:font-bold",
      "[&_h2]:mb-3 [&_h2]:font-sans [&_h2]:text-xl [&_h2]:font-semibold",
      "[&_h3]:mb-3 [&_h3]:font-sans [&_h3]:text-lg [&_h3]:font-semibold",
      "[&_h4]:mb-2 [&_h4]:font-sans [&_h4]:font-semibold",
      "[&_img]:my-4 [&_img]:max-h-96 [&_img]:max-w-full",
      "[&_li]:my-1 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:mb-4 [&_ul]:list-disc [&_ul]:pl-6",
      "[&_table]:my-6 [&_table]:w-full [&_table]:border-collapse [&_td]:border [&_td]:border-stone-300 [&_td]:p-2 [&_th]:border [&_th]:border-stone-300 [&_th]:p-2"
    ]
  end

  defp page_title(graph, root), do: document_title(graph, root)

  defp document_title(graph, root), do: Thesis.title(graph, root)
end
