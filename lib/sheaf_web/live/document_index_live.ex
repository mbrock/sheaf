defmodule SheafWeb.DocumentIndexLive do
  @moduledoc """
  Live landing page for stored documents and assistant research notes.
  """

  use SheafWeb, :live_view

  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantHistoryComponents
  import SheafWeb.DocumentEntryComponents, only: [document_entry: 1]

  @impl true
  def mount(_params, _session, socket) do
    {documents, document_error} = fetch_documents()
    {notes, notes_graph, notes_error} = AssistantHistoryComponents.fetch_notes()

    socket =
      socket
      |> assign(:page_title, "Sheaf")
      |> assign(:documents, documents)
      |> assign(:notes, notes)
      |> assign(:notes_graph, notes_graph)
      |> assign(:research_session_titles, AssistantHistoryComponents.research_session_titles())
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
      {:ok, documents} -> {Enum.filter(documents, &index_document?/1), nil}
      {:error, reason} -> {[], inspect(reason)}
    end
  end

  defp index_document?(%{kind: kind}) when kind in [:transcript, :spreadsheet], do: false
  defp index_document?(_document), do: true

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
            <div :if={kind} class="mb-1 flex items-baseline justify-between gap-3">
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
        <AssistantHistoryComponents.note_history
          notes={@notes}
          notes_graph={@notes_graph}
          notes_error={@notes_error}
          research_session_titles={@research_session_titles}
        />
      </AppChrome.right_sidebar>
    </main>
    """
  end

  defp grouped_documents(documents) do
    owner_documents = Enum.filter(documents, & &1.workspace_owner_authored?)
    library_documents = Enum.reject(documents, & &1.workspace_owner_authored?)

    owner_group =
      case owner_documents do
        [] -> []
        documents -> [{nil, Enum.sort_by(documents, &document_sort_key/1)}]
      end

    library_groups =
      library_documents
      |> Enum.group_by(&document_group/1)
      |> Enum.map(fn {kind, documents} ->
        {kind, Enum.sort_by(documents, &document_sort_key/1)}
      end)
      |> Enum.sort_by(fn {kind, documents} ->
        {kind_order(kind), kind_label(kind), first_title(documents)}
      end)

    owner_group ++ library_groups
  end

  defp document_sort_key(document) do
    {kind_order(document_group(document)), String.downcase(document.title)}
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
end
