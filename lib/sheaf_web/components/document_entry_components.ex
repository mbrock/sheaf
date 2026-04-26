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

  def document_row(assigns) do
    ~H"""
    <div class={["leading-snug", if(@nested, do: "px-2 py-1.5", else: "px-2 py-1")]}>
      <div class="flex min-w-0 items-baseline gap-2 font-sans">
        <input
          :if={@show_checkbox && excludable?(@document)}
          type="checkbox"
          checked={!@document.excluded?}
          phx-click="toggle_document_exclusion"
          phx-value-id={@document.id}
          phx-value-included={if(@document.excluded?, do: "true", else: "false")}
          aria-label={
            if(@document.excluded?, do: "Include in workspace", else: "Exclude from workspace")
          }
          title={if(@document.excluded?, do: "Include in workspace", else: "Exclude from workspace")}
          class="inline-block size-3.5 shrink-0 rounded-sm border border-stone-400 bg-stone-100 text-stone-600 accent-stone-500 focus:ring-1 focus:ring-stone-400 dark:border-stone-500 dark:bg-stone-800 dark:text-stone-300 dark:accent-stone-400"
        />
        <.link
          :if={@document.path}
          navigate={@document.path}
          class="min-w-0 flex-1 truncate transition-colors"
        >
          {@document.title}
        </.link>
        <span
          :if={is_nil(@document.path)}
          class={[
            "min-w-0 flex-1 truncate",
            !has_document?(@document) && "text-stone-600 dark:text-stone-300"
          ]}
        >
          {@document.title}
        </span>
        <span
          :if={!has_document?(@document)}
          class="shrink-0 rounded-sm border border-stone-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-stone-500 dark:border-stone-700 dark:text-stone-400"
        >
          metadata only
        </span>
        <span
          :if={@document.cited? && !@nested}
          class="shrink-0 rounded-sm border border-amber-300 px-1.5 py-0.5 font-sans text-[0.6875rem] uppercase tracking-wide text-amber-800 dark:border-amber-700 dark:text-amber-200"
        >
          cited
        </span>
      </div>

      <div
        :if={subline?(@document)}
        class="flex min-w-0 items-baseline gap-3 text-[0.9375rem] text-stone-500 dark:text-stone-400"
      >
        <span :if={year_str(@document) != ""} class="shrink-0 tabular-nums">
          {year_str(@document)}
        </span>

        <span class="small-caps min-w-0 flex-1 truncate text-stone-600 dark:text-stone-300">
          {authors_str(@document) || ""}
        </span>

        <span class="shrink-0 tabular-nums">{page_count_str(@document)}</span>
      </div>

      <div
        :if={chapter_metadata?(@document)}
        class="flex min-w-0 items-baseline gap-2 truncate font-sans text-xs text-stone-500 dark:text-stone-400"
      >
        <span class="min-w-0 truncate italic">{chapter_venue(@document)}</span>
        <span :if={publisher_str(@document)} class="shrink-0">{publisher_str(@document)}</span>
        <span :if={pages_str(@document)} class="shrink-0">{pages_str(@document)}</span>
      </div>
    </div>
    """
  end

  defp excludable?(%{kind: :thesis}), do: false
  defp excludable?(document), do: has_document?(document)

  defp has_document?(document), do: Map.get(document, :has_document?, true)

  defp subline?(document) do
    authors_str(document) != nil or year_str(document) != "" or page_count_str(document) != ""
  end

  defp authors_str(document) do
    case document |> Map.get(:metadata, %{}) |> Map.get(:authors, []) do
      [] -> nil
      authors -> Enum.join(authors, ", ")
    end
  end

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
