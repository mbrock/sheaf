defmodule SheafWeb.BlockPreviewComponent do
  @moduledoc """
  On-demand block reference preview overlay.
  """

  use SheafWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :preview, nil)}
  end

  @impl true
  def handle_event("show_resource_preview", %{"id" => id}, socket) do
    {:noreply, assign(socket, :preview, Sheaf.ResourcePreviews.get(id))}
  end

  def handle_event("show_block_preview", %{"id" => id}, socket) do
    {:noreply, assign(socket, :preview, Sheaf.ResourcePreviews.get(id))}
  end

  def handle_event("hide_block_preview", _params, socket) do
    {:noreply, assign(socket, :preview, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <div :if={@preview} class="contents">
        <button
          type="button"
          class="fixed inset-0 z-40 bg-stone-950/45 dark:bg-stone-950/60"
          phx-click="hide_block_preview"
          phx-target={@myself}
          aria-label="Close block preview"
        >
        </button>
        <aside
          role="tooltip"
          class="fixed inset-x-3 bottom-[4.5rem] z-50 max-h-[min(20rem,calc(100dvh-8rem))] overflow-y-auto rounded-sm border border-stone-200 bg-white p-2.5 text-left shadow-lg ring-1 ring-stone-950/5 sm:left-4 sm:right-auto sm:top-16 sm:bottom-auto sm:max-h-none sm:w-[min(24rem,calc(100vw-2rem))] sm:overflow-visible dark:border-stone-700 dark:bg-stone-900 dark:ring-white/10"
        >
          <div class="mb-1.5 flex min-w-0 items-start gap-2 font-sans leading-4">
            <div class="min-w-0 flex-1">
              <div class="small-caps truncate text-[0.78rem] text-stone-700 dark:text-stone-200">
                {preview_document_label(@preview)}
              </div>
              <div
                :if={preview_year(@preview) || preview_authors(@preview) != []}
                class="flex min-w-0 items-baseline gap-2 text-[0.72rem] text-stone-500 dark:text-stone-400"
              >
                <span :if={preview_year(@preview)} class="shrink-0 tabular-nums">
                  {preview_year(@preview)}
                </span>
                <span :if={preview_authors(@preview) != []} class="small-caps min-w-0 truncate">
                  {Enum.join(preview_authors(@preview), ", ")}
                </span>
              </div>
            </div>
            <a
              href={Map.get(@preview, :path)}
              target="_blank"
              rel="noopener noreferrer"
              class="grid size-6 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-100 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
              title="Open page"
              aria-label="Open page"
            >
              <.icon name="hero-arrow-up-right" class="size-3.5" />
            </a>
          </div>
          <div
            :if={preview_section_label(@preview)}
            class="mb-1 truncate font-sans text-[0.7rem] leading-4 text-stone-500 dark:text-stone-400"
          >
            {preview_section_label(@preview)}
          </div>
          <div class="font-serif text-[0.84rem] leading-[1.32] text-stone-800 dark:text-stone-100">
            {Map.get(@preview, :text)}
          </div>
        </aside>
      </div>
    </div>
    """
  end

  defp preview_document_label(preview) do
    title = Map.get(preview, :document_title)

    cond do
      present?(title) -> title
      present?(Map.get(preview, :document_id)) -> "Document"
      true -> "Document"
    end
  end

  defp preview_section_label(preview) do
    title = Map.get(preview, :section_title)
    if present?(title), do: title
  end

  defp preview_year(preview) do
    case Map.get(preview, :document_year) do
      year when is_binary(year) -> blank_to_nil(year)
      year when not is_nil(year) -> year |> to_string() |> blank_to_nil()
      nil -> nil
    end
  end

  defp preview_authors(preview) do
    preview
    |> Map.get(:document_authors, [])
    |> List.wrap()
    |> Enum.filter(&present?/1)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)
end
