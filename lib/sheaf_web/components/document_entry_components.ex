defmodule SheafWeb.DocumentEntryComponents do
  @moduledoc """
  Shared document and bibliographic work rows.
  """

  use SheafWeb, :html

  attr :document, :map, required: true
  attr :show_checkbox, :boolean, default: false
  attr :nested, :boolean, default: false

  def document_entry(assigns) do
    ~H"""
    <div class={[
      @document.excluded? && "opacity-45 grayscale",
      @document.cited? &&
        "rounded-sm border-l-2 border-amber-500 bg-amber-50/70 dark:border-amber-300 dark:bg-amber-950/25",
      workspace_owner_authored?(@document) &&
        "rounded-sm border-l-2 border-sky-500 bg-sky-50/70 dark:border-sky-300 dark:bg-sky-950/25",
      @nested &&
        "border-l border-stone-200 bg-stone-100/60 pl-2 dark:border-stone-700 dark:bg-stone-900/50"
    ]}>
      <.document_row document={@document} show_checkbox={@show_checkbox} nested={@nested} />
    </div>
    """
  end

  attr :document, :map, required: true
  attr :show_checkbox, :boolean, default: false
  attr :nested, :boolean, default: false
  attr :link_title, :boolean, default: true

  def document_row(assigns) do
    ~H"""
    <div class={["leading-snug", if(@nested, do: "px-2 py-1.5", else: "px-2 py-1")]}>
      <.document_title_line
        document={@document}
        show_checkbox={@show_checkbox}
        nested={@nested}
        link_title={@link_title}
      />
      <.document_metadata_lines document={@document} />
    </div>
    """
  end

  attr :document, :map, required: true
  attr :show_checkbox, :boolean, default: false
  attr :nested, :boolean, default: false
  attr :link_title, :boolean, default: true
  attr :class, :string, default: "flex min-w-0 items-baseline gap-2 font-sans"
  attr :title_class, :string, default: "min-w-0 flex-1 truncate"
  attr :show_status_pills, :boolean, default: true

  def document_title_line(assigns) do
    ~H"""
    <div class={@class}>
      <input
        :if={@show_checkbox && checkbox_visible?(@document)}
        type="checkbox"
        checked={checkbox_checked?(@document)}
        disabled={!excludable?(@document)}
        phx-click="toggle_document_exclusion"
        phx-value-id={@document.id}
        phx-value-included={if(@document.excluded?, do: "true", else: "false")}
        aria-label={checkbox_label(@document)}
        title={checkbox_label(@document)}
        class="inline-block size-3.5 shrink-0 rounded-sm border border-stone-400 bg-stone-100 text-stone-600 accent-stone-500 focus:ring-1 focus:ring-stone-400 dark:border-stone-500 dark:bg-stone-800 dark:text-stone-300 dark:accent-stone-400"
      />
      <.link
        :if={@link_title && @document.path}
        navigate={@document.path}
        class={[@title_class, "transition-colors"]}
      >
        {@document.title}
      </.link>
      <span
        :if={!@link_title || is_nil(@document.path)}
        class={[
          @title_class,
          !has_document?(@document) && "text-stone-600 dark:text-stone-300"
        ]}
      >
        {@document.title}
      </span>
      <span
        :if={@show_status_pills && !has_document?(@document)}
        class="shrink-0 rounded-sm border border-stone-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-stone-500 dark:border-stone-700 dark:text-stone-400"
      >
        metadata only
      </span>
      <span
        :if={@show_status_pills && @document.cited? && !@nested}
        class="shrink-0 rounded-sm border border-amber-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-amber-800 dark:border-amber-700 dark:text-amber-200"
      >
        cited
      </span>
      <span
        :if={@show_status_pills && status_str(@document) == "draft"}
        class="shrink-0 rounded-sm border border-sky-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-sky-800 dark:border-sky-700 dark:text-sky-200"
      >
        draft
      </span>
      <span
        :if={@show_status_pills && status_str(@document) == "mikael"}
        class="shrink-0 rounded-sm border border-emerald-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-emerald-800 dark:border-emerald-900/70 dark:text-emerald-300"
      >
        MIKAEL
      </span>
    </div>
    """
  end

  attr :document, :map, required: true
  attr :show_publisher, :boolean, default: true

  attr :subline_class, :string,
    default:
      "flex min-w-0 items-baseline gap-3 text-[0.9375rem] text-stone-500 dark:text-stone-400"

  attr :detail_class, :string,
    default:
      "flex min-w-0 items-baseline gap-2 truncate font-sans text-xs text-stone-500 dark:text-stone-400"

  attr :numeric_class, :string, default: "shrink-0 tabular-nums"

  def document_metadata_lines(assigns) do
    ~H"""
    <div :if={subline?(@document)} class={@subline_class}>
      <span :if={year_str(@document) != ""} class={@numeric_class}>
        {year_str(@document)}
      </span>

      <span class="small-caps min-w-0 flex-1 truncate text-stone-600 dark:text-stone-300">
        <span class="sm:hidden">
          {compact_authors_str(@document) || authors_str(@document) || ""}
        </span>
        <span class="hidden sm:inline">{authors_str(@document) || ""}</span>
      </span>

      <span class={@numeric_class}>{page_count_str(@document)}</span>
    </div>

    <div :if={chapter_metadata?(@document)} class={@detail_class}>
      <span class="min-w-0 truncate italic">{chapter_venue(@document)}</span>
      <span :if={@show_publisher && publisher_str(@document)} class="shrink-0">
        {publisher_str(@document)}
      </span>
      <span :if={pages_str(@document)} class="shrink-0">{pages_str(@document)}</span>
    </div>
    """
  end

  attr :document, :map, required: true
  attr :path, :string, default: nil
  attr :open_new?, :boolean, default: false
  attr :show_open?, :boolean, default: true

  def document_metadata_heading(assigns) do
    assigns =
      assign_new(assigns, :path, fn -> Map.get(assigns.document, :path) end)

    ~H"""
    <div class="min-w-0 font-sans text-[0.82rem] leading-4">
      <div class="min-w-0 text-stone-900 dark:text-stone-50">
        <span>{@document.title}</span>
        <span
          :if={metadata_only?(@document)}
          class="ml-1 inline-flex translate-y-[-0.08em] items-center rounded-sm border border-stone-300 px-1 py-0 font-sans text-[0.58rem] uppercase leading-3 tracking-wide text-stone-500 dark:border-stone-700 dark:text-stone-400"
        >
          metadata
        </span>
        <span
          :if={cited?(@document)}
          class="ml-1 inline-flex translate-y-[-0.08em] items-center rounded-sm border border-amber-300 px-1 py-0 font-sans text-[0.58rem] uppercase leading-3 tracking-wide text-amber-800 dark:border-amber-700 dark:text-amber-200"
        >
          cited
        </span>
        <span
          :if={status_str(@document) == "draft"}
          class="ml-1 inline-flex translate-y-[-0.08em] items-center rounded-sm border border-sky-300 px-1 py-0 font-sans text-[0.58rem] uppercase leading-3 tracking-wide text-sky-800 dark:border-sky-700 dark:text-sky-200"
        >
          draft
        </span>
        <span
          :if={status_str(@document) == "mikael"}
          class="ml-1 inline-flex translate-y-[-0.08em] items-center rounded-sm border border-emerald-300 px-1 py-0 font-sans text-[0.58rem] uppercase leading-3 tracking-wide text-emerald-800 dark:border-emerald-900/70 dark:text-emerald-300"
        >
          MIKAEL
        </span>
        <a
          :if={@show_open? && @path}
          href={@path}
          target={if @open_new?, do: "_blank"}
          rel={if @open_new?, do: "noopener noreferrer"}
          class="ml-1 inline-block text-stone-500 transition-colors hover:text-stone-900 dark:text-stone-400 dark:hover:text-stone-100"
          title="Open page"
          aria-label="Open page"
        >
          <.icon name="hero-arrow-top-right-on-square-mini" class="size-[0.9em] align-[-0.08em]" />
        </a>
      </div>
      <.document_metadata_lines
        document={@document}
        subline_class="flex min-w-0 items-baseline gap-2 text-[0.9rem] text-stone-500 dark:text-stone-400"
        detail_class="flex min-w-0 items-baseline gap-2 truncate font-sans text-stone-500 dark:text-stone-400"
        numeric_class="small-caps shrink-0 tabular-nums"
        show_publisher={false}
      />
    </div>
    """
  end

  defp checkbox_visible?(document), do: excludable?(document) or !has_document?(document)

  defp checkbox_checked?(document), do: excludable?(document) and !document.excluded?

  defp checkbox_label(document) do
    cond do
      !has_document?(document) -> "Metadata-only entry cannot be excluded from workspace"
      document.excluded? -> "Include in workspace"
      true -> "Exclude from workspace"
    end
  end

  defp excludable?(%{kind: :thesis}), do: false
  defp excludable?(document), do: has_document?(document)

  defp has_document?(document), do: Map.get(document, :has_document?, true)

  defp metadata_only?(document), do: !has_document?(document)

  defp cited?(document), do: Map.get(document, :cited?, false)

  defp workspace_owner_authored?(document),
    do: Map.get(document, :workspace_owner_authored?, false)

  defp subline?(document) do
    authors_str(document) != nil or year_str(document) != "" or page_count_str(document) != ""
  end

  defp authors_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:authors, []) do
      [] -> nil
      authors -> Enum.join(authors, ", ")
    end
  end

  defp compact_authors_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:authors, []) do
      [] -> nil
      authors -> authors |> Enum.map(&surname/1) |> Enum.join(", ")
    end
  end

  defp surname(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> List.last()
    |> Kernel.||(name)
  end

  defp surname(name), do: to_string(name)

  defp year_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:year) do
      nil -> ""
      year -> to_string(year)
    end
  end

  defp page_count_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:page_count) do
      nil -> ""
      count -> "#{count} pp."
    end
  end

  defp status_str(document), do: document |> Map.get(:metadata, %{}) |> Map.get(:status)

  defp chapter_metadata?(document), do: chapter_venue(document) != nil

  defp chapter_venue(%{metadata: %{kind: "Book chapter", venue: venue}})
       when is_binary(venue) and venue != "",
       do: venue

  defp chapter_venue(_document), do: nil

  defp publisher_str(document), do: document |> Map.get(:metadata, %{}) |> Map.get(:publisher)

  defp pages_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:pages) do
      nil -> nil
      "" -> nil
      pages -> "pp. #{pages}"
    end
  end
end
