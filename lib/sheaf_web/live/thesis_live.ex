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
    <div class="mx-auto flex min-h-screen w-full max-w-5xl flex-col px-4 py-8 sm:px-6 lg:px-8">
      <header class="border-b border-stone-200 pb-6">
        <p class="text-xs font-semibold uppercase tracking-[0.24em] text-stone-500">Sheaf</p>
        <h1 class="mt-3 text-3xl font-semibold tracking-tight text-stone-950 sm:text-4xl">
          {thesis_title(@thesis)}
        </h1>
        <p class="mt-2 text-sm text-stone-600">
          Structured thesis blocks loaded from Fuseki.
        </p>
      </header>

      <main class="flex-1 py-8">
        <div :if={@error} class="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-700">
          {render_error(@error)}
        </div>

        <div :if={is_nil(@error) and is_nil(@thesis)} class="rounded-xl border border-stone-200 bg-white px-4 py-5 text-sm text-stone-600">
          No thesis document is present in the named graph yet. Run <code class="rounded bg-stone-100 px-1 py-0.5 text-stone-950">mix sheaf.seed_sample</code> to load a minimal sample.
        </div>

        <div :if={@thesis} class="space-y-4">
          <.outline_children children={@thesis.children} level={0} />
        </div>
      </main>
    </div>
    """
  end

  attr :children, :list, required: true
  attr :level, :integer, required: true

  defp outline_children(assigns) do
    ~H"""
    <div class="space-y-4">
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
        "overflow-hidden rounded-2xl border border-stone-200 bg-white shadow-sm",
        indentation_class(@level)
      ]}
      open={@level < 2}
    >
      <summary class="cursor-pointer px-4 py-3">
        <p class="text-[0.65rem] font-semibold uppercase tracking-[0.22em] text-stone-500">
          Section
        </p>
        <h2 class="mt-1 inline text-lg font-medium text-stone-950">
          {@block.heading}
        </h2>
      </summary>

      <div class="border-t border-stone-200 px-4 py-4">
        <.outline_children children={@block.children} level={@level + 1} />
      </div>
    </details>
    """
  end

  defp outline_block(%{block: %{type: :paragraph}} = assigns) do
    ~H"""
    <div class={["border-l border-stone-200 pl-4 text-base leading-7 text-stone-700", indentation_class(@level)]}>
      <p class="max-w-none whitespace-pre-wrap">{@block.text}</p>
    </div>
    """
  end

  defp indentation_class(0), do: nil
  defp indentation_class(1), do: "ml-4"
  defp indentation_class(2), do: "ml-8"
  defp indentation_class(_level), do: "ml-12"

  defp page_title(nil), do: "Sheaf"
  defp page_title(thesis), do: thesis_title(thesis)

  defp thesis_title(nil), do: "Sheaf"
  defp thesis_title(thesis), do: thesis.title

  defp render_error(reason) when is_binary(reason), do: reason
  defp render_error(reason), do: inspect(reason)
end
