defmodule SheafWeb.ThesisLive do
  use SheafWeb, :live_view

  alias Sheaf.Thesis

  @impl true
  def mount(_params, _session, socket) do
    socket =
      case Thesis.fetch_outline() do
        {:ok, thesis} ->
          socket
          |> assign(:page_title, page_title(thesis))
          |> assign(:thesis, thesis)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:page_title, "Sheaf")
          |> assign(:thesis, nil)
          |> assign(:error, reason)
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-[var(--sheaf-paper)] lg:h-screen">
      <div class="mx-auto grid min-h-screen max-w-[1600px] grid-cols-1 lg:h-screen lg:grid-cols-[320px_minmax(0,1fr)]">
        <aside class="border-b border-[var(--sheaf-line)] lg:flex lg:min-h-0 lg:flex-col lg:border-r lg:border-b-0">
          <div class="border-b border-[var(--sheaf-line)] px-5 py-5">
            <div class="text-[15px] font-semibold text-[var(--sheaf-ink)]">Sheaf</div>
            <div class="mt-3 text-[13px] leading-6 text-[var(--sheaf-ink-soft)] text-balance">
              {thesis_title(@thesis)}
            </div>
            <div class="mt-2 text-xs text-[var(--sheaf-ink-muted)]">
              {document_kind(@thesis)}
            </div>
          </div>

          <div :if={@thesis} class="px-5 pt-3">
            <div class="sheaf-ui text-[10px] uppercase text-[var(--sheaf-ink-muted)]">Contents</div>
          </div>

          <.toc :if={@thesis} entries={toc_entries(@thesis)} />
        </aside>

        <main class="min-w-0 lg:flex lg:min-h-0 lg:flex-col">
          <div class="border-b border-[var(--sheaf-line)] px-5 py-3 sm:px-7">
            <div class="flex flex-wrap items-center gap-2 text-[13px]">
              <span class="text-[var(--sheaf-ink-soft)]">{document_kind(@thesis)}</span>
              <span class="text-[var(--sheaf-ink-faint)]">›</span>
              <span class="text-[var(--sheaf-ink)]">full text</span>
            </div>
          </div>

          <div class="px-4 pb-16 pt-8 sm:px-7 lg:flex-1 lg:overflow-y-auto lg:px-8 lg:pt-10">
            <div
              :if={@error}
              class="mx-auto max-w-[72ch] border-l-2 border-rose-400 bg-rose-50 px-4 py-3 text-sm text-rose-800"
            >
              {render_error(@error)}
            </div>

            <div
              :if={is_nil(@error) and is_nil(@thesis)}
              class="mx-auto max-w-[72ch] border border-[var(--sheaf-line)] bg-[var(--sheaf-raised)] px-5 py-5 text-sm leading-7 text-[var(--sheaf-ink-soft)]"
            >
              No thesis document is present in the named graph yet. Run
              <code class="sheaf-ui rounded bg-[var(--sheaf-paper)] px-1.5 py-0.5 text-[var(--sheaf-ink)]">
                mix sheaf.seed_sample
              </code>
              to load a minimal sample.
            </div>

            <article :if={@thesis} class="mx-auto max-w-[72ch]">
              <header
                id="document-start"
                class="mb-8 scroll-mt-20 border-b border-[var(--sheaf-line)] pb-4"
              >
                <div class="text-[13px] text-[var(--sheaf-ink-soft)]">{document_kind(@thesis)}</div>
                <h1 class="sheaf-reading mt-3 text-[2.35rem] leading-[1.06] font-bold tracking-[-0.02em] text-[var(--sheaf-ink)]">
                  {thesis_title(@thesis)}
                </h1>
              </header>

              <.reader_children children={@thesis.children} level={0} />
            </article>
          </div>
        </main>
      </div>
    </div>
    """
  end

  attr :entries, :list, required: true

  defp toc(assigns) do
    ~H"""
    <nav class="pb-5 pt-2 text-[13px] text-[var(--sheaf-ink-soft)] lg:flex-1 lg:overflow-y-auto">
      <a
        href="#document-start"
        class="flex items-baseline gap-2 border-l-2 border-transparent pl-4 pr-3.5 py-1 text-left hover:bg-[var(--sheaf-glow)] hover:text-[var(--sheaf-ink)]"
      >
        <span class="sheaf-ui w-2.5 flex-none text-[10px] text-[var(--sheaf-line-strong)]">§</span>
        <span class="flex-1 text-balance text-[var(--sheaf-ink)]">Document</span>
      </a>

      <a
        :for={entry <- @entries}
        href={"#block-#{entry.id}"}
        class={[
          "flex items-baseline gap-2 border-l-2 border-transparent pr-3.5 py-1 text-left hover:bg-[var(--sheaf-glow)] hover:text-[var(--sheaf-ink)]",
          toc_padding_class(entry.level)
        ]}
      >
        <span class={[
          "sheaf-ui w-2.5 flex-none text-[10px]",
          if(entry.level == 0,
            do: "text-[var(--sheaf-line-strong)]",
            else: "text-[var(--sheaf-ink-faint)]"
          )
        ]}>
          {toc_marker(entry.level)}
        </span>
        <span class={[
          "min-w-0 flex-1 text-balance leading-5",
          if(entry.level == 0,
            do: "text-[var(--sheaf-ink)]",
            else: "text-[var(--sheaf-ink-soft)]"
          )
        ]}>
          {entry.heading}
        </span>
      </a>
    </nav>
    """
  end

  attr :children, :list, required: true
  attr :level, :integer, required: true

  defp reader_children(assigns) do
    ~H"""
    <div class={[reader_stack_class(@level), reader_indent_class(@level)]}>
      <.reader_block :for={block <- @children} block={block} level={@level} />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :level, :integer, required: true

  defp reader_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details id={"block-#{@block.id}"} class="scroll-mt-20" open={section_open?(@level)}>
      <summary class="cursor-pointer py-1.5 text-[var(--sheaf-ink)] hover:text-[var(--sheaf-ink)]">
        <div class="grid grid-cols-[64px_minmax(0,1fr)] gap-2">
          <div class="sheaf-ui pr-1.5 pt-2.5 text-right text-[10px] tracking-[0.08em] text-[var(--sheaf-ink-faint)] select-none">
            {@block.id}
          </div>

          <div class={section_heading_container_class(@level)}>
            <h2 class={section_heading_class(@level)}>
              {@block.heading}
            </h2>
          </div>
        </div>
      </summary>

      <div class="mt-2">
        <.reader_children children={@block.children} level={@level + 1} />
      </div>
    </details>
    """
  end

  defp reader_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <div
      id={"block-#{@block.id}"}
      class="scroll-mt-20 grid grid-cols-[64px_minmax(0,1fr)] gap-2 py-1.5 -ml-2.5 pl-2 border-l-2 border-transparent hover:bg-[color-mix(in_oklab,var(--sheaf-glow)_60%,transparent)]"
    >
      <div class="sheaf-ui pr-1.5 pt-2.5 text-right text-[10px] tracking-[0.08em] text-[var(--sheaf-ink-faint)] select-none">
        {@block.id}
      </div>
      <p class="sheaf-prose whitespace-pre-wrap">{@block.text}</p>
    </div>
    """
  end

  defp toc_entries(nil), do: []
  defp toc_entries(thesis), do: collect_toc_entries(thesis.children, 0)

  defp collect_toc_entries(blocks, level) do
    Enum.flat_map(blocks, fn
      %{type: :section} = block ->
        [
          %{id: block.id, heading: block.heading, level: level}
          | collect_toc_entries(block.children, level + 1)
        ]

      _block ->
        []
    end)
  end

  defp reader_stack_class(0), do: "space-y-10"
  defp reader_stack_class(1), do: "space-y-6"
  defp reader_stack_class(_level), do: "space-y-4"

  defp reader_indent_class(0), do: nil
  defp reader_indent_class(1), do: "ml-3"
  defp reader_indent_class(2), do: "ml-6"
  defp reader_indent_class(_level), do: "ml-9"

  defp section_heading_container_class(0), do: "border-b border-[var(--sheaf-line)] pb-3.5"
  defp section_heading_container_class(1), do: "pb-1"
  defp section_heading_container_class(_level), do: "pb-0.5"

  defp section_open?(level), do: level < 2

  defp section_heading_class(0) do
    "sheaf-reading text-[2rem] leading-[1.12] font-bold tracking-[-0.02em] text-[var(--sheaf-ink)]"
  end

  defp section_heading_class(1) do
    "sheaf-reading text-[1.45rem] leading-[1.18] font-bold tracking-[-0.015em] text-[var(--sheaf-ink)]"
  end

  defp section_heading_class(_level) do
    "sheaf-reading text-[1.2rem] leading-[1.25] font-bold text-[var(--sheaf-ink)]"
  end

  defp toc_padding_class(0), do: "pl-4"
  defp toc_padding_class(1), do: "pl-[1.875rem]"
  defp toc_padding_class(2), do: "pl-[3rem]"
  defp toc_padding_class(_level), do: "pl-[4.125rem]"

  defp toc_marker(0), do: "◆"
  defp toc_marker(_level), do: "·"

  defp page_title(nil), do: "Sheaf"
  defp page_title(thesis), do: thesis_title(thesis)

  defp thesis_title(nil), do: "Sheaf"
  defp thesis_title(thesis), do: thesis.title

  defp document_kind(nil), do: "document"
  defp document_kind(thesis), do: thesis.kind |> Atom.to_string() |> String.replace("_", " ")

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason), do: inspect(reason)
end
