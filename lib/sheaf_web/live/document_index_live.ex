defmodule SheafWeb.DocumentIndexLive do
  @moduledoc """
  Live landing page for stored documents and assistant research notes.
  """

  use SheafWeb, :live_view

  alias RDF.{Description, Graph}
  alias Sheaf.BlockRefs
  alias Sheaf.Assistant.Chats
  alias Sheaf.Assistant.Notes
  alias Sheaf.Id
  alias SheafWeb.AppChrome
  import SheafWeb.DocumentEntryComponents, only: [document_entry: 1]

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
    {notes, notes_graph, notes_error} = fetch_notes()

    socket =
      socket
      |> assign(:page_title, "Sheaf")
      |> assign(:documents, documents)
      |> assign(:notes, notes)
      |> assign(:notes_graph, notes_graph)
      |> assign(:research_session_titles, research_session_titles())
      |> assign(:document_error, document_error)
      |> assign(:notes_error, notes_error)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_document_exclusion", %{"id" => id, "included" => included}, socket) do
    excluded? = included not in ["true", true]

    case Sheaf.Workspace.set_document_excluded(id, excluded?) do
      :ok ->
        {documents, document_error} = fetch_documents()

        {:noreply,
         socket
         |> assign(:documents, documents)
         |> assign(:document_error, document_error)}

      {:error, reason} ->
        {:noreply, assign(socket, :document_error, inspect(reason))}
    end
  end

  defp fetch_documents do
    case Sheaf.Documents.list() do
      {:ok, documents} -> {documents, nil}
      {:error, reason} -> {[], inspect(reason)}
    end
  end

  defp fetch_notes do
    case Notes.list_graph(limit: 30) do
      {:ok, graph} -> {Notes.descriptions(graph), graph, nil}
      {:error, reason} -> {[], Graph.new(), inspect(reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="grid h-dvh grid-rows-[auto_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 xl:grid-cols-[minmax(0,1fr)_30rem] dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:index} />

      <div class="min-h-0 overflow-y-auto px-6 py-6 xl:col-start-1 xl:row-start-2">
        <p
          :if={@document_error}
          class="py-2 text-sm text-rose-700"
        >
          {@document_error}
        </p>

        <div :if={@documents != []} class="space-y-5">
          <section :for={{kind, documents} <- grouped_documents(@documents)}>
            <div class="mb-1 flex items-baseline justify-between gap-3">
              <h2 class="font-sans text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
                {kind_label(kind)}
              </h2>
              <span class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400">
                {length(documents)}
              </span>
            </div>

            <ul class="space-y-0.5">
              <li :for={document <- documents}>
                <.document_entry document={document} show_checkbox />
              </li>
            </ul>
          </section>
        </div>
      </div>

      <AppChrome.right_sidebar assistant_id="index-assistant" class="xl:col-start-2 xl:row-start-2">
        <section class="mt-4 min-w-0">
          <div class="mb-2 flex items-end justify-between gap-3">
            <h2 class="font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400">
              History
            </h2>
          </div>

          <p
            :if={@notes_error}
            class="py-2 text-sm text-rose-700"
          >
            {@notes_error}
          </p>

          <div :if={@notes != []} class="space-y-3">
            <section
              :for={group <- grouped_notes(@notes, @notes_graph, @research_session_titles)}
              class="space-y-0.5"
            >
              <div class="flex items-center gap-2 py-1">
                <.icon name={history_icon(group)} class={history_icon_class(group)} />
                <span class="min-w-0 flex-1 truncate font-sans text-sm text-stone-800 dark:text-stone-100">
                  {group.title}
                </span>
                <time
                  :if={group.published_at}
                  datetime={datetime_attr(group.published_at)}
                  class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
                >
                  {compact_time(group.published_at)}
                </time>
              </div>

              <ol class="space-y-0.5">
                <li :for={note <- group.notes}>
                  <.note_entry note={note} />
                </li>
              </ol>
            </section>
          </div>

          <p
            :if={@notes == [] and is_nil(@notes_error)}
            class="py-3 text-sm text-stone-500 dark:text-stone-400"
          >
            No research notes yet.
          </p>
        </section>
      </AppChrome.right_sidebar>
    </main>
    """
  end

  attr :note, :map, required: true

  defp note_entry(assigns) do
    ~H"""
    <details class="group rounded-sm">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-2 py-1.5 transition-colors hover:bg-stone-200/60 dark:hover:bg-stone-800/70 [&::-webkit-details-marker]:hidden">
        <span class="flex size-5 shrink-0 items-center justify-center text-stone-400 dark:text-stone-500">
          <.icon name="hero-document-text" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 truncate font-sans text-sm font-medium text-stone-800 dark:text-stone-100">
          {note_title(@note) || "Research note"}
        </span>
        <span class="block w-3 shrink-0 text-center font-mono text-xs leading-snug text-stone-400 transition-transform group-open:rotate-90 dark:text-stone-500">
          ▸
        </span>
      </summary>

      <article class="px-9 pb-3 pt-1 text-sm leading-6">
        <div class="assistant-prose max-h-72 overflow-y-auto pr-2 break-words text-stone-800 dark:text-stone-100">
          {raw(render_markdown(note_text(@note)))}
        </div>
      </article>
    </details>
    """
  end

  defp grouped_documents(documents) do
    documents
    |> Enum.group_by(&document_group/1)
    |> Enum.map(fn {kind, documents} ->
      {kind, Enum.sort_by(documents, &String.downcase(&1.title))}
    end)
    |> Enum.sort_by(fn {kind, documents} ->
      {kind_order(kind), kind_label(kind), first_title(documents)}
    end)
  end

  defp document_group(%{metadata: %{kind: kind}}) when is_binary(kind) do
    {:expression, kind}
  end

  defp document_group(%{kind: kind}), do: kind

  defp first_title([document | _documents]), do: String.downcase(document.title)
  defp first_title([]), do: ""

  defp kind_label({:expression, kind}), do: pluralize_expression_kind(kind)
  defp kind_label(:thesis), do: "Thesis"
  defp kind_label(:paper), do: "Papers"
  defp kind_label(:transcript), do: "Transcripts"
  defp kind_label(:spreadsheet), do: "Spreadsheets"
  defp kind_label(:document), do: "Documents"

  defp pluralize_expression_kind("Book"), do: "Books"
  defp pluralize_expression_kind("Book chapter"), do: "Book chapters"
  defp pluralize_expression_kind("Doctoral thesis"), do: "Doctoral theses"
  defp pluralize_expression_kind("Journal article"), do: "Journal articles"
  defp pluralize_expression_kind("Report document"), do: "Reports"
  defp pluralize_expression_kind(kind), do: kind <> "s"

  defp kind_order(:thesis), do: 0
  defp kind_order({:expression, "Journal article"}), do: 1
  defp kind_order({:expression, "Book"}), do: 2
  defp kind_order({:expression, "Book chapter"}), do: 3
  defp kind_order({:expression, "Doctoral thesis"}), do: 4
  defp kind_order({:expression, "Report document"}), do: 5
  defp kind_order({:expression, _kind}), do: 6
  defp kind_order(:paper), do: 6
  defp kind_order(:transcript), do: 7
  defp kind_order(:spreadsheet), do: 8
  defp kind_order(:document), do: 9

  defp research_session_titles do
    Chats.list()
    |> Enum.filter(&(chat_kind(&1) == :research))
    |> Map.new(&{&1.id, &1.title})
  end

  defp chat_kind(%{kind: kind}) when kind in [:research, "research"], do: :research
  defp chat_kind(_chat), do: :chat

  defp grouped_notes(notes, %Graph{} = graph, session_titles) do
    notes
    |> Enum.group_by(&note_context_iri/1)
    |> Enum.map(fn {session_iri, notes} ->
      %{
        session_iri: session_iri,
        notes: notes,
        published_at: group_published_at(notes),
        mode: session_mode(graph, session_iri)
      }
    end)
    |> Enum.map(&put_note_group_title(&1, graph, session_titles))
    |> Enum.sort_by(fn group -> group_sort_time(group.published_at) end, {:desc, DateTime})
  end

  defp put_note_group_title(%{session_iri: session_iri} = group, graph, session_titles) do
    title =
      graph
      |> research_question_content(session_iri)
      |> case do
        title
        when is_binary(title) and title not in ["", "Research session", "Assistant conversation"] ->
          title

        _other ->
          session_iri
          |> session_id()
          |> then(&Map.get(session_titles, &1))
          |> case do
            title
            when is_binary(title) and
                   title not in ["", "Research session", "Assistant conversation"] ->
              title

            _other ->
              case note_group_title(session_resource_label(graph, session_iri)) do
                title when title in ["Research session", "Assistant conversation"] ->
                  note_group_title_from_notes(group.notes)

                title ->
                  title
              end
          end
      end

    Map.put(group, :title, title)
  end

  defp research_question_content(_graph, nil), do: nil

  defp research_question_content(%Graph{} = graph, session_iri) do
    session = RDF.iri(session_iri)

    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.Message}))
    |> Enum.filter(&Description.include?(&1, {Sheaf.NS.AS.context(), session}))
    |> Enum.reject(&(Description.first(&1, Sheaf.NS.AS.inReplyTo()) != nil))
    |> Enum.sort_by(fn question ->
      question
      |> Description.first(Sheaf.NS.AS.published())
      |> rdf_value()
      |> case do
        %DateTime{} = published_at -> DateTime.to_unix(published_at)
        nil -> 0
        published_at -> to_string(published_at)
      end
    end)
    |> List.first()
    |> case do
      %Description{} = question -> first_value(question, Sheaf.NS.AS.content())
      nil -> nil
    end
  end

  defp note_group_title(nil), do: "Assistant conversation"
  defp note_group_title(""), do: "Assistant conversation"
  defp note_group_title("Research session " <> _id), do: "Research session"
  defp note_group_title("Assistant conversation " <> _id), do: "Assistant conversation"
  defp note_group_title(title), do: title

  defp note_group_title_from_notes(notes) do
    notes
    |> Enum.map(&note_title/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> common_note_title()
  end

  defp common_note_title([]), do: "Assistant conversation"
  defp common_note_title([title]), do: title

  defp common_note_title(titles) do
    prefix =
      titles
      |> Enum.reduce(&common_prefix/2)
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.trim_trailing("→")
      |> String.trim()

    if String.length(prefix) >= 12, do: prefix, else: hd(titles)
  end

  defp common_prefix(left, right) do
    left_chars = String.graphemes(left)
    right_chars = String.graphemes(right)

    left_chars
    |> Enum.zip(right_chars)
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map_join(fn {char, _} -> char end)
  end

  defp note_context_iri(%Description{} = note) do
    note
    |> Description.first(Sheaf.NS.AS.context())
    |> case do
      nil -> nil
      context -> to_string(context)
    end
  end

  defp session_id(nil), do: nil
  defp session_id(session_iri), do: Id.id_from_iri(session_iri)

  defp session_resource_label(_graph, nil), do: nil
  defp session_resource_label(graph, session_iri), do: resource_label(graph, RDF.iri(session_iri))

  defp session_mode(_graph, nil), do: nil

  defp session_mode(graph, session_iri) do
    graph
    |> RDF.Data.description(RDF.iri(session_iri))
    |> first_value(Sheaf.NS.DOC.conversationMode())
  end

  defp history_icon(%{mode: "research"}), do: "hero-beaker"
  defp history_icon(_group), do: "hero-chat-bubble-left-ellipsis"

  defp history_icon_class(%{mode: "research"}),
    do: "size-3.5 shrink-0 text-emerald-600 dark:text-emerald-300"

  defp history_icon_class(_group), do: "size-3.5 shrink-0 text-stone-400 dark:text-stone-500"

  defp group_published_at(notes) do
    notes
    |> Enum.map(&note_published_at/1)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp group_sort_time(%DateTime{} = published_at), do: published_at
  defp group_sort_time(_published_at), do: ~U[0000-01-01 00:00:00Z]

  defp note_title(%Description{} = note), do: first_value(note, RDF.NS.RDFS.label())
  defp note_text(%Description{} = note), do: first_value(note, Sheaf.NS.AS.content()) || ""

  defp note_published_at(%Description{} = note) do
    note
    |> Description.first(Sheaf.NS.AS.published())
    |> rdf_value()
  end

  defp datetime_attr(%DateTime{} = published_at), do: DateTime.to_iso8601(published_at)
  defp datetime_attr(published_at), do: to_string(published_at)

  defp compact_time(published_at) do
    case published_at do
      %DateTime{} = published_at -> Calendar.strftime(published_at, "%b %-d, %H:%M")
      published_at -> to_string(published_at)
    end
  end

  defp first_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> rdf_value()
  end

  defp resource_label(_graph, nil), do: nil

  defp resource_label(%Graph{} = graph, resource) do
    graph
    |> RDF.Data.description(resource)
    |> first_value(RDF.NS.RDFS.label())
  end

  defp rdf_value(nil), do: nil

  defp rdf_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

  defp render_markdown(text) do
    (text || "")
    |> BlockRefs.linkify_markdown()
    |> MDEx.to_html!(@mdex_opts)
  end
end
