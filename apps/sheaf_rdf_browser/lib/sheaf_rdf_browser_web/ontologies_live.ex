defmodule SheafRDFBrowserWeb.OntologiesLive do
  @moduledoc """
  Namespace-based OWL ontology browser.
  """

  use Phoenix.LiveView

  alias Phoenix.HTML
  alias SheafRDFBrowser.{Index, Snapshot}

  @mdex_opts [
    extension: [
      strikethrough: true,
      autolink: true,
      table: true,
      tasklist: true
    ],
    render: [unsafe_: false, hardbreaks: true],
    parse: [smart: true]
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Snapshot.subscribe()

    socket =
      socket
      |> assign(:page_title, "OWL Ontologies")
      |> assign(:snapshot_refreshing, false)
      |> assign_snapshot(Snapshot.get())

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
    socket
    |> assign(:snapshot, snapshot)
    |> assign(:ontologies, Index.ontology_rows(snapshot.index))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-950 text-slate-100">
      <div class="mx-auto flex w-full max-w-none flex-col px-4 py-5">
        <%= if @snapshot.error do %>
          <pre class="overflow-auto border border-red-700/60 bg-red-950/40 p-3 text-sm text-red-100"><%= @snapshot.error %></pre>
        <% end %>

        <section :for={ontology <- @ontologies} class="min-w-0 pb-8">
          <div class="flex min-w-0 flex-col gap-1">
            <.ontology_label ontology={ontology} />
            <.ontology_notes notes={ontology.notes} />
            <.class_overview
              classes={ontology.class_tree}
              snapshot={@snapshot}
              ontology_prefix={ontology.prefix}
            />
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :ontology, :map, required: true

  defp ontology_label(assigns) do
    ~H"""
    <span class="flex w-full min-w-0 items-baseline justify-between gap-4">
      <span class="min-w-0 break-words align-bottom font-serif text-xl font-bold text-slate-100">
        {Map.get(@ontology, :name, @ontology.label)}
      </span>
      <span
        :if={@ontology.prefix}
        class="shrink-0 align-baseline font-mono text-xl font-bold uppercase text-slate-500"
      >
        {@ontology.prefix}
      </span>
    </span>
    """
  end

  attr :notes, :list, required: true

  defp ontology_notes(assigns) do
    ~H"""
    <div :if={@notes != []} class="mb-1 max-w-4xl text-xs leading-snug text-slate-500">
      <section :for={note <- @notes} class="mb-3 last:mb-0">
        <h3 class="mb-0.5 font-sans text-[0.6rem] font-semibold uppercase text-slate-600">
          {note.label}
        </h3>
        <div
          :for={value <- note.values}
          class="ontology-note-markdown mb-1 last:mb-0"
        >
          {render_markdown(value)}
        </div>
      </section>
    </div>
    """
  end

  attr :classes, :list, required: true
  attr :snapshot, Snapshot, required: true
  attr :ontology_prefix, :string, default: nil
  attr :depth, :integer, default: 0

  defp class_overview(assigns) do
    assigns = assign(assigns, :leaf_list, leaf_list?(assigns.classes, assigns.snapshot.index))

    ~H"""
    <div
      :if={@classes != []}
      class={["min-w-0", @leaf_list && "flex flex-wrap gap-x-5", !@leaf_list && "flex flex-col"]}
    >
      <%= if @leaf_list do %>
        <.leaf_class_item
          :for={class <- @classes}
          class={class}
          snapshot={@snapshot}
          ontology_prefix={@ontology_prefix}
          depth={@depth}
        />
      <% else %>
        <.class_overview_row
          :for={class <- @classes}
          class={class}
          snapshot={@snapshot}
          ontology_prefix={@ontology_prefix}
          depth={@depth}
        />
      <% end %>
    </div>
    """
  end

  attr :class, :map, required: true
  attr :snapshot, Snapshot, required: true
  attr :ontology_prefix, :string, default: nil
  attr :depth, :integer, required: true

  defp leaf_class_item(assigns) do
    property_rows = class_schema_property_rows(assigns.snapshot.index, assigns.class.id)

    assigns =
      assigns
      |> assign(:indent, "#{assigns.depth * 1.1}rem")
      |> assign(:property_rows, property_rows)

    ~H"""
    <div class="min-w-0">
      <.class_heading class={@class} indent={@indent} ontology_prefix={@ontology_prefix} />

      <div
        :if={@property_rows != []}
        class="mb-1 flex min-w-0 flex-wrap gap-x-3 gap-y-0 pl-[1.1rem]"
      >
        <.overview_property_row
          :for={property <- @property_rows}
          property={property}
          ontology_prefix={@ontology_prefix}
        />
      </div>
    </div>
    """
  end

  attr :class, :map, required: true
  attr :snapshot, Snapshot, required: true
  attr :ontology_prefix, :string, default: nil
  attr :depth, :integer, required: true

  defp class_overview_row(assigns) do
    property_rows = class_schema_property_rows(assigns.snapshot.index, assigns.class.id)

    assigns =
      assigns
      |> assign(:indent, "#{assigns.depth * 1.1}rem")
      |> assign(:property_rows, property_rows)

    ~H"""
    <div class="min-w-0">
      <.class_heading class={@class} indent={@indent} ontology_prefix={@ontology_prefix} />

      <div
        :if={@property_rows != []}
        class="mb-1 flex min-w-0 flex-wrap gap-x-3 gap-y-0 pl-[1.1rem]"
        style={"margin-left: #{@indent}"}
      >
        <.overview_property_row
          :for={property <- @property_rows}
          property={property}
          ontology_prefix={@ontology_prefix}
        />
      </div>

      <.class_overview
        :if={@class.children != []}
        classes={@class.children}
        snapshot={@snapshot}
        ontology_prefix={@ontology_prefix}
        depth={@depth + 1}
      />
    </div>
    """
  end

  attr :class, :map, required: true
  attr :indent, :string, required: true
  attr :ontology_prefix, :string, default: nil

  defp class_heading(assigns) do
    assigns =
      assigns
      |> assign(:show_namespace, class_namespace?(assigns.class, assigns.ontology_prefix))
      |> assign(:popover_id, class_popover_id(assigns.class.id))
      |> assign(:anchor_name, class_anchor_name(assigns.class.id))
      |> assign(:has_notes, class_notes?(assigns.class))

    ~H"""
    <div class="min-w-0">
      <%= if @has_notes do %>
        <button
          type="button"
          popovertarget={@popover_id}
          class={[
            "flex min-w-0 cursor-pointer items-baseline gap-1.5 bg-transparent p-0 text-left leading-tight hover:text-slate-100",
            Map.get(@class, :external_ancestor?, false) && "opacity-45"
          ]}
          style={"padding-left: #{@indent}; anchor-name: #{@anchor_name}"}
        >
          <.class_heading_content class={@class} show_namespace={@show_namespace} />
        </button>

        <div
          id={@popover_id}
          popover="auto"
          class="rdf-class-popover max-w-xl bg-slate-900 px-3 py-2 font-mono text-[0.68rem] leading-normal text-slate-300 shadow-xl"
          style={"position-anchor: #{@anchor_name}"}
        >
          <.class_notes notes={@class.notes} />
        </div>
      <% else %>
        <div
          class={[
            "flex min-w-0 items-baseline gap-1.5 leading-tight",
            Map.get(@class, :external_ancestor?, false) && "opacity-45"
          ]}
          style={"padding-left: #{@indent}"}
        >
          <.class_heading_content class={@class} show_namespace={@show_namespace} />
          <span class="font-mono text-[0.65rem] text-slate-600">?</span>
        </div>
      <% end %>
    </div>
    """
  end

  attr :class, :map, required: true
  attr :show_namespace, :boolean, required: true

  defp class_heading_content(assigns) do
    ~H"""
    <span class="shrink-0 text-slate-600">•</span>
    <span class={[
      "small-caps break-words align-baseline text-slate-300 opacity-80",
      !Map.get(@class, :labeled?, false) && "font-mono"
    ]}>
      {Map.get(@class, :name, @class.label)}
    </span>
    <span :if={@show_namespace} class="ml-1 text-xs lowercase text-slate-600">
      {@class.prefix || @class.namespace}
    </span>
    """
  end

  attr :notes, :list, required: true

  defp class_notes(assigns) do
    ~H"""
    <div class="flex max-w-prose flex-col gap-2">
      <section :for={note <- @notes}>
        <h4 class="mb-0.5 font-sans text-[0.6rem] font-semibold uppercase text-slate-500">
          {note.label}
        </h4>
        <p :for={value <- note.values}>
          {class_note_value(value)}
        </p>
      </section>
    </div>
    """
  end

  attr :property, :map, required: true
  attr :ontology_prefix, :string, default: nil

  defp overview_property_row(assigns) do
    assigns =
      assigns
      |> assign(:marker, property_marker(assigns.property.role))
      |> assign(:term, maybe_hide_same_prefix(assigns.property, assigns.ontology_prefix))
      |> assign(:show_prefix, property_prefix?(assigns.property, assigns.ontology_prefix))

    ~H"""
    <div class="flex min-w-0 items-baseline gap-0.5">
      <span class="w-4 shrink-0 text-center font-mono text-xs text-slate-600">{@marker}</span>
      <span class={[
        "break-words align-baseline font-sans text-xs text-slate-400",
        @property.count > 0 && "font-bold text-slate-300",
        !Map.get(@term, :labeled?, false) && "font-mono"
      ]}>
        {Map.get(@term, :name, @term.label)}
      </span>
      <span :if={@show_prefix} class="ml-1 text-xs lowercase text-slate-600">
        {@property.prefix || @property.namespace}
      </span>
    </div>
    """
  end

  defp class_schema_property_rows(index, class_id) do
    rows = Index.class_schema_property_rows(index, class_id)

    rows.domain
    |> Map.new(&{&1.id, Map.put(&1, :role, :domain)})
    |> Map.merge(Map.new(rows.range, &{&1.id, Map.put(&1, :role, :range)}), fn
      _id, domain_row, range_row ->
        domain_row
        |> Map.put(:role, :both)
        |> Map.put(:count, max(domain_row.count, range_row.count))
    end)
    |> Map.values()
    |> Enum.sort_by(fn property ->
      namespace = property.prefix || property.namespace || ""
      label = Map.get(property, :name) || property.label || property.id

      {String.downcase(namespace), String.downcase(label), property.id}
    end)
  end

  defp property_marker(:domain), do: "→"
  defp property_marker(:range), do: "←"
  defp property_marker(:both), do: "↔"

  defp maybe_hide_same_prefix(property, prefix) when is_binary(prefix) do
    if property.prefix == prefix do
      %{property | prefix: nil}
    else
      property
    end
  end

  defp maybe_hide_same_prefix(property, _prefix), do: property

  defp property_prefix?(property, prefix) when is_binary(prefix) do
    (property.prefix || property.namespace) && property.prefix != prefix
  end

  defp property_prefix?(property, _prefix), do: property.prefix || property.namespace

  defp leaf_list?(classes, index) do
    Enum.all?(classes, fn class ->
      class.children == [] and class_schema_property_rows(index, class.id) == []
    end)
  end

  defp class_namespace?(class, prefix) when is_binary(prefix) do
    (class.prefix || class.namespace) && class.prefix != prefix
  end

  defp class_namespace?(class, _prefix), do: class.prefix || class.namespace
  defp class_notes?(class), do: Map.get(class, :notes, []) != []

  defp class_popover_id(class_id), do: "class-popover-#{class_hash(class_id)}"
  defp class_anchor_name(class_id), do: "--class-anchor-#{class_hash(class_id)}"
  defp class_hash(class_id), do: :erlang.phash2(class_id)

  defp render_markdown(text) do
    text
    |> MDEx.to_html!(@mdex_opts)
    |> HTML.raw()
  end

  defp class_note_value(value), do: String.replace(value, ~r/[[:space:]]+/, " ")
end
