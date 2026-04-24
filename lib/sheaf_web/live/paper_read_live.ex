defmodule SheafWeb.PaperReadLive do
  use SheafWeb, :live_view

  alias Sheaf.DatalabJSON

  @json_path "priv/papers/Reka_Tolg_-_KAPPA.datalab.json"

  @impl true
  def mount(_params, _session, socket) do
    case load_pages() do
      {:ok, pages} ->
        {:ok,
         socket
         |> assign(:page_title, "KAPPA")
         |> assign(:pages, pages)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:page_title, "KAPPA")
         |> assign(:pages, [])
         |> assign(:error, reason)}
    end
  end

  @impl true
  def render(%{error: nil} = assigns) do
    assigns = assign(assigns, :blocks, DatalabJSON.document_blocks(assigns.pages))

    ~H"""
    <div
      id="paper-reader"
      class="grid h-dvh grid-rows-[minmax(0,16rem)_auto_minmax(0,1fr)] overflow-hidden bg-stone-50 text-stone-950 lg:grid-cols-[24rem_minmax(0,1fr)] lg:grid-rows-[auto_minmax(0,1fr)]"
    >
      <aside class="min-h-0 overflow-y-auto p-4 lg:row-span-2">
        <h1 class="text-lg font-bold">KAPPA</h1>
        <.toc blocks={@blocks} />
      </aside>

      <div class="min-w-0 border-b border-stone-200/80 bg-stone-50/90 px-12 py-2 sm:px-8">
        <div class="mx-auto flex min-h-7 w-full max-w-prose items-center gap-3 overflow-hidden">
          <span class="min-w-0 flex-1 truncate font-serif text-lg lowercase text-stone-500 [font-variant-caps:small-caps]">
            The (im)possibilities of circular consumption
          </span>
        </div>
      </div>

      <article id="document-start" class="min-h-0 min-w-0 overflow-y-auto px-12 pb-4 sm:px-8">
        <div class="mx-auto w-full max-w-prose pt-4">
          <.reader_blocks blocks={@blocks} />
        </div>
      </article>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="grid min-h-dvh place-items-center bg-stone-50 p-8 text-stone-950">
      <div class="max-w-xl border border-stone-200 bg-white p-6">
        <p class="font-mono text-xs uppercase tracking-wide text-stone-500">KAPPA</p>
        <h1 class="mt-2 text-xl font-semibold">Could not load Datalab JSON</h1>
        <p class="mt-3 font-mono text-sm text-red-700">{inspect(@error)}</p>
      </div>
    </main>
    """
  end

  attr :blocks, :list, required: true

  defp toc(assigns) do
    assigns = assign(assigns, :sections, DatalabJSON.section_blocks(assigns.blocks))

    ~H"""
    <nav class="mt-4 text-sm">
      <.toc_list blocks={@sections} />
    </nav>
    """
  end

  attr :blocks, :list, required: true
  attr :class, :string, default: "space-y-1"

  defp toc_list(assigns) do
    ~H"""
    <ol class={@class}>
      <li :for={section <- @blocks}>
        <a
          href={"#paper-block-#{section.dom_id}"}
          class={[
            "-mx-1 flex items-baseline rounded-sm px-1 py-0.5 transition-colors hover:bg-stone-200/70",
            if(section.level == 1, do: "text-stone-950", else: "text-stone-600")
          ]}
        >
          <span class="min-w-0 flex-1 text-balance leading-5">
            {DatalabJSON.block_title(section.block)}
          </span>
        </a>

        <.toc_list
          :if={DatalabJSON.section_blocks(section.children) != []}
          blocks={DatalabJSON.section_blocks(section.children)}
          class="ml-4 mt-1 space-y-1"
        />
      </li>
    </ol>
    """
  end

  attr :blocks, :list, required: true

  defp reader_blocks(assigns) do
    ~H"""
    <div class="space-y-4">
      <.reader_block :for={block <- @blocks} block={block} />
    </div>
    """
  end

  attr :block, :map, required: true

  defp reader_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details
      id={"paper-block-#{@block.dom_id}"}
      class="space-y-3 [&:not([open])>summary]:text-stone-500 [&[open]>summary]:pb-2 [&[open]>summary]:text-stone-900 [&>summary::-webkit-details-marker]:hidden"
      open={true}
    >
      <summary class={section_heading_classes()}>
        {raw(DatalabJSON.block_html(@block.block))}
      </summary>

      <div class="pl-4">
        <.reader_blocks blocks={@block.children} />
      </div>
    </details>
    """
  end

  defp reader_block(assigns) do
    ~H"""
    <div id={"paper-block-#{@block.dom_id}"} class="relative max-w-prose font-serif leading-7">
      <span class="absolute right-full top-1 mr-3 w-10 text-right font-sans text-xs leading-5 text-stone-500">
        p{@block.page}
      </span>
      <div class={block_html_classes()}>
        {raw(DatalabJSON.block_html(@block.block))}
      </div>
    </div>
    """
  end

  defp load_pages do
    with {:ok, json} <- File.read(json_path()),
         {:ok, %{"children" => pages}} <- Jason.decode(json) do
      {:ok, pages}
    end
  end

  defp json_path do
    :sheaf
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:json_path, @json_path)
  end

  defp section_heading_classes do
    [
      "cursor-pointer list-none rounded-sm transition-colors",
      "[&_h1]:font-sans [&_h1]:text-lg [&_h1]:font-semibold",
      "[&_h2]:font-sans [&_h2]:text-lg [&_h2]:font-semibold",
      "[&_h3]:font-sans [&_h3]:text-base [&_h3]:font-semibold",
      "[&_h4]:font-sans [&_h4]:text-base [&_h4]:font-semibold",
      "[&_h5]:font-sans [&_h5]:text-sm [&_h5]:font-semibold",
      "[&_p]:inline"
    ]
  end

  defp block_html_classes do
    [
      "[&_a]:text-sky-700 [&_a]:underline",
      "[&_h1]:mb-4 [&_h1]:font-sans [&_h1]:text-2xl [&_h1]:font-bold",
      "[&_h2]:mb-3 [&_h2]:font-sans [&_h2]:text-xl [&_h2]:font-semibold",
      "[&_h3]:mb-3 [&_h3]:font-sans [&_h3]:text-lg [&_h3]:font-semibold",
      "[&_h4]:mb-2 [&_h4]:font-sans [&_h4]:font-semibold",
      "[&_img]:my-4 [&_img]:max-h-96 [&_img]:max-w-full",
      "[&_li]:my-1 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:mb-4 [&_ul]:list-disc [&_ul]:pl-6",
      "[&_table]:my-6 [&_table]:w-full [&_table]:border-collapse [&_td]:border [&_td]:border-stone-300 [&_td]:p-2 [&_th]:border [&_th]:border-stone-300 [&_th]:p-2"
    ]
  end
end
