defmodule SheafWeb.AppChrome do
  @moduledoc """
  Shared application chrome for reader and index LiveViews.
  """

  use SheafWeb, :html

  attr :id, :string, default: "app-toolbar"
  attr :section, :atom, default: :index
  attr :breadcrumb_id, :string, default: nil
  attr :copy_markdown?, :boolean, default: false
  attr :pdf_export_path, :string, default: nil
  attr :search?, :boolean, default: true
  slot :inner_block

  def toolbar(assigns) do
    ~H"""
    <div
      id={@id}
      class="sticky top-0 z-50 col-span-full min-w-0 border-b border-stone-200/80 bg-stone-50/90 px-2 py-1 backdrop-blur sm:px-4 dark:border-stone-800/80 dark:bg-stone-950/90"
    >
      <div class="flex w-full items-center gap-2 overflow-visible sm:gap-3">
        <.link
          :if={@section == :document}
          navigate={~p"/"}
          class="grid size-8 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Back"
          aria-label="Back"
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>

        <.link
          :if={@section != :document}
          navigate={~p"/"}
          class="grid size-8 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Home"
          aria-label="Home"
        >
          <.icon name="hero-home" class="size-4" />
        </.link>

        <span
          :if={@breadcrumb_id && @inner_block == []}
          id={@breadcrumb_id}
          class="small-caps min-w-0 flex-1 truncate text-center text-lg text-stone-500 dark:text-stone-400"
        >
        </span>

        <div :if={@inner_block != []} class="min-w-0 flex-1">
          {render_slot(@inner_block)}
        </div>

        <div :if={!@breadcrumb_id && @inner_block == []} class="hidden min-w-0 flex-1 sm:block"></div>

        <.link
          :if={@search?}
          navigate={~p"/search"}
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Search"
          aria-label="Search"
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
        </.link>

        <.link
          navigate={~p"/history"}
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Assistant"
          aria-label="Assistant"
        >
          <.icon name="hero-sparkles" class="size-4" />
        </.link>

        <.link
          :if={@pdf_export_path}
          href={@pdf_export_path}
          target="_blank"
          rel="noopener noreferrer"
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Open PDF export"
          aria-label="Open PDF export"
        >
          <.icon name="hero-document-arrow-down" class="size-4" />
        </.link>

        <button
          :if={@copy_markdown?}
          id="copy-markdown"
          type="button"
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
          title="Copy markdown"
          aria-label="Copy markdown"
        >
          <.icon name="hero-clipboard-document" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  slot :inner_block
  attr :assistant_id, :string, default: "app-assistant"
  attr :graph, :any, default: nil
  attr :root, :any, default: nil
  attr :selected_id, :string, default: nil
  attr :class, :string, required: true

  def right_sidebar(assigns) do
    ~H"""
    <aside class={[
      "min-h-0 min-w-0 overflow-x-hidden overflow-y-auto border-stone-200/80 px-5 py-4 dark:border-stone-800/80",
      @class
    ]}>
      <.live_component
        module={SheafWeb.AssistantChatComponent}
        id={@assistant_id}
        graph={@graph}
        root={@root}
        selected_id={@selected_id}
      />
      {render_slot(@inner_block)}
    </aside>
    """
  end
end
