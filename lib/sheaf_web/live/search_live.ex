defmodule SheafWeb.SearchLive do
  @moduledoc """
  Full-page corpus search with exact and approximate result groups.
  """

  use SheafWeb, :live_view

  alias Sheaf.Id
  alias SheafWeb.AppChrome

  @limit 40

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Search")
     |> assign(:query, "")
     |> assign(:exact_results, [])
     |> assign(:approximate_results, [])
     |> assign(:exact_error, nil)
     |> assign(:approximate_error, nil)
     |> assign(:searched?, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.trim()
    {:noreply, run_search(socket, query)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?q=#{String.trim(query || "")}")}
  end

  defp run_search(socket, query) do
    cond do
      query == "" ->
        assign(socket,
          query: "",
          exact_results: [],
          approximate_results: [],
          exact_error: nil,
          approximate_error: nil,
          searched?: false
        )

      String.length(query) < 3 ->
        assign(socket,
          query: query,
          exact_results: [],
          approximate_results: [],
          exact_error: nil,
          approximate_error: nil,
          searched?: false
        )

      true ->
        {exact_results, exact_error} =
          case Sheaf.Embedding.Index.exact_search(query, limit: @limit) do
            {:ok, results} -> {results, nil}
            {:error, reason} -> {[], inspect(reason)}
          end

        {approximate_results, approximate_error} =
          case Sheaf.Embedding.Index.search(query, limit: @limit, exact_limit: 0) do
            {:ok, results} -> {results, nil}
            {:error, reason} -> {[], inspect(reason)}
          end

        assign(socket,
          query: query,
          exact_results: exact_results,
          approximate_results: approximate_results,
          exact_error: exact_error,
          approximate_error: approximate_error,
          searched?: true
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:document} search?={false} />

      <div class="overflow-x-hidden px-6 py-5">
        <div class="mx-auto min-w-0 max-w-5xl">
          <form phx-submit="search" class="mb-5">
            <div class="flex items-center gap-2 border-b border-stone-300 bg-white px-2 py-2 dark:border-stone-700 dark:bg-stone-900">
              <input
                type="search"
                name="search[query]"
                value={@query}
                autocomplete="off"
                placeholder="Search passages"
                class="min-w-0 flex-1 border-0 bg-transparent p-0 font-sans text-base leading-7 text-stone-950 outline-none placeholder:text-stone-400 focus:ring-0 dark:text-stone-50 dark:placeholder:text-stone-500"
              />
              <button
                type="submit"
                title="Search"
                class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
              >
                <.icon name="hero-magnifying-glass" class="size-4" />
              </button>
            </div>
          </form>

          <div :if={!@searched?} class="text-sm text-stone-500 dark:text-stone-400">
            Search indexed passages across the corpus.
          </div>

          <div :if={@searched?} class="grid min-w-0 gap-7 lg:grid-cols-2">
            <.result_section
              title="Exact Matches"
              query={@query}
              results={@exact_results}
              error={@exact_error}
            />
            <.result_section
              title="Approximate Matches"
              query={@query}
              results={@approximate_results}
              error={@approximate_error}
            />
          </div>
        </div>
      </div>
    </main>
    """
  end

  attr :title, :string, required: true
  attr :query, :string, required: true
  attr :results, :list, required: true
  attr :error, :string, default: nil

  defp result_section(assigns) do
    ~H"""
    <section class="min-w-0">
      <div class="mb-2 flex items-baseline justify-between gap-3">
        <h2 class="font-sans text-xs font-semibold uppercase tracking-wide text-stone-500 dark:text-stone-400">
          {@title}
        </h2>
        <span class="text-xs tabular-nums text-stone-500 dark:text-stone-400">
          {length(@results)}
        </span>
      </div>

      <p :if={@error} class="py-2 text-xs leading-5 text-rose-700 dark:text-rose-300">
        {@error}
      </p>

      <p
        :if={@results == [] and is_nil(@error)}
        class="py-2 text-xs leading-5 text-stone-500 dark:text-stone-400"
      >
        No matches.
      </p>

      <ol :if={@results != []} class="space-y-2">
        <li :for={result <- @results}>
          <article class="min-w-0 border-t border-stone-200 pt-2 dark:border-stone-800">
            <div class="flex min-w-0 items-baseline gap-2">
              <.link
                href={block_path(result.iri)}
                class="min-w-0 flex-1 truncate font-sans text-sm font-medium text-stone-950 hover:underline dark:text-stone-50"
              >
                {result.doc_title || "Untitled document"}
              </.link>
              <span class="shrink-0 text-[11px] tabular-nums text-stone-500 dark:text-stone-400">
                {score_percent(result.score)}
              </span>
            </div>

            <div class="mt-0.5 flex min-w-0 items-baseline gap-2 text-[11px] leading-4 text-stone-500 dark:text-stone-400">
              <span
                :if={authors_line(result)}
                class="small-caps min-w-0 truncate text-stone-600 dark:text-stone-300"
              >
                {authors_line(result)}
              </span>
              <span :if={context_label(result)}>{context_label(result)}</span>
            </div>

            <div class="mt-1.5 max-h-40 overflow-hidden break-words text-xs leading-5 text-stone-700 dark:text-stone-200 [&_mark]:bg-yellow-200/50 [&_mark]:px-0.5 [&_mark]:text-inherit dark:[&_mark]:bg-yellow-400/25">
              {raw(snippet_html(result, @query))}
            </div>
          </article>
        </li>
      </ol>
    </section>
    """
  end

  defp block_path(iri), do: "/b/#{Id.id_from_iri(iri)}"

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

  defp score_percent(score) when is_float(score), do: "#{round(score * 100)}%"
  defp score_percent(_score), do: ""

  defp authors_line(%{doc_authors: authors}) when is_list(authors) and authors != [] do
    authors
    |> Enum.take(4)
    |> Enum.join(", ")
  end

  defp authors_line(_result), do: nil

  defp snippet_html(%{text: text}, query) do
    text
    |> plain_text()
    |> excerpt_around(query)
    |> highlight_query(query)
  end

  defp excerpt_around(text, query, radius \\ 360) do
    text = normalize_text(text)
    query = String.trim(query || "")

    if query == "" do
      String.slice(text, 0, radius * 2)
    else
      haystack = String.downcase(text)
      needle = String.downcase(query)

      case :binary.match(haystack, needle) do
        {index, length} ->
          start = max(index - radius, 0)
          finish = min(index + length + radius, String.length(text))
          prefix = if start > 0, do: "... ", else: ""
          suffix = if finish < String.length(text), do: " ...", else: ""
          prefix <> String.slice(text, start, finish - start) <> suffix

        :nomatch ->
          String.slice(text, 0, radius * 2)
      end
    end
  end

  defp highlight_query(text, query) do
    query = String.trim(query || "")

    if query == "" do
      escaped_text(text)
    else
      pattern = Regex.compile!(Regex.escape(query), "iu")

      pattern
      |> Regex.split(text, include_captures: true)
      |> Enum.map_join(fn part ->
        if String.downcase(part) == String.downcase(query) do
          "<mark>" <> escaped_text(part) <> "</mark>"
        else
          escaped_text(part)
        end
      end)
    end
  end

  defp plain_text(text) do
    text
    |> to_string()
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end

  defp normalize_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp escaped_text(text) do
    text
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
