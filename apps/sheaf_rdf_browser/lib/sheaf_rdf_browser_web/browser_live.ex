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

    socket =
      socket
      |> assign(:page_title, "RDF Browser")
      |> assign(:snapshot_refreshing, false)
      |> assign_snapshot(snapshot)

    {:ok, socket}
  end

  @impl true
  def handle_info({:snapshot_updated, snapshot}, socket) do
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  @impl true
  def handle_event("refresh_snapshot", _params, socket) do
    socket =
      socket
      |> assign(:snapshot_refreshing, true)
      |> start_async(:refresh_snapshot, fn -> Snapshot.refresh() end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:refresh_snapshot, {:ok, snapshot}, socket) do
    {:noreply,
     socket
     |> assign(:snapshot_refreshing, false)
     |> assign_snapshot(snapshot)}
  end

  def handle_async(:refresh_snapshot, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:snapshot_refreshing, false)
     |> assign(:snapshot, %{socket.assigns.snapshot | error: inspect(reason)})}
  end

  defp assign_snapshot(socket, snapshot) do
    index = snapshot.index

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:class_tree, Index.class_tree(index))
  end

  defp role_property_rows(rows, count_key) do
    rows
    |> Enum.map(&Map.put(&1, :count, Map.get(&1, count_key, 0)))
    |> Enum.filter(&(&1.count > 0))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-950 text-slate-100">
      <div class="mx-auto flex w-full max-w-none flex-col px-4 py-5">
        <%= if @snapshot.error do %>
          <pre class="overflow-auto border border-red-700/60 bg-red-950/40 p-3 text-sm text-red-100"><%= @snapshot.error %></pre>
        <% end %>

        <div class="flex min-w-0 flex-col">
          <div class="mb-3 flex items-center gap-2">
            <button
              type="button"
              phx-click="refresh_snapshot"
              disabled={@snapshot_refreshing}
              class="font-mono text-xs text-slate-500 hover:text-slate-100 disabled:cursor-wait disabled:text-slate-600"
            >
              refresh
            </button>
            <span
              :if={@snapshot_refreshing}
              class="size-3 rounded-full border border-slate-700 border-t-slate-300 motion-safe:animate-spin"
            />
          </div>

          <%= for class <- @class_tree do %>
            <.class_node
              node={class}
              depth={0}
              snapshot={@snapshot}
            />
          <% end %>
        </div>
      </div>
    </main>
    """
  end

  attr :node, :map, required: true
  attr :depth, :integer, required: true
  attr :snapshot, :map, required: true

  defp class_node(assigns) do
    rows = class_property_rows(assigns.snapshot, assigns.node.id)

    assigns =
      assigns
      |> assign(:indent, "#{assigns.depth * 1.1}rem")
      |> assign(:property_rows, rows)
      |> assign(:domain_rows, role_property_rows(rows, :subject_count))
      |> assign(:range_rows, role_property_rows(rows, :object_count))

    ~H"""
    <div class="min-w-0">
      <details class="min-w-0">
        <summary class={term_row_class(false, true)}>
          <.term_label
            term={@node}
            small_caps
            emphasized={@node.count > 0}
            indent={@indent}
            count={@node.count}
            label_class="text-lg"
          />
        </summary>

        <div
          :if={@node.comment || @property_rows != []}
          class="mt-1 pb-2"
          style={"padding-left: calc(1.1rem + #{@indent})"}
        >
          <p :if={@node.comment} class="mb-3 max-w-3xl text-sm leading-relaxed text-slate-400">
            {@node.comment}
          </p>
          <.property_section title="domain" rows={@domain_rows} />
          <.property_section title="range" rows={@range_rows} />
        </div>
      </details>

      <div :if={@node.children != []} class="flex flex-col">
        <%= for child <- @node.children do %>
          <.class_node
            node={child}
            depth={@depth + 1}
            snapshot={@snapshot}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp class_property_rows(%Snapshot{} = snapshot, class_id) do
    usage = Map.get(snapshot.class_property_cache, class_id, [])
    Index.property_usage_rows(snapshot.index, usage)
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true

  defp property_section(assigns) do
    ~H"""
    <section :if={@rows != []} class="mb-4">
      <h3 class="mb-1 text-xs uppercase tracking-widest text-slate-500">{@title}</h3>
      <div class="flex flex-col">
        <.term_row
          :for={property <- @rows}
          term={property}
          labeled_font="font-sans"
          emphasized
          count={property.count}
        />
      </div>
    </section>
    """
  end

  attr :term, :map, required: true
  attr :small_caps, :boolean, default: false
  attr :emphasized, :boolean, default: false
  attr :indent, :string, default: "0rem"
  attr :count, :integer, default: 0
  attr :selected, :boolean, default: false
  attr :event, :string, default: nil
  attr :labeled_font, :string, default: nil
  attr :label_class, :string, default: nil

  defp term_row(assigns) do
    ~H"""
    <button
      :if={@event}
      type="button"
      phx-click={@event}
      phx-value-id={@term.id}
      class={term_row_class(@selected, true)}
    >
      <.term_label
        term={@term}
        small_caps={@small_caps}
        emphasized={@emphasized}
        indent={@indent}
        count={@count}
        labeled_font={@labeled_font}
        label_class={@label_class}
      />
    </button>

    <div :if={!@event} class={term_row_class(@selected, false)}>
      <.term_label
        term={@term}
        small_caps={@small_caps}
        emphasized={@emphasized}
        indent={@indent}
        count={@count}
        labeled_font={@labeled_font}
        label_class={@label_class}
      />
    </div>
    """
  end

  attr :term, :map, required: true
  attr :small_caps, :boolean, default: false
  attr :emphasized, :boolean, default: false
  attr :indent, :string, default: "0rem"
  attr :count, :integer, default: 0
  attr :labeled_font, :string, default: nil
  attr :label_class, :string, default: nil

  defp term_label(assigns) do
    ~H"""
    <span class={["min-w-0", !@emphasized && "opacity-75"]} style={"padding-left: #{@indent}"}>
      <span class={[
        "inline-block break-words align-bottom text-slate-100",
        @emphasized && "font-bold",
        @small_caps && Map.get(@term, :labeled?, false) && "small-caps",
        term_label_font(@term, @small_caps, @labeled_font),
        @label_class
      ]}>
        {Map.get(@term, :name, @term.label)}
      </span>
      <span
        :if={Map.get(@term, :prefix)}
        class="ml-1.5 align-baseline text-xs lowercase text-slate-500"
      >
        {@term.prefix}
      </span>
      <span
        :if={!Map.get(@term, :prefix) and Map.get(@term, :namespace)}
        class="ml-1.5 align-baseline text-xs lowercase text-slate-500"
        title={@term.namespace}
      >
        {@term.namespace}
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

  defp term_label_font(term, true, labeled_font),
    do: if(Map.get(term, :labeled?, false), do: labeled_font, else: "font-mono")

  defp term_label_font(term, false, labeled_font),
    do: if(Map.get(term, :labeled?, false), do: labeled_font || "font-serif", else: "font-mono")

  defp term_row_class(_selected, clickable) do
    [
      "block w-full py-0.5 text-left",
      clickable && "cursor-pointer hover:text-white"
    ]
  end
end
