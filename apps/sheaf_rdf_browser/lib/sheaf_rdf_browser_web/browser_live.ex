defmodule SheafRDFBrowserWeb.BrowserLive do
  @moduledoc """
  Generic ontology-first RDF dataset browser prototype.
  """

  use Phoenix.LiveView

  alias SheafRDFBrowser.{Index, Snapshot}

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Snapshot.get()

    {:ok,
     socket
     |> assign(:page_title, "RDF Browser")
     |> assign_snapshot(snapshot)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    snapshot = Snapshot.refresh()
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  defp assign_snapshot(socket, snapshot) do
    index = snapshot.index

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:class_tree, Index.class_tree(index))
    |> assign(:property_rows, Index.property_rows(index, 120))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-950 text-slate-100">
      <div class="mx-auto flex w-full max-w-7xl flex-col gap-4 px-4 py-5">
        <header class="flex justify-end">
          <button
            type="button"
            phx-click="refresh"
            class="w-fit border border-cyan-700/50 bg-cyan-900/30 px-3 py-1 text-sm text-cyan-100 hover:bg-cyan-800/50"
          >
            refresh snapshot
          </button>
        </header>

        <%= if @snapshot.error do %>
          <pre class="overflow-auto border border-red-700/60 bg-red-950/40 p-3 text-sm text-red-100"><%= @snapshot.error %></pre>
        <% end %>

        <section class="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
          <div class="flex min-w-0 flex-col gap-2">
            <h2 class="text-lg text-slate-100">Classes</h2>
            <div class="flex flex-col">
              <%= for class <- @class_tree do %>
                <.class_node node={class} depth={0} />
              <% end %>
            </div>
          </div>

          <div class="flex min-w-0 flex-col gap-2">
            <h2 class="text-lg text-slate-100">Properties</h2>
            <div class="flex flex-col">
              <%= for property <- @property_rows do %>
                <.term_row term={property} kind="property" />
              <% end %>
            </div>
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :term, :map, required: true
  attr :kind, :string, required: true

  defp term_row(assigns) do
    ~H"""
    <details class="py-2">
      <summary class="flex cursor-pointer items-start justify-between gap-3 hover:text-white">
        <span class="min-w-0">
          <.term_label term={@term} />
          <span
            :if={@term.comment}
            class="mt-1 block whitespace-normal break-words font-serif text-sm leading-snug text-slate-300"
          >
            {@term.comment}
          </span>
        </span>
        <span class="shrink-0 pt-0.5 font-mono text-xs text-slate-500">
          {@term.count}
        </span>
      </summary>
      <dl class="ml-4 mt-2 flex flex-col gap-2 text-sm">
        <.detail label="IRI" value={@term.id} />
        <.detail
          :if={Map.get(@term, :parents, []) != []}
          label="parents"
          value={Enum.join(@term.parents, "\n")}
        />
        <.detail
          :if={@kind == "property" and Map.get(@term, :domains, []) != []}
          label="domain"
          value={Enum.join(@term.domains, ", ")}
        />
        <.detail
          :if={@kind == "property" and Map.get(@term, :ranges, []) != []}
          label="range"
          value={Enum.join(@term.ranges, ", ")}
        />
      </dl>
    </details>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, required: true

  defp class_node(assigns) do
    assigns = assign(assigns, :indent, "#{assigns.depth * 1.1}rem")

    ~H"""
    <div class="min-w-0">
      <div style={"margin-left: #{@indent}"}>
        <details class="py-2">
          <summary class="flex cursor-pointer items-start justify-between gap-3 hover:text-white">
            <span class="min-w-0">
              <.term_label term={@node} />
              <span
                :if={@node.comment}
                class="mt-1 block whitespace-normal break-words font-serif text-sm leading-snug text-slate-300"
              >
                {@node.comment}
              </span>
            </span>
            <span class="flex shrink-0 items-center gap-2">
              <span
                :if={@node.children != []}
                class="font-mono text-xs text-slate-500"
              >
                {length(@node.children)}
              </span>
              <span class="font-mono text-xs text-slate-500">
                {@node.count}
              </span>
            </span>
          </summary>
          <dl class="ml-4 mt-2 flex flex-col gap-2 text-sm">
            <.detail label="IRI" value={@node.id} />
            <.detail
              :if={Map.get(@node, :parents, []) != []}
              label="parents"
              value={Enum.join(@node.parents, "\n")}
            />
          </dl>
        </details>
      </div>

      <div :if={@node.children != []} class="flex flex-col">
        <%= for child <- @node.children do %>
          <.class_node node={child} depth={@depth + 1} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp detail(assigns) do
    ~H"""
    <div class="grid gap-1 md:grid-cols-[8rem_minmax(0,1fr)]">
      <dt class="text-xs uppercase tracking-widest text-slate-500">{@label}</dt>
      <dd class="whitespace-pre-wrap break-words font-mono text-xs text-slate-300">{@value}</dd>
    </div>
    """
  end

  attr :term, :map, required: true

  defp term_label(assigns) do
    ~H"""
    <span class="block min-w-0">
      <span class={[
        "inline-block max-w-[22ch] truncate align-bottom text-base font-bold text-slate-100",
        if(Map.get(@term, :labeled?, false), do: "font-serif", else: "font-mono")
      ]}>
        {Map.get(@term, :name, @term.label)}
      </span>
      <span
        :if={Map.get(@term, :prefix)}
        class="pl-1 align-baseline font-mono text-xs uppercase text-slate-500"
      >
        {@term.prefix}
      </span>
      <span
        :if={!Map.get(@term, :prefix) and Map.get(@term, :namespace)}
        class="pl-1 align-baseline font-mono text-xs normal-case text-slate-500"
      >
        {@term.namespace}
      </span>
      <span
        :if={
          !Map.get(@term, :labeled?, false) and Map.get(@term, :prefix) == nil and
            @term.compact != @term.label
        }
        class="block truncate font-mono text-xs text-blue-300"
      >
        {@term.compact}
      </span>
    </span>
    """
  end
end
