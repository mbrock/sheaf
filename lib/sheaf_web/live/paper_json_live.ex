defmodule SheafWeb.PaperJsonLive do
  use SheafWeb, :live_view

  @default_json_path "priv/papers/Reka_Tolg_-_KAPPA.datalab.json"
  @default_result_path "tmp/datalab/kappa-full-json-result.json"

  @impl true
  def mount(_params, _session, socket) do
    case load_document() do
      {:ok, document, images} ->
        pages = Map.get(document, "children", [])
        block_types = block_type_counts(pages)

        socket =
          socket
          |> assign(:page_title, "Datalab JSON")
          |> assign(:document, document)
          |> assign(:images, images)
          |> assign(:pages, pages)
          |> assign(:block_types, block_types)
          |> assign(:total_blocks, total_blocks(block_types))
          |> assign(:error, nil)

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:page_title, "Datalab JSON")
          |> assign(:document, %{})
          |> assign(:images, %{})
          |> assign(:pages, [])
          |> assign(:block_types, [])
          |> assign(:total_blocks, 0)
          |> assign(:error, reason)

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    pages = socket.assigns.pages
    selected_page_index = selected_page_index(params, pages)
    selected_type = selected_type(params, socket.assigns.block_types)
    page = Enum.at(pages, selected_page_index, %{})

    visible_blocks =
      page
      |> Map.get("children", [])
      |> filter_blocks(selected_type)

    socket =
      socket
      |> assign(:selected_page_index, selected_page_index)
      |> assign(:selected_page_number, selected_page_index + 1)
      |> assign(:selected_type, selected_type)
      |> assign(:page, page)
      |> assign(:visible_blocks, visible_blocks)
      |> assign(:page_counts, block_type_counts([page]))

    {:noreply, socket}
  end

  @impl true
  def render(%{error: nil} = assigns) do
    ~H"""
    <div class="grid h-dvh grid-cols-[18rem_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950">
      <aside class="min-h-0 overflow-y-auto border-r border-stone-200 bg-white p-4">
        <div class="mb-4">
          <p class="text-xs font-semibold uppercase tracking-wide text-stone-500">Datalab JSON</p>
          <h1 class="mt-1 text-xl font-semibold leading-tight">KAPPA conversion</h1>
          <p class="mt-2 text-sm text-stone-600">
            {@total_blocks} blocks across {length(@pages)} pages.
          </p>
        </div>

        <div class="mb-4 space-y-2">
          <p class="text-xs font-semibold uppercase tracking-wide text-stone-500">Block Type</p>
          <.type_link page={@selected_page_number} type="all" selected_type={@selected_type}>
            All
          </.type_link>
          <.type_link
            :for={{type, count} <- @block_types}
            page={@selected_page_number}
            type={type}
            selected_type={@selected_type}
          >
            <span>{type}</span>
            <span class="text-stone-500">{count}</span>
          </.type_link>
        </div>

        <div>
          <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-500">Pages</p>
          <div class="grid grid-cols-3 gap-1">
            <.link
              :for={{page, index} <- Enum.with_index(@pages)}
              patch={viewer_path(index + 1, @selected_type)}
              class={[
                "rounded-sm border px-2 py-1 text-center text-xs tabular-nums transition-colors",
                if(index == @selected_page_index,
                  do: "border-stone-950 bg-stone-950 text-white",
                  else: "border-stone-200 bg-white text-stone-700 hover:border-stone-400"
                )
              ]}
              title={page_summary(page, index)}
            >
              {index + 1}
            </.link>
          </div>
        </div>
      </aside>

      <main class="min-h-0 min-w-0 overflow-y-auto">
        <header class="sticky top-0 z-10 border-b border-stone-200 bg-stone-50/95 px-6 py-4 backdrop-blur">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <p class="text-xs font-semibold uppercase tracking-wide text-stone-500">
                Page {@selected_page_number}
              </p>
              <h2 class="mt-1 text-2xl font-semibold">{page_summary(@page, @selected_page_index)}</h2>
            </div>
            <div class="flex flex-wrap gap-2">
              <span
                :for={{type, count} <- @page_counts}
                class="rounded-sm border border-stone-200 bg-white px-2 py-1 text-xs"
              >
                {type}: {count}
              </span>
            </div>
          </div>
        </header>

        <div class="space-y-4 p-6">
          <div
            :if={@visible_blocks == []}
            class="rounded-sm border border-dashed border-stone-300 bg-white p-8 text-center text-stone-500"
          >
            No blocks of type {@selected_type} on this page.
          </div>

          <article
            :for={block <- @visible_blocks}
            id={block_dom_id(block)}
            class="overflow-hidden rounded-sm border border-stone-200 bg-white"
          >
            <div class="flex flex-wrap items-center gap-2 border-b border-stone-200 bg-stone-100 px-4 py-2">
              <span class={[
                "rounded-sm px-2 py-1 text-xs font-semibold",
                type_badge_class(block_type(block))
              ]}>
                {block_type(block)}
              </span>
              <span class="font-mono text-xs text-stone-500">{Map.get(block, "id")}</span>
              <span class="ml-auto font-mono text-xs text-stone-500">
                bbox {bbox(block)}
              </span>
            </div>

            <div class="grid min-w-0 lg:grid-cols-[minmax(0,1fr)_minmax(22rem,0.8fr)]">
              <section class="min-w-0 border-b border-stone-200 p-4 lg:border-b-0 lg:border-r">
                <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-500">
                  Rendered HTML
                </p>
                <div class="datalab-preview min-w-0 max-w-none overflow-x-auto rounded-sm bg-stone-50 p-4 font-serif leading-7 text-stone-950 [&_a]:text-sky-700 [&_a]:underline [&_blockquote]:border-l-2 [&_blockquote]:border-stone-300 [&_blockquote]:pl-3 [&_h1]:mb-3 [&_h1]:font-sans [&_h1]:text-2xl [&_h1]:font-semibold [&_h2]:mb-3 [&_h2]:font-sans [&_h2]:text-xl [&_h2]:font-semibold [&_h3]:mb-2 [&_h3]:font-sans [&_h3]:text-lg [&_h3]:font-semibold [&_h4]:mb-2 [&_h4]:font-sans [&_h4]:font-semibold [&_hr]:my-3 [&_img]:mb-3 [&_img]:max-h-64 [&_img]:rounded-sm [&_img]:border [&_img]:border-stone-200 [&_li]:my-1 [&_ol]:list-decimal [&_ol]:pl-5 [&_p]:mb-3 [&_table]:w-full [&_table]:border-collapse [&_td]:border [&_td]:border-stone-300 [&_td]:p-2 [&_th]:border [&_th]:border-stone-300 [&_th]:bg-stone-100 [&_th]:p-2 [&_ul]:list-disc [&_ul]:pl-5">
                  {raw(preview_html(block, @images))}
                </div>
              </section>

              <section class="min-w-0 p-4">
                <p class="mb-2 text-xs font-semibold uppercase tracking-wide text-stone-500">
                  Block JSON
                </p>
                <pre class="max-h-[32rem] min-w-0 overflow-auto rounded-sm bg-stone-950 p-4 text-xs leading-5 text-stone-100"><code>{block_json(block)}</code></pre>
              </section>
            </div>
          </article>
        </div>
      </main>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="grid min-h-dvh place-items-center bg-stone-50 p-8 text-stone-950">
      <div class="max-w-xl rounded-sm border border-stone-200 bg-white p-6">
        <p class="text-xs font-semibold uppercase tracking-wide text-stone-500">Datalab JSON</p>
        <h1 class="mt-2 text-xl font-semibold">Could not load JSON</h1>
        <p class="mt-3 font-mono text-sm text-red-700">{inspect(@error)}</p>
      </div>
    </main>
    """
  end

  attr :page, :integer, required: true
  attr :type, :string, required: true
  attr :selected_type, :string, required: true
  slot :inner_block, required: true

  defp type_link(assigns) do
    ~H"""
    <.link
      patch={viewer_path(@page, @type)}
      class={[
        "flex items-center justify-between rounded-sm border px-2 py-1 text-sm transition-colors",
        if(@type == @selected_type,
          do: "border-stone-950 bg-stone-950 text-white",
          else: "border-stone-200 bg-white text-stone-700 hover:border-stone-400"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp load_document do
    with {:ok, json} <- File.read(json_path()),
         {:ok, document} <- Jason.decode(json) do
      {:ok, document, load_images()}
    end
  end

  defp load_images do
    result_path()
    |> File.read()
    |> case do
      {:ok, json} ->
        json
        |> Jason.decode()
        |> case do
          {:ok, %{"images" => images}} when is_map(images) -> images
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp json_path do
    configured_path(:json_path, @default_json_path)
  end

  defp result_path do
    configured_path(:result_path, @default_result_path)
  end

  defp configured_path(key, default) do
    :sheaf
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp block_type_counts(pages) do
    pages
    |> Enum.flat_map(&Map.get(&1, "children", []))
    |> Enum.frequencies_by(&block_type/1)
    |> Enum.sort_by(fn {type, count} -> {-count, type} end)
  end

  defp total_blocks(block_types) do
    block_types
    |> Enum.map(fn {_type, count} -> count end)
    |> Enum.sum()
  end

  defp selected_page_index(params, pages) do
    max_index = max(length(pages) - 1, 0)

    params
    |> Map.get("page", "1")
    |> parse_int(1)
    |> Kernel.-(1)
    |> max(0)
    |> min(max_index)
  end

  defp selected_type(%{"type" => "all"}, _block_types), do: "all"

  defp selected_type(%{"type" => type}, block_types) do
    block_types
    |> Enum.map(&elem(&1, 0))
    |> Enum.member?(type)
    |> if(do: type, else: "all")
  end

  defp selected_type(_params, _block_types), do: "all"

  defp filter_blocks(blocks, "all"), do: blocks

  defp filter_blocks(blocks, selected_type),
    do: Enum.filter(blocks, &(block_type(&1) == selected_type))

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp viewer_path(page, type) do
    ~p"/papers/kappa/datalab-json?#{[page: page, type: type]}"
  end

  defp page_summary(page, index) do
    page
    |> Map.get("children", [])
    |> Enum.find_value(fn block ->
      if block_type(block) in ["SectionHeader", "Text"] do
        block
        |> Map.get("html", "")
        |> plain_text()
        |> String.slice(0, 80)
      end
    end)
    |> case do
      nil -> "PDF page #{index + 1}"
      "" -> "PDF page #{index + 1}"
      text -> text
    end
  end

  defp preview_html(block, images) do
    block
    |> Map.get("html", "")
    |> inline_images(images)
  end

  defp inline_images(html, images) do
    Enum.reduce(images, html, fn {filename, base64}, html ->
      data_uri = "data:#{mime_type(filename)};base64,#{base64}"
      String.replace(html, ~s(src="#{filename}"), ~s(src="#{data_uri}"))
    end)
  end

  defp mime_type(filename) do
    case filename |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".tif" -> "image/tiff"
      ".tiff" -> "image/tiff"
      _ -> "image/jpeg"
    end
  end

  defp plain_text(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp block_type(block), do: Map.get(block, "block_type", "Unknown")

  defp type_badge_class("SectionHeader"), do: "bg-sky-100 text-sky-900"
  defp type_badge_class("Text"), do: "bg-stone-200 text-stone-900"
  defp type_badge_class("Table"), do: "bg-emerald-100 text-emerald-900"
  defp type_badge_class("Picture"), do: "bg-amber-100 text-amber-900"
  defp type_badge_class("Footnote"), do: "bg-violet-100 text-violet-900"
  defp type_badge_class(_type), do: "bg-stone-100 text-stone-800"

  defp bbox(block) do
    block
    |> Map.get("bbox", [])
    |> Enum.map_join(", ", &format_number/1)
  end

  defp format_number(number) when is_float(number),
    do: :erlang.float_to_binary(number, decimals: 1)

  defp format_number(number), do: to_string(number)

  defp block_dom_id(block) do
    "datalab-" <> String.replace(Map.get(block, "id", "block"), ~r/[^A-Za-z0-9_-]/, "-")
  end

  defp block_json(block), do: Jason.encode!(block, pretty: true)
end
