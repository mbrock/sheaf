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
    <div class="min-h-screen bg-[var(--sheaf-paper)]">
      <div class="mx-auto grid min-h-screen max-w-[1440px] grid-cols-1 lg:grid-cols-[320px_minmax(0,1fr)]">
        <aside class="border-b border-[var(--sheaf-line)] px-4 py-5 lg:border-r lg:border-b-0 lg:px-5 lg:py-6">
          <div class="lg:sticky lg:top-0">
            <p class="sheaf-ui text-[11px] uppercase text-[var(--sheaf-amber)]">Sheaf</p>
            <h1 class="sheaf-reading mt-2.5 text-[1.9rem] leading-[1.1] font-bold tracking-[-0.02em] text-[var(--sheaf-ink)]">
              {thesis_title(@thesis)}
            </h1>
            <p class="mt-3 max-w-[26ch] text-[13px] leading-6 text-[var(--sheaf-ink-soft)]">
              Structured, block-addressable thesis text loaded from Fuseki and rendered as a nested outline.
            </p>

            <div class="mt-5 border-t border-[var(--sheaf-line)] pt-3">
              <div class="sheaf-ui text-[10px] uppercase text-[var(--sheaf-ink-muted)]">Document</div>
              <div class="mt-1.5 text-[13px] leading-6 text-[var(--sheaf-ink-soft)]">
                <p>{document_kind(@thesis)}</p>
                <p :if={@thesis} class="sheaf-ui mt-2 text-[11px] text-[var(--sheaf-ink-muted)]">
                  {@thesis.id}
                </p>
              </div>
            </div>
          </div>
        </aside>

        <main class="min-w-0 border-t border-[var(--sheaf-line)] lg:border-t-0">
          <div class="border-b border-[var(--sheaf-line)] px-5 py-3 sm:px-7">
            <div class="flex flex-wrap items-center gap-2 text-[13px]">
              <span class="text-[var(--sheaf-ink-soft)]">{document_kind(@thesis)}</span>
              <span class="text-[var(--sheaf-ink-faint)]">›</span>
              <span class="text-[var(--sheaf-ink)]">outline</span>
            </div>
          </div>

          <div class="px-3 py-6 sm:px-7 sm:py-7">
            <div
              :if={@error}
              class="max-w-4xl border-l-2 border-rose-400 bg-rose-50 px-4 py-3 text-sm text-rose-800"
            >
              {render_error(@error)}
            </div>

            <div
              :if={is_nil(@error) and is_nil(@thesis)}
              class="max-w-4xl border border-[var(--sheaf-line)] bg-[var(--sheaf-raised)] px-5 py-5 text-sm leading-7 text-[var(--sheaf-ink-soft)]"
            >
              No thesis document is present in the named graph yet. Run
              <code class="sheaf-ui rounded bg-[var(--sheaf-paper)] px-1.5 py-0.5 text-[var(--sheaf-ink)]">
                mix sheaf.seed_sample
              </code>
              to load a minimal sample.
            </div>

            <div :if={@thesis} class="mx-auto max-w-[74ch] space-y-3">
              <.outline_children children={@thesis.children} level={0} />
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end

  attr :children, :list, required: true
  attr :level, :integer, required: true

  defp outline_children(assigns) do
    ~H"""
    <div class="space-y-2.5">
      <.outline_block :for={block <- @children} block={block} level={@level} />
    </div>
    """
  end

  attr :block, :map, required: true
  attr :level, :integer, required: true

  defp outline_block(%{block: %{type: :section}} = assigns) do
    ~H"""
    <details
      class={[
        "overflow-hidden border border-[var(--sheaf-line)] bg-[color-mix(in_oklab,var(--sheaf-raised)_55%,white)]",
        indentation_class(@level)
      ]}
      open={@level < 2}
    >
      <summary class="cursor-pointer list-none border-l-2 border-transparent px-3 py-2.5 hover:bg-[var(--sheaf-glow)]">
        <div class="grid grid-cols-[64px_minmax(0,1fr)] gap-2">
          <div class="sheaf-ui pt-1 text-right text-[10px] text-[var(--sheaf-ink-faint)]">
            {@block.id}
          </div>
          <div>
            <p class="sheaf-ui text-[10px] uppercase text-[var(--sheaf-amber)]">Section</p>
            <h2 class="sheaf-reading mt-0.5 text-[1.2rem] leading-[1.2] font-bold text-[var(--sheaf-ink)]">
              {@block.heading}
            </h2>
          </div>
        </div>
      </summary>

      <div class="border-t border-[var(--sheaf-line)] px-3 py-2.5">
        <.outline_children children={@block.children} level={@level + 1} />
      </div>
    </details>
    """
  end

  defp outline_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <div class={[
      "grid grid-cols-[64px_minmax(0,1fr)] gap-2 border-l-2 border-transparent pl-2 pr-1 py-1.5 hover:bg-[color-mix(in_oklab,var(--sheaf-glow)_60%,transparent)]",
      indentation_class(@level)
    ]}>
      <div class="sheaf-ui pr-1.5 pt-2 text-right text-[10px] text-[var(--sheaf-ink-faint)]">
        {@block.id}
      </div>
      <p class="sheaf-prose max-w-none whitespace-pre-wrap">{@block.text}</p>
    </div>
    """
  end

  defp indentation_class(0), do: nil
  defp indentation_class(1), do: "ml-3"
  defp indentation_class(2), do: "ml-6"
  defp indentation_class(_level), do: "ml-9"

  defp page_title(nil), do: "Sheaf"
  defp page_title(thesis), do: thesis_title(thesis)

  defp thesis_title(nil), do: "Sheaf"
  defp thesis_title(thesis), do: thesis.title

  defp document_kind(nil), do: "document"
  defp document_kind(thesis), do: thesis.kind |> Atom.to_string() |> String.replace("_", " ")

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason), do: inspect(reason)
end
