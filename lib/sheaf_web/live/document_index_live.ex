defmodule SheafWeb.DocumentIndexLive do
  use SheafWeb, :live_view

  alias Sheaf.Document

  @impl true
  def mount(_params, _session, socket) do
    socket =
      case Sheaf.Documents.list() do
        {:ok, documents} ->
          socket
          |> assign(:page_title, "Sheaf")
          |> assign(:documents, documents)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:page_title, "Sheaf")
          |> assign(:documents, [])
          |> assign(:error, inspect(reason))
      end

    socket =
      socket
      |> assign(:expanded, MapSet.new())
      |> assign(:tocs, %{})

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_toc", %{"id" => id}, socket) do
    expanded = socket.assigns.expanded
    tocs = socket.assigns.tocs

    if MapSet.member?(expanded, id) do
      {:noreply, assign(socket, :expanded, MapSet.delete(expanded, id))}
    else
      document = Enum.find(socket.assigns.documents, &(&1.id == id))

      tocs =
        if document && not Map.has_key?(tocs, id) do
          Map.put(tocs, id, fetch_toc(document))
        else
          tocs
        end

      {:noreply,
       socket
       |> assign(:expanded, MapSet.put(expanded, id))
       |> assign(:tocs, tocs)}
    end
  end

  defp fetch_toc(document) do
    case Sheaf.fetch_graph(document.iri) do
      {:ok, graph} -> Document.toc(graph, document.iri)
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 px-6 py-6 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <div class="mx-auto max-w-5xl">
        <header class="mb-5">
          <h1 class="font-sans text-2xl font-bold">Sheaf</h1>
          <p class="mt-0.5 text-sm text-stone-500 dark:text-stone-400">Documents in the dataset</p>
        </header>

        <p :if={@error} class="border-l-2 border-rose-500 py-2 pl-3 text-sm text-rose-700">
          {@error}
        </p>

        <div :if={@documents != []} class="space-y-5">
          <section :for={{kind, documents} <- grouped_documents(@documents)}>
            <h2 class="mb-1 font-sans text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
              {kind_label(kind)}
            </h2>

            <ul class="divide-y divide-stone-200/80 border-y border-stone-200/80 dark:divide-stone-800/80 dark:border-stone-800/80">
              <li :for={document <- documents}>
                <.document_entry
                  document={document}
                  expanded={MapSet.member?(@expanded, document.id)}
                  toc={Map.get(@tocs, document.id, [])}
                />
              </li>
            </ul>
          </section>
        </div>
      </div>
    </main>
    """
  end

  attr :document, :map, required: true
  attr :expanded, :boolean, default: false
  attr :toc, :list, default: []

  defp document_entry(assigns) do
    ~H"""
    <div class="flex items-stretch gap-0">
      <button
        type="button"
        phx-click="toggle_toc"
        phx-value-id={@document.id}
        aria-expanded={@expanded}
        aria-label={if(@expanded, do: "Collapse outline", else: "Expand outline")}
        class="shrink-0 px-2 py-1.5 text-stone-400 transition-colors hover:bg-stone-200/70 hover:text-stone-900 dark:text-stone-500 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
      >
        <span class={[
          "block w-3 text-center font-mono text-xs leading-snug transition-transform",
          @expanded && "rotate-90"
        ]}>
          ▸
        </span>
      </button>

      <div class="min-w-0 flex-1">
        <.link
          :if={@document.path}
          navigate={@document.path}
          class="block transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80"
        >
          <.document_row document={@document} />
        </.link>

        <div :if={is_nil(@document.path)}>
          <.document_row document={@document} />
        </div>

        <div
          :if={@expanded}
          class="border-l-2 border-stone-200 py-2 pl-2 pr-2 dark:border-stone-800"
        >
          <.block_outline
            :if={@toc != []}
            entries={@toc}
            base_path={@document.path}
            class="text-xs"
          />
          <p :if={@toc == []} class="px-2 text-xs italic text-stone-500 dark:text-stone-400">
            No outline available.
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :document, :map, required: true

  defp document_row(assigns) do
    ~H"""
    <div class="px-2 py-1.5 text-sm leading-snug">
      <div class="truncate font-serif">{@document.title}</div>

      <div
        :if={subline?(@document)}
        class="flex min-w-0 items-baseline gap-3 text-xs text-stone-500 dark:text-stone-400"
      >
        <span class="w-10 shrink-0 tabular-nums">{year_str(@document)}</span>

        <span class="min-w-0 flex-1 truncate font-serif text-stone-600 [font-variant-caps:small-caps] dark:text-stone-300">
          {authors_str(@document) || ""}
        </span>

        <span class="shrink-0 tabular-nums">{page_count_str(@document)}</span>
      </div>
    </div>
    """
  end

  defp subline?(document) do
    authors_str(document) != nil or year_str(document) != "" or
      page_count_str(document) != ""
  end

  defp authors_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:authors, []) do
      [] -> nil
      authors -> Enum.join(authors, ", ")
    end
  end

  defp year_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:year) do
      nil -> ""
      year -> to_string(year)
    end
  end

  defp page_count_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:page_count) do
      nil -> ""
      count -> "#{count} pp."
    end
  end

  defp grouped_documents(documents) do
    documents
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _documents} -> kind_order(kind) end)
  end

  defp kind_label(:thesis), do: "Thesis"
  defp kind_label(:paper), do: "Papers"
  defp kind_label(:transcript), do: "Transcripts"
  defp kind_label(:document), do: "Documents"

  defp kind_order(:thesis), do: 0
  defp kind_order(:paper), do: 1
  defp kind_order(:transcript), do: 2
  defp kind_order(:document), do: 3
end
