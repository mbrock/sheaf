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
    <div class="space-y-1 px-1">
      <div class="flex min-w-0 items-baseline gap-3">
        <span class="min-w-0 flex-1 truncate font-serif text-lg">{@document.title}</span>
        <span class="shrink-0 font-mono text-xs text-stone-500 dark:text-stone-400">
          {@document.id}
        </span>
      </div>

      <div
        :if={metadata_byline(@document)}
        class="truncate font-serif [font-variant-caps:small-caps]  text-stone-600 dark:text-stone-300"
      >
        {metadata_byline(@document)}
      </div>

      <div
        :if={metadata_publication(@document)}
        class="truncate text-xs text-stone-500 dark:text-stone-500"
      >
        {metadata_publication(@document)}
      </div>
    </div>
    """
  end

  defp metadata_byline(document) do
    metadata = Map.get(document, :metadata, %{})
    authors = Map.get(metadata, :authors, [])
    year = Map.get(metadata, :year)

    case {authors, year} do
      {[], nil} -> nil
      {[], year} -> year
      {authors, nil} -> Enum.join(authors, ", ")
      {authors, year} -> "#{Enum.join(authors, ", ")} (#{year})"
    end
  end

  defp metadata_publication(document) do
    metadata = Map.get(document, :metadata, %{})

    [
      Map.get(metadata, :kind),
      Map.get(metadata, :venue) || Map.get(metadata, :publisher),
      volume_issue(metadata),
      pages(metadata),
      doi(metadata)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp volume_issue(metadata) do
    case {Map.get(metadata, :volume), Map.get(metadata, :issue)} do
      {nil, nil} -> nil
      {volume, nil} -> "vol. #{volume}"
      {nil, issue} -> "issue #{issue}"
      {volume, issue} -> "#{volume}(#{issue})"
    end
  end

  defp pages(%{pages: pages}) when is_binary(pages) and pages != "", do: "pp. #{pages}"
  defp pages(_metadata), do: nil

  defp doi(%{doi: doi}) when is_binary(doi) and doi != "", do: "doi: #{doi}"
  defp doi(_metadata), do: nil

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
