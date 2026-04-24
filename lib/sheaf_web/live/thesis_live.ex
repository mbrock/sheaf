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
    ~H"""
    <div class="flex min-h-dvh bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <aside class="p-4 w-96 shrink-0 lg:sticky lg:top-0 lg:h-dvh lg:overflow-y-auto">
        <h1 class="font-bold text-lg">{document_title(@graph, @root)}</h1>
        <.toc entries={toc_entries(@graph, @root)} />
      </aside>

      <article id="document-start" class="p-4 flex mx-auto">
        <.reader_children graph={@graph} children={Thesis.children(@graph, @root)} level={0} />
      </article>
    </div>
    """
  end

  attr :entries, :list, required: true

  defp toc(assigns) do
    ~H"""
    <nav class="text-sm space-y-1">
      <a
        :for={entry <- @entries}
        href={"#block-#{entry.id}"}
        class={[
          "flex items-baseline ml-#{entry.level * 2}"
        ]}
      >
        <span class={[
          "min-w-0 flex-1 text-balance leading-5",
          if(entry.level == 0,
            do: "text-stone-950 dark:text-stone-50",
            else: "text-stone-600 dark:text-stone-400"
          )
        ]}>
          {entry.heading}
        </span>
      </a>
    </nav>
    """
  end

  attr :children, :list, required: true
  attr :graph, :any, required: true
  attr :level, :integer, required: true

  defp reader_children(assigns) do
    ~H"""
    <div class="space-y-4">
      <.reader_block :for={block <- @children} graph={@graph} block={block} level={@level} />
    </div>
    """
  end

  attr :block, :any, required: true
  attr :graph, :any, required: true
  attr :level, :integer, required: true

  defp reader_block(assigns) do
    case Thesis.block_type(assigns.graph, assigns.block) do
      :section -> reader_section(assigns)
      :paragraph -> reader_paragraph(assigns)
    end
  end

  defp reader_section(assigns) do
    ~H"""
    <details
      id={"block-#{Thesis.id(@block)}"}
      class="pl-4"
      open={true}
    >
      <summary class="cursor-pointer font-bold text-lg">
        {Thesis.heading(@graph, @block)}
      </summary>

      <.reader_children
        graph={@graph}
        children={Thesis.children(@graph, @block)}
        level={@level + 1}
      />
    </details>
    """
  end

  defp reader_paragraph(assigns) do
    ~H"""
    <p id={"block-#{Thesis.id(@block)}"} class="font-serif max-w-prose">
      {Thesis.paragraph_text(@graph, @block)}
    </p>
    """
  end

  defp toc_entries(nil, _root), do: []
  defp toc_entries(graph, root), do: collect_toc_entries(graph, Thesis.children(graph, root), 0)

  defp collect_toc_entries(graph, blocks, level) do
    Enum.flat_map(blocks, fn block ->
      if Thesis.block_type(graph, block) == :section do
        [
          %{id: Thesis.id(block), heading: Thesis.heading(graph, block), level: level}
          | collect_toc_entries(graph, Thesis.children(graph, block), level + 1)
        ]
      else
        []
      end
    end)
  end

  defp page_title(graph, root), do: document_title(graph, root)

  defp document_title(graph, root), do: Thesis.title(graph, root)
end
