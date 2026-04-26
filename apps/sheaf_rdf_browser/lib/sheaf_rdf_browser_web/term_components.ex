defmodule SheafRDFBrowserWeb.TermComponents do
  @moduledoc """
  Shared term rendering for RDF browser views.
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :labeled_font, :string, default: nil

  def term_section(assigns) do
    ~H"""
    <section :if={@rows != []} class="mb-4">
      <h3 class="mb-1 text-xs uppercase tracking-widest text-slate-500">{@title}</h3>
      <div class="flex flex-col">
        <.term_row
          :for={term <- @rows}
          term={term}
          labeled_font={@labeled_font}
          emphasized
          count={term.count}
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

  def term_row(assigns) do
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

  def term_label(assigns) do
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

  def term_row_class(_selected, clickable) do
    [
      "block w-full py-0.5 text-left",
      clickable && "cursor-pointer hover:text-white"
    ]
  end

  defp term_label_font(term, true, labeled_font),
    do: if(Map.get(term, :labeled?, false), do: labeled_font, else: "font-mono")

  defp term_label_font(term, false, labeled_font),
    do: if(Map.get(term, :labeled?, false), do: labeled_font || "font-serif", else: "font-mono")
end
