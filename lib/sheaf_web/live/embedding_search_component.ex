defmodule SheafWeb.EmbeddingSearchComponent do
  @moduledoc """
  Compact live semantic search over the SQLite embedding index.
  """

  use SheafWeb, :live_component

  alias Sheaf.Id

  @min_query_chars 3

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:error, nil)
     |> assign(:searched?, false)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:limit, fn -> 20 end)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    query = String.trim(query || "")

    cond do
      query == "" ->
        {:noreply, assign(socket, query: "", results: [], error: nil, searched?: false)}

      String.length(query) < @min_query_chars ->
        {:noreply, assign(socket, query: query, results: [], error: nil, searched?: false)}

      true ->
        socket =
          case Sheaf.Embedding.Index.search(query, limit: socket.assigns.limit) do
            {:ok, results} ->
              assign(socket, query: query, results: results, error: nil, searched?: true)

            {:error, reason} ->
              assign(socket, query: query, results: [], error: inspect(reason), searched?: true)
          end

        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="border-y border-stone-200/80 py-3 dark:border-stone-800/80">
      <div class="mb-2 flex items-end justify-between gap-3">
        <div class="min-w-0">
          <h2 class="font-sans text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
            Search
          </h2>
          <p class="mt-0.5 text-xs text-stone-500 dark:text-stone-400">
            Semantic search across papers, thesis paragraphs, and coded rows
          </p>
        </div>
        <span
          :if={@searched?}
          class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
        >
          {length(@results)}
        </span>
      </div>

      <.form for={%{}} as={:search} phx-submit="search" phx-target={@myself}>
        <div class="flex items-center gap-2 rounded-sm border border-stone-300 bg-white px-2 py-1.5 dark:border-stone-700 dark:bg-stone-900">
          <input
            type="search"
            name="search[query]"
            value={@query}
            autocomplete="off"
            placeholder="Search concepts, passages, or cases"
            class="min-w-0 flex-1 border-0 bg-transparent p-0 font-sans text-sm leading-6 text-stone-950 outline-none placeholder:text-stone-400 focus:ring-0 dark:text-stone-50 dark:placeholder:text-stone-500"
          />
          <button
            type="submit"
            title="Search"
            class="grid size-6 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
          >
            <.icon name="hero-magnifying-glass" class="size-4" />
          </button>
        </div>
      </.form>

      <p
        :if={@error}
        class="mt-2 border-l-2 border-rose-500 py-1 pl-3 text-xs leading-5 text-rose-700 dark:text-rose-300"
      >
        {@error}
      </p>

      <p
        :if={@searched? and @results == [] and is_nil(@error)}
        class="mt-2 text-xs leading-5 text-stone-500 dark:text-stone-400"
      >
        No matching indexed blocks.
      </p>

      <ol
        :if={@results != []}
        class="mt-3 max-h-[28rem] divide-y divide-stone-200/80 overflow-y-auto border-y border-stone-200/80 dark:divide-stone-800/80 dark:border-stone-800/80"
      >
        <li :for={result <- @results}>
          <.link
            href={block_path(result.iri)}
            class="block px-2 py-2 transition-colors hover:bg-stone-200/70 dark:hover:bg-stone-800/80"
          >
            <div class="flex min-w-0 items-baseline gap-2">
              <span class="shrink-0 font-mono text-[11px] text-stone-500 dark:text-stone-400">
                #{block_id(result.iri)}
              </span>
              <span class="min-w-0 flex-1 truncate font-serif text-sm text-stone-950 dark:text-stone-50">
                {result.doc_title || "Untitled document"}
              </span>
              <span class="shrink-0 font-sans text-[11px] tabular-nums text-stone-500 dark:text-stone-400">
                {score_percent(result.score)}
              </span>
            </div>

            <div class="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 font-sans text-[11px] leading-4 text-stone-500 dark:text-stone-400">
              <span class="rounded-sm border border-stone-200 px-1.5 py-0.5 uppercase leading-none dark:border-stone-800">
                {kind_label(result.kind)}
              </span>
              <span :if={context_label(result)} class="min-w-0 truncate">
                {context_label(result)}
              </span>
              <span class="uppercase">
                {match_label(result)}
              </span>
            </div>

            <p class="mt-1 line-clamp-2 text-xs leading-5 text-stone-700 dark:text-stone-300">
              {snippet(result.text)}
            </p>
          </.link>
        </li>
      </ol>
    </section>
    """
  end

  defp block_id(iri), do: Id.id_from_iri(iri)
  defp block_path(iri), do: "/b/#{block_id(iri)}"

  defp kind_label("sourceHtml"), do: "PDF"
  defp kind_label("paragraph"), do: "Paragraph"
  defp kind_label("row"), do: "Row"
  defp kind_label(kind), do: kind

  defp context_label(%{kind: "sourceHtml", source_page: page}) when is_integer(page),
    do: "p. #{page}"

  defp context_label(%{kind: "row"} = result) do
    [row_label(result.spreadsheet_row), result.spreadsheet_source, result.code_category_title]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp context_label(_result), do: nil

  defp row_label(nil), do: nil
  defp row_label(row), do: "row #{row}"

  defp score_percent(score) when is_float(score), do: "#{round(score * 100)}"
  defp score_percent(_score), do: ""

  defp match_label(%{match: :both}), do: "exact + semantic"
  defp match_label(%{match: :exact}), do: "exact"
  defp match_label(_result), do: "semantic"

  defp snippet(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
