defmodule SheafWeb.AssistantActivityComponents do
  @moduledoc """
  Compact assistant activity primitives for tool calls and their artifacts.
  """

  use SheafWeb, :html

  attr :label, :string, default: nil
  attr :title, :string, default: "Tool activity"
  attr :meta, :list, default: []
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def activity_stack(assigns) do
    ~H"""
    <ol
      class={[
        "border-l-6 text-xs border-orange-200 bg-white px-3 py-2 dark:border-stone-800 dark:bg-stone-900",
        @class
      ]}
      aria-label={@label}
    >
      {render_slot(@inner_block)}
    </ol>
    """
  end

  attr :icon, :string, default: "hero-wrench-screwdriver"
  attr :tone, :atom, default: :default
  attr :title, :string, required: true
  attr :summary, :string, default: nil
  attr :status, :string, default: nil
  attr :meta, :list, default: []
  attr :class, :any, default: nil

  def activity_row(assigns) do
    assigns = assign(assigns, :classes, activity_row_classes(assigns.tone))

    ~H"""
    <li class={[
      "flex min-w-0",
      @classes.row,
      @class
    ]}>
      <.icon
        name={@icon}
        class={["mt-0.5 mr-2 size-3.5 shrink-0", @classes.icon]}
      />
      <span class="min-w-0 flex-1">
        <span class="flex min-w-0 items-baseline gap-2">
          <span class={["min-w-0 flex-1 truncate", @classes.title]}>
            {@title}
          </span>
          <span
            :if={present?(@status)}
            class={["shrink-0 uppercase", @classes.badge]}
          >
            {@status}
          </span>
        </span>
        <span
          :if={present?(@summary)}
          class={["hidden break-words", @classes.summary]}
        >
          {@summary}
        </span>
        <span :if={@meta != []} class="flex min-w-0 gap-2 pl-2 overflow-hidden">
          <span :for={item <- @meta} class={["shrink-0", @classes.meta]}>
            {item}
          </span>
        </span>
      </span>
    </li>
    """
  end

  attr :icon, :string, default: "hero-wrench-screwdriver"
  attr :tone, :atom, default: :default
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :status, :string, default: nil
  attr :meta, :list, default: []
  attr :open, :boolean, default: false
  attr :class, :any, default: nil
  slot :inner_block

  def activity_preview(assigns) do
    assigns =
      assigns
      |> assign(:classes, activity_preview_classes(assigns.tone))
      |> assign(:body?, assigns.inner_block != [])

    ~H"""
    <li class={[
      "overflow-hidden text-left",
      @classes.frame,
      @class
    ]}>
      <details :if={@body?} open={@open} class="group">
        <summary class={[
          "relative flex min-w-0 cursor-pointer list-none items-start gap-2 [&::-webkit-details-marker]:hidden",
          @classes.header
        ]}>
          <.icon name={@icon} class={["mt-0.5 size-3.5 shrink-0", @classes.icon]} />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-stone-900 dark:text-stone-50">
              {@title}
            </span>
            <span
              :if={present?(@subtitle)}
              class="truncate text-stone-500 dark:text-stone-400"
            >
              {@subtitle}
            </span>
            <span
              :if={@meta != []}
              class="flex min-w-0 gap-2 pl-2 overflow-hidden text-stone-500 dark:text-stone-400"
            >
              <span :for={item <- @meta} class="shrink-0">
                {item}
              </span>
            </span>
          </span>
          <span
            :if={present?(@status)}
            class={["shrink-0 uppercase", @classes.badge]}
          >
            {@status}
          </span>
        </summary>
        <div class="min-w-0 border-t border-stone-200 px-2 py-1 dark:border-stone-800">
          {render_slot(@inner_block)}
        </div>
      </details>

      <header
        :if={!@body?}
        class={[
          "relative flex min-w-0 items-start gap-2 px-2 py-1",
          @classes.header
        ]}
      >
        <.icon name={@icon} class={["mt-0.5 size-3.5 shrink-0", @classes.icon]} />
        <div class="min-w-0 flex-1">
          <div class="truncate text-stone-900 dark:text-stone-50">
            {@title}
          </div>
          <div
            :if={present?(@subtitle)}
            class="truncate text-stone-500 dark:text-stone-400"
          >
            {@subtitle}
          </div>
          <div
            :if={@meta != []}
            class="flex min-w-0 gap-2 overflow-hidden text-stone-500 dark:text-stone-400"
          >
            <span :for={item <- @meta} class="shrink-0">
              {item}
            </span>
          </div>
        </div>
        <span
          :if={present?(@status)}
          class={["shrink-0 uppercase", @classes.badge]}
        >
          {@status}
        </span>
      </header>
    </li>
    """
  end

  attr :icon, :string, default: "hero-wrench-screwdriver"
  attr :tone, :atom, default: :default
  attr :title, :string, required: true
  attr :detail, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def activity_panel(assigns) do
    assigns = assign(assigns, :classes, activity_panel_classes(assigns.tone))

    ~H"""
    <article class={[
      "border-l-2 px-3 text-stone-900 dark:text-stone-100",
      @classes.panel,
      @class
    ]}>
      <div class="min-w-0 flex-1">
        <div class="flex min-w-0 items-baseline gap-2">
          <.icon name={@icon} class={["size-3.5 shrink-0", @classes.icon]} />
          <span class={[@classes.title]}>
            {@title}
          </span>
          <span
            :if={present?(@detail)}
            class="min-w-0 truncate text-stone-500 dark:text-stone-400"
          >
            {@detail}
          </span>
        </div>
      </div>
      {render_slot(@inner_block)}
    </article>
    """
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp activity_row_classes(:pending) do
    %{
      row: "border-amber-300 dark:border-amber-800",
      icon: "text-amber-600 dark:text-amber-300",
      title: "text-stone-700 dark:text-stone-200",
      summary: "text-stone-500 dark:text-stone-400",
      badge: "text-amber-700 dark:text-amber-300",
      meta: "text-stone-500 dark:text-stone-400"
    }
  end

  defp activity_row_classes(:danger) do
    %{
      row: "border-red-300 dark:border-red-900",
      icon: "text-red-700 dark:text-red-300",
      title: "text-red-700 dark:text-red-300",
      summary: "text-red-700 dark:text-red-300",
      badge: "text-red-700 dark:text-red-300",
      meta: "text-red-700 dark:text-red-300"
    }
  end

  defp activity_row_classes(_tone) do
    %{
      row: "border-stone-200 dark:border-stone-800",
      icon: "text-stone-500 dark:text-stone-400",
      title: "text-stone-700 dark:text-stone-200",
      summary: "text-stone-500 dark:text-stone-400",
      badge: "text-stone-500 dark:text-stone-400",
      meta: "text-stone-500 dark:text-stone-400"
    }
  end

  defp activity_preview_classes(:pending) do
    %{
      frame: "border-amber-300 dark:border-amber-800",
      header:
        "border-amber-200 bg-amber-50/60 dark:border-amber-900 dark:bg-amber-950/20",
      icon: "text-amber-600 dark:text-amber-300",
      badge: "text-amber-700 dark:text-amber-300"
    }
  end

  defp activity_preview_classes(:danger) do
    %{
      frame: "border-red-300 dark:border-red-900",
      header:
        "border-red-200 bg-red-50/60 dark:border-red-900 dark:bg-red-950/20",
      icon: "text-red-700 dark:text-red-300",
      badge: "text-red-700 dark:text-red-300"
    }
  end

  defp activity_preview_classes(_tone) do
    %{
      frame: "",
      header: "dark:bg-stone-950/40",
      icon: "text-stone-500 dark:text-stone-400",
      badge: "text-stone-500 dark:text-stone-400"
    }
  end

  defp activity_panel_classes(:note) do
    %{
      panel:
        "border-emerald-500 bg-emerald-50/50 dark:border-emerald-700 dark:bg-emerald-950/20",
      icon: "text-emerald-700 dark:text-emerald-300",
      title: "text-emerald-800 dark:text-emerald-200"
    }
  end

  defp activity_panel_classes(_tone) do
    %{
      panel: "border-stone-300 dark:border-stone-700 dark:bg-stone-900/60",
      icon: "text-stone-500 dark:text-stone-400",
      title: "text-stone-800 dark:text-stone-100"
    }
  end
end
