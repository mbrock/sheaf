defmodule SheafRDFBrowserWeb.BrowserLive do
  @moduledoc """
  Generic ontology-first RDF dataset browser prototype.
  """

  use Phoenix.LiveView

  alias SheafRDFBrowser.{Index, Snapshot}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Snapshot.subscribe()

    snapshot = Snapshot.get()

    {:ok,
     socket
     |> assign(:page_title, "RDF Browser")
     |> assign_snapshot(snapshot)}
  end

  @impl true
  def handle_info({:snapshot_updated, snapshot}, socket) do
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  defp assign_snapshot(socket, snapshot) do
    index = snapshot.index

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:class_tree, Index.class_tree(index))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-950 text-slate-100">
      <div class="mx-auto flex w-full max-w-4xl flex-col px-4 py-5">
        <%= if @snapshot.error do %>
          <pre class="overflow-auto border border-red-700/60 bg-red-950/40 p-3 text-sm text-red-100"><%= @snapshot.error %></pre>
        <% end %>

        <div class="flex flex-col">
          <%= for class <- @class_tree do %>
            <.class_node node={class} depth={0} />
          <% end %>
        </div>
      </div>
    </main>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, required: true

  defp class_node(assigns) do
    assigns = assign(assigns, :indent, "#{assigns.depth * 1.1}rem")

    ~H"""
    <div class="min-w-0">
      <details>
        <summary class="flex cursor-pointer items-baseline gap-2 hover:text-white">
          <.term_label
            term={@node}
            small_caps
            emphasized={@node.count > 0}
            indent={@indent}
            count={@node.count}
          />
        </summary>
        <dl class="mt-1 flex flex-col gap-1 text-sm" style={"margin-left: calc(1rem + #{@indent})"}>
          <.detail label="IRI" value={@node.id} />
          <.detail :if={@node.comment} label="description" value={@node.comment} />
          <.detail
            :if={Map.get(@node, :parents, []) != []}
            label="parents"
            value={Enum.join(@node.parents, "\n")}
          />
        </dl>
      </details>

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
  attr :small_caps, :boolean, default: false
  attr :emphasized, :boolean, default: false
  attr :indent, :string, default: "0rem"
  attr :count, :integer, default: 0

  defp term_label(assigns) do
    ~H"""
    <span class={["min-w-0", !@emphasized && "opacity-75"]} style={"padding-left: #{@indent}"}>
      <span
        :if={Map.get(@term, :prefix)}
        class="mr-1.5 align-baseline text-xs lowercase text-slate-500"
      >
        {@term.prefix}
      </span>
      <span
        :if={!Map.get(@term, :prefix) and Map.get(@term, :namespace)}
        class="mr-1.5 align-baseline text-xs lowercase text-slate-500"
        title={@term.namespace}
      >
        {@term.namespace}
      </span>
      <span class={[
        "inline-block break-words align-bottom text-slate-100",
        @emphasized && "font-bold",
        @small_caps && "small-caps",
        term_label_font(@term, @small_caps)
      ]}>
        {Map.get(@term, :name, @term.label)}
      </span>
      <span :if={@count > 0} class="ml-2 align-baseline font-mono text-xs text-slate-500">
        {@count}
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

  defp term_label_font(_term, true), do: nil

  defp term_label_font(term, false),
    do: if(Map.get(term, :labeled?, false), do: "font-serif", else: "font-mono")
end
