defmodule SheafWeb.EmbeddingSearchComponent do
  @moduledoc """
  Compact live semantic search over the SQLite embedding index.
  """

  use SheafWeb, :live_component

  alias Sheaf.Id

  @min_query_chars 3
  @toolbar_group_limit 5
  @toolbar_visible_per_group 5
  @full_result_limit 20

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:query, "")
     |> assign(:results, [])
     |> assign(:exact_results, [])
     |> assign(:approximate_results, [])
     |> assign(:error, nil)
     |> assign(:searched?, false)}
  end

  @impl true
  def update(assigns, socket) do
    variant = Map.get(assigns, :variant, Map.get(socket.assigns, :variant, :full))
    limit = Map.get(assigns, :limit, Map.get(socket.assigns, :limit, default_limit(variant)))
    preview_limit = Map.get(assigns, :preview_limit, toolbar_visible_limit(variant))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:variant, variant)
     |> assign(:limit, limit)
     |> assign(:preview_limit, preview_limit)}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    search(query, socket)
  end

  @impl true
  def handle_event("search_key", %{"key" => "Enter", "value" => query}, socket) do
    search(query, socket)
  end

  def handle_event("search_key", _params, socket), do: {:noreply, socket}

  def handle_event("reset", _params, socket) do
    {:noreply,
     assign(socket,
       query: "",
       results: [],
       exact_results: [],
       approximate_results: [],
       error: nil,
       searched?: false
     )}
  end

  defp search(query, socket) do
    query = String.trim(query || "")

    cond do
      query == "" ->
        {:noreply,
         assign(socket,
           query: "",
           results: [],
           exact_results: [],
           approximate_results: [],
           error: nil,
           searched?: false
         )}

      String.length(query) < @min_query_chars ->
        {:noreply,
         assign(socket,
           query: query,
           results: [],
           exact_results: [],
           approximate_results: [],
           error: nil,
           searched?: false
         )}

      true ->
        {:noreply, run_search(socket, query)}
    end
  end

  defp run_search(%{assigns: %{variant: :toolbar}} = socket, query) do
    exact = Sheaf.Embedding.Index.exact_search(query, limit: socket.assigns.limit)
    approximate = Sheaf.Embedding.Index.search(query, limit: socket.assigns.limit, exact_limit: 0)

    case {exact, approximate} do
      {{:ok, exact_results}, {:ok, approximate_results}} ->
        assign(socket,
          query: query,
          results: exact_results ++ approximate_results,
          exact_results: exact_results,
          approximate_results: approximate_results,
          error: nil,
          searched?: true
        )

      {{:error, reason}, _} ->
        search_error(socket, query, reason)

      {_, {:error, reason}} ->
        search_error(socket, query, reason)
    end
  end

  defp run_search(socket, query) do
    case Sheaf.Embedding.Index.search(query, limit: socket.assigns.limit) do
      {:ok, results} ->
        assign(socket,
          query: query,
          results: results,
          exact_results: [],
          approximate_results: [],
          error: nil,
          searched?: true
        )

      {:error, reason} ->
        search_error(socket, query, reason)
    end
  end

  defp search_error(socket, query, reason) do
    assign(socket,
      query: query,
      results: [],
      exact_results: [],
      approximate_results: [],
      error: inspect(reason),
      searched?: true
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class={if @variant == :toolbar, do: "min-w-0 flex-1 sm:flex-none", else: nil}>
      <.toolbar_search :if={@variant == :toolbar} {assigns} />
      <.full_search :if={@variant != :toolbar} {assigns} />
    </section>
    """
  end

  defp toolbar_search(assigns) do
    assigns =
      assign(assigns, :open?, toolbar_open?(assigns.query, assigns.searched?, assigns.error))

    ~H"""
    <div
      class="relative z-20 min-w-0"
      phx-click-away="reset"
      phx-target={@myself}
    >
      <form phx-submit="search" phx-target={@myself}>
        <div class="flex h-9 w-full min-w-0 items-center gap-1.5 rounded-sm border border-stone-300 bg-white px-2 shadow-sm sm:w-[min(22rem,42vw)] sm:gap-2 dark:border-stone-700 dark:bg-stone-900">
          <input
            id={"#{@id}-input"}
            type="search"
            name="search[query]"
            value={@query}
            autocomplete="off"
            placeholder="Search"
            class="min-w-0 flex-1 border-0 bg-transparent p-0 font-sans text-sm leading-6 text-stone-950 outline-none placeholder:text-stone-400 focus:ring-0 dark:text-stone-50 dark:placeholder:text-stone-500"
          />
          <button
            type="submit"
            title="Search"
            class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-900 focus:outline-none focus:ring-2 focus:ring-stone-400 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
          >
            <.icon name="hero-magnifying-glass" class="size-4" />
          </button>
        </div>
      </form>

      <div
        :if={@open?}
        id={"#{@id}-results"}
        class="absolute right-0 top-full z-[100] w-[min(32rem,calc(100vw-2rem))] rounded-b-sm border-x border-b border-stone-300 bg-white p-1 text-stone-950 shadow-xl ring-1 ring-black/5 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:ring-white/10"
      >
        <.search_results
          query={@query}
          results={@results}
          exact_results={@exact_results}
          approximate_results={@approximate_results}
          searched?={@searched?}
          error={@error}
          search_path={~p"/search?q=#{@query}"}
          compact?={true}
          preview_limit={@preview_limit}
          result_limit={@limit}
        />
      </div>
    </div>
    """
  end

  defp toolbar_open?(query, searched?, error) do
    searched? or not blank?(query) or not is_nil(error)
  end

  defp default_limit(:toolbar), do: @toolbar_group_limit
  defp default_limit(_variant), do: @full_result_limit

  defp toolbar_visible_limit(:toolbar), do: @toolbar_visible_per_group
  defp toolbar_visible_limit(_variant), do: nil

  defp full_search(assigns) do
    ~H"""
    <div class="py-3">
      <div class="mb-2 flex justify-end">
        <span
          :if={@searched?}
          class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
        >
          {length(@results)}
        </span>
      </div>

      <form phx-submit="search" phx-target={@myself}>
        <div class="flex items-center gap-2 rounded-sm border border-stone-300 bg-white px-2 py-1.5 dark:border-stone-700 dark:bg-stone-900">
          <input
            id={"#{@id}-input"}
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
      </form>

      <.search_results
        query={@query}
        results={@results}
        exact_results={[]}
        approximate_results={[]}
        searched?={@searched?}
        error={@error}
        search_path={~p"/search?q=#{@query}"}
        compact?={false}
        result_limit={@limit}
      />
    </div>
    """
  end

  attr :results, :list, required: true
  attr :exact_results, :list, default: []
  attr :approximate_results, :list, default: []
  attr :searched?, :boolean, required: true
  attr :error, :string, default: nil
  attr :query, :string, default: ""
  attr :search_path, :string, default: nil
  attr :compact?, :boolean, default: false
  attr :preview_limit, :any, default: nil
  attr :result_limit, :any, default: nil

  defp search_results(assigns) do
    assigns =
      assigns
      |> assign(:visible_results, visible_results(assigns.results, assigns.preview_limit))
      |> assign(
        :visible_exact_results,
        visible_results(assigns.exact_results, assigns.preview_limit)
      )
      |> assign(
        :visible_approximate_results,
        visible_results(assigns.approximate_results, assigns.preview_limit)
      )

    ~H"""
    <p
      :if={@error}
      class="py-1 text-xs leading-5 text-rose-700 dark:text-rose-300"
    >
      {@error}
    </p>

    <p
      :if={@searched? and @results == [] and is_nil(@error)}
      class="text-xs leading-5 text-stone-500 dark:text-stone-400"
    >
      No matching indexed blocks.
    </p>

    <p
      :if={not @searched? and is_nil(@error)}
      class="text-xs leading-5 text-stone-500 dark:text-stone-400"
    >
      Search indexed passages and coded rows.
    </p>

    <div :if={@compact? and @visible_exact_results != []} class="pb-1">
      <.result_group_title title="Exact matches" />
      <.result_list query={@query} results={@visible_exact_results} compact?={@compact?} />
    </div>

    <div :if={@compact? and @visible_approximate_results != []} class="pb-1">
      <.result_group_title title="Approximate matches" />
      <.result_list query={@query} results={@visible_approximate_results} compact?={@compact?} />
    </div>

    <.result_list
      :if={!@compact? and @visible_results != []}
      query={@query}
      results={@visible_results}
      compact?={@compact?}
    />

    <.link
      :if={@searched? and @search_path}
      navigate={@search_path}
      class="mt-1 block bg-stone-100 px-2 py-1.5 text-center font-sans text-[10px] font-medium uppercase tracking-wide text-stone-600 transition-colors hover:bg-stone-200 hover:text-stone-950 dark:bg-stone-800/80 dark:text-stone-300 dark:hover:bg-stone-700 dark:hover:text-stone-50"
    >
      Show all results
    </.link>
    """
  end

  attr :title, :string, required: true

  defp result_group_title(assigns) do
    ~H"""
    <div class="px-2 pb-0.5 pt-1 font-sans text-[9px] font-medium uppercase tracking-wide text-stone-500 dark:text-stone-400">
      {@title}
    </div>
    """
  end

  attr :results, :list, required: true
  attr :query, :string, required: true
  attr :compact?, :boolean, default: false

  defp result_list(assigns) do
    ~H"""
    <ol class={[
      "overflow-y-auto",
      if(@compact?, do: "", else: "max-h-[30rem] space-y-0.5 pr-1")
    ]}>
      <li :for={result <- @results}>
        <article class={[
          "transition-colors hover:bg-stone-100 dark:hover:bg-stone-800/80",
          if(@compact?, do: "px-2 py-0.5", else: "px-2 py-1.5")
        ]}>
          <div class="flex min-w-0 items-baseline gap-2">
            <.link
              href={block_path(result.iri)}
              class={[
                "min-w-0 flex-1 truncate font-sans text-stone-950 hover:underline dark:text-stone-50",
                if(@compact?, do: "text-[11px] font-normal", else: "text-xs font-medium")
              ]}
            >
              {result.doc_title || "Untitled document"}
            </.link>
            <span class="shrink-0 font-sans text-[10px] tabular-nums text-stone-500 dark:text-stone-400">
              {score_percent(result.score)}
            </span>
          </div>

          <div class={[
            "flex min-w-0 items-baseline gap-1.5 font-sans text-[10px] text-stone-500 dark:text-stone-400",
            if(@compact?, do: "mt-0 leading-3", else: "mt-0.5 leading-4")
          ]}>
            <span
              :if={authors_line(result)}
              class="small-caps min-w-0 truncate text-stone-600 dark:text-stone-300"
            >
              {authors_line(result)}
            </span>
            <span :if={context_label(result)} class="min-w-0 truncate">
              {context_label(result)}
            </span>
          </div>

          <div class={[
            "overflow-hidden break-words text-stone-700 dark:text-stone-200 [&_a]:underline [&_br]:hidden [&_i]:italic [&_li]:mb-0.5 [&_ol]:m-0 [&_ol]:list-inside [&_ol]:list-decimal [&_p]:m-0 [&_ul]:m-0 [&_ul]:list-inside [&_ul]:list-disc",
            if(@compact?,
              do: "mt-0.5 line-clamp-2 text-[10px] leading-[0.9rem]",
              else: "mt-1 max-h-24 text-[11px] leading-4"
            )
          ]}>
            {raw(snippet_html(result, @query))}
          </div>
        </article>
      </li>
    </ol>
    """
  end

  defp visible_results(results, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(results, limit)

  defp visible_results(results, _limit), do: results

  defp block_id(iri), do: Id.id_from_iri(iri)
  defp block_path(iri), do: "/b/#{block_id(iri)}"

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

  defp excerpt_around(text, query, radius \\ 260) do
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
          "<mark class=\"bg-yellow-200/50 px-0.5 text-inherit dark:bg-yellow-400/25\">" <>
            escaped_text(part) <> "</mark>"
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
