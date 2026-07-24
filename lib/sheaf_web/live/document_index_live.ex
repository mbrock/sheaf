defmodule SheafWeb.DocumentIndexLive do
  @moduledoc """
  Live landing page for stored documents.
  """

  use SheafWeb, :live_view

  require OpenTelemetry.Tracer, as: Tracer

  alias SheafWeb.AppChrome
  import SheafWeb.DocumentEntryComponents, only: [document_card: 1]

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
  def handle_event(
        "toggle_document_exclusion",
        %{"id" => id, "included" => included},
        socket
      ) do
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
    Tracer.with_span "SheafWeb.DocumentIndexLive.fetch_documents", %{
      kind: :internal
    } do
      case Sheaf.Documents.list() do
        {:ok, documents} ->
          index_documents = Enum.filter(documents, &index_document?/1)
          mentions = Sheaf.DocumentMentions.for_documents(index_documents)

          index_documents =
            Enum.map(index_documents, fn document ->
              Map.put(document, :mentions, Map.get(mentions, document.id, []))
            end)

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

  defp index_document?(%{kind: kind})
       when kind in [:transcript, :spreadsheet], do: false

  defp index_document?(_document), do: true

  @impl true
  def render(assigns) do
    Tracer.with_span "SheafWeb.DocumentIndexLive.render", %{
      kind: :internal,
      attributes: [
        {"sheaf.document_count", length(assigns.documents)}
      ]
    } do
      assigns =
        assign(
          assigns,
          :document_groups,
          grouped_documents(assigns.documents)
        )

      Tracer.set_attribute(
        "sheaf.document_group_count",
        length(assigns.document_groups)
      )

      ~H"""
      <main class="min-h-dvh max-w-full overflow-x-hidden bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
        <AppChrome.toolbar section={:index} />
        <.live_component
          module={SheafWeb.BlockPreviewComponent}
          id="document-index-preview"
        />

        <div class="min-w-0">
          <p
            :if={@document_error}
            class="py-2 text-sm text-rose-700"
          >
            {@document_error}
          </p>

          <div :if={@documents != []} class="space-y-6 px-3 py-3 sm:px-4 lg:px-5">
            <section :for={{folder, documents} <- @document_groups} class="min-w-0">
              <div class="mb-2 flex items-baseline gap-2.5">
                <h2 class="font-sans text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
                  {folder_label(folder)}
                </h2>
                <span class="shrink-0 font-sans text-[11px] tabular-nums text-stone-500 dark:text-stone-400">
                  {length(documents)}
                </span>
              </div>
              <div class="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6">
                <.document_card :for={document <- documents} document={document} />
              </div>
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
      groups =
        documents
        |> Enum.group_by(&Map.get(&1, :folder))
        |> Enum.map(fn {folder, documents} ->
          {folder, Enum.sort_by(documents, &document_sort_key/1)}
        end)
        |> Enum.sort_by(fn {folder, documents} ->
          {is_nil(folder), String.downcase(folder || ""),
           first_title(documents)}
        end)

      Tracer.set_attribute("sheaf.document_group_count", length(groups))
      groups
    end
  end

  defp document_sort_key(document) do
    String.downcase(document.title)
  end

  defp first_title([document | _documents]),
    do: String.downcase(document.title)

  defp first_title([]), do: ""

  defp folder_label(nil), do: "Unfiled"
  defp folder_label(folder), do: folder
end
