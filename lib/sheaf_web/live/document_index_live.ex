defmodule SheafWeb.DocumentIndexLive do
  use SheafWeb, :live_view

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

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 px-6 py-8 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <div class="mx-auto max-w-5xl">
        <header class="mb-8">
          <h1 class="font-sans text-2xl font-bold">Sheaf</h1>
          <p class="mt-1 text-sm text-stone-500 dark:text-stone-400">Documents in the dataset</p>
        </header>

        <p :if={@error} class="border-l-2 border-rose-500 py-2 pl-3 text-sm text-rose-700">
          {@error}
        </p>

        <div :if={@documents != []} class="space-y-8">
          <section :for={{kind, documents} <- grouped_documents(@documents)}>
            <h2 class="mb-2 font-sans text-xs font-semibold uppercase tracking-wide text-stone-500 dark:text-stone-400">
              {kind_label(kind)}
            </h2>

            <ul class="divide-y divide-stone-200/80 border-y border-stone-200/80 dark:divide-stone-800/80 dark:border-stone-800/80">
              <li :for={document <- documents} class="py-3">
                <.link
                  :if={document.path}
                  navigate={document.path}
                  class="block rounded-sm transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80"
                >
                  <.document_row document={document} />
                </.link>

                <div :if={is_nil(document.path)}>
                  <.document_row document={document} />
                </div>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </main>
    """
  end

  attr :document, :map, required: true

  defp document_row(assigns) do
    ~H"""
    <div class="flex min-w-0 items-baseline gap-3 px-1">
      <span class="min-w-0 flex-1 truncate font-serif text-lg">{@document.title}</span>
      <span class="shrink-0 font-mono text-xs text-stone-500 dark:text-stone-400">
        {@document.id}
      </span>
    </div>
    <div class="mt-1 truncate px-1 font-mono text-xs text-stone-500 dark:text-stone-500">
      {@document.iri}
    </div>
    """
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
