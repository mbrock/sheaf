defmodule SheafWeb.DocumentIndexLive do
  use SheafWeb, :live_view

  alias Sheaf.BlockRefs
  alias Sheaf.Assistant.Notes
  alias Sheaf.Document

  @mdex_opts [
    extension: [
      strikethrough: true,
      autolink: true,
      table: true,
      tasklist: true
    ],
    render: [unsafe_: false, hardbreaks: true],
    parse: [smart: true]
  ]

  @impl true
  def mount(_params, _session, socket) do
    {documents, document_error} = fetch_documents()
    {notes, notes_error} = fetch_notes()

    socket =
      socket
      |> assign(:page_title, "Sheaf")
      |> assign(:documents, documents)
      |> assign(:notes, notes)
      |> assign(:document_error, document_error)
      |> assign(:notes_error, notes_error)
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

  defp fetch_documents do
    case Sheaf.Documents.list() do
      {:ok, documents} -> {documents, nil}
      {:error, reason} -> {[], inspect(reason)}
    end
  end

  defp fetch_notes do
    case Notes.list(limit: 30) do
      {:ok, notes} -> {notes, nil}
      {:error, reason} -> {[], inspect(reason)}
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
        <p
          :if={@document_error}
          class="mb-4 border-l-2 border-rose-500 py-2 pl-3 text-sm text-rose-700"
        >
          {@document_error}
        </p>

        <section class="mb-8">
          <div class="mb-2 flex items-end justify-between gap-3">
            <div>
              <h2 class="font-sans text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
                Research notes
              </h2>
              <p class="mt-0.5 text-xs text-stone-500 dark:text-stone-400">
                Activity from assistant research sessions
              </p>
            </div>
            <span
              :if={@notes != []}
              class="font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
            >
              {length(@notes)}
            </span>
          </div>

          <p
            :if={@notes_error}
            class="border-l-2 border-rose-500 py-2 pl-3 text-sm text-rose-700"
          >
            {@notes_error}
          </p>

          <ol
            :if={@notes != []}
            class="divide-y divide-stone-200/80 border-y border-stone-200/80 dark:divide-stone-800/80 dark:border-stone-800/80"
          >
            <li :for={note <- @notes}>
              <.note_entry note={note} />
            </li>
          </ol>

          <p
            :if={@notes == [] and is_nil(@notes_error)}
            class="border-y border-stone-200/80 py-3 text-sm text-stone-500 dark:border-stone-800/80 dark:text-stone-400"
          >
            No research notes yet.
          </p>
        </section>

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

  attr :note, :map, required: true

  defp note_entry(assigns) do
    ~H"""
    <article class="grid grid-cols-[5rem_minmax(0,1fr)] gap-3 px-2 py-3 text-sm leading-6">
      <div class="font-sans text-xs text-stone-500 dark:text-stone-400">
        <time :if={@note.published_at} datetime={note_datetime(@note)}>
          {note_time(@note)}
        </time>
        <span :if={is_nil(@note.published_at)}>Undated</span>
      </div>

      <div class="min-w-0 border-l-2 border-emerald-200 pl-3 dark:border-emerald-900">
        <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1 font-sans text-xs text-stone-500 dark:text-stone-400">
          <span class="font-semibold text-stone-700 dark:text-stone-300">
            {note_actor(@note)}
          </span>
          <span :if={note_context(@note) != ""}>in {note_context(@note)}</span>
        </div>

        <h3
          :if={@note.title}
          class="mt-1 truncate font-serif text-sm font-semibold text-stone-950 dark:text-stone-50"
        >
          {@note.title}
        </h3>

        <div class="assistant-prose mt-1 max-h-72 overflow-y-auto pr-2 break-words text-stone-800 dark:text-stone-100">
          {raw(render_markdown(@note.text))}
        </div>

        <div :if={@note.mentions != []} class="mt-2 flex flex-wrap gap-1.5">
          <.link
            :for={mention <- note_mentions_preview(@note)}
            href={mention.path}
            class="rounded-sm border border-stone-200 px-1.5 py-0.5 font-sans text-[0.6875rem] leading-none text-stone-600 transition-colors hover:border-stone-400 hover:text-stone-950 dark:border-stone-800 dark:text-stone-400 dark:hover:border-stone-600 dark:hover:text-stone-100"
          >
            #{mention.id}
          </.link>
          <span
            :if={hidden_mention_count(@note) > 0}
            class="rounded-sm border border-stone-200 px-1.5 py-0.5 font-sans text-[0.6875rem] leading-none text-stone-500 dark:border-stone-800 dark:text-stone-400"
          >
            +{hidden_mention_count(@note)}
          </span>
        </div>
      </div>
    </article>
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

  defp note_actor(%{agent_label: label}) when is_binary(label) and label != "", do: label
  defp note_actor(%{agent_id: id}) when is_binary(id) and id != "", do: "Agent #{id}"
  defp note_actor(_note), do: "Assistant"

  defp note_context(%{session_label: label}) when is_binary(label) and label != "", do: label
  defp note_context(%{session_id: id}) when is_binary(id) and id != "", do: "session #{id}"
  defp note_context(_note), do: ""

  defp note_datetime(%{published_at: %DateTime{} = published_at}),
    do: DateTime.to_iso8601(published_at)

  defp note_datetime(%{published_at: published_at}), do: to_string(published_at)

  defp note_time(%{published_at: %DateTime{} = published_at}) do
    Calendar.strftime(published_at, "%b %-d, %H:%M")
  end

  defp note_time(%{published_at: published_at}), do: to_string(published_at)

  defp note_mentions_preview(%{mentions: mentions}), do: Enum.take(mentions, 16)

  defp hidden_mention_count(%{mentions: mentions}) do
    max(length(mentions) - 16, 0)
  end

  defp render_markdown(text) do
    (text || "")
    |> BlockRefs.linkify_markdown()
    |> MDEx.to_html!(@mdex_opts)
  end
end
