defmodule SheafWeb.DocumentIndexLive do
  @moduledoc """
  Live landing page for stored documents.
  """

  use SheafWeb, :live_view

  require OpenTelemetry.Tracer, as: Tracer

  alias SheafWeb.AppChrome
  import SheafWeb.DocumentEntryComponents, only: [document_entry: 1]

  @impl true
  def mount(_params, _session, socket) do
    Tracer.with_span "SheafWeb.DocumentIndexLive.mount", %{
      kind: :internal,
      attributes: [
        {"sheaf.live.connected", connected?(socket)}
      ]
    } do
      {documents, document_error} = fetch_documents()

      Tracer.set_attributes([
        {"sheaf.document_count", length(documents)}
      ])

      socket =
        socket
        |> assign(:page_title, "Sheaf")
        |> assign(:documents, documents)
        |> assign(:document_error, document_error)

      {:ok, socket}
    end
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
    Tracer.with_span "SheafWeb.DocumentIndexLive.fetch_documents", %{kind: :internal} do
      case Sheaf.Documents.list() do
        {:ok, documents} ->
          index_documents = Enum.filter(documents, &index_document?/1)

          Tracer.set_attributes([
            {"sheaf.document_count.total", length(documents)},
            {"sheaf.document_count.index", length(index_documents)}
          ])

          {index_documents, nil}

        {:error, reason} ->
          Tracer.set_attribute("sheaf.error", inspect(reason))
          {[], inspect(reason)}
      end
    end
  end

  defp index_document?(%{kind: kind}) when kind in [:transcript, :spreadsheet], do: false
  defp index_document?(_document), do: true

  @impl true
  def render(assigns) do
    Tracer.with_span "SheafWeb.DocumentIndexLive.render", %{
      kind: :internal,
      attributes: [
        {"sheaf.document_count", length(assigns.documents)}
      ]
    } do
      assigns = assign(assigns, :document_groups, grouped_documents(assigns.documents))
      Tracer.set_attribute("sheaf.document_group_count", length(assigns.document_groups))

      ~H"""
      <main class="min-h-dvh max-w-full overflow-x-hidden bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
        <AppChrome.toolbar section={:index} />

        <div class="min-w-0 px-6 py-6">
          <p
            :if={@document_error}
            class="py-2 text-sm text-rose-700"
          >
            {@document_error}
          </p>

          <div :if={@documents != []} class="space-y-5">
            <section :for={{kind, documents} <- @document_groups}>
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
      </main>
      """
    end
  end

  defp grouped_documents(documents) do
    Tracer.with_span "SheafWeb.DocumentIndexLive.grouped_documents", %{
      kind: :internal,
      attributes: [{"sheaf.document_count", length(documents)}]
    } do
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

      groups = owner_group ++ library_groups
      Tracer.set_attribute("sheaf.document_group_count", length(groups))
      groups
    end
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
