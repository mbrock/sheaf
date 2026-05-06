defmodule SheafWeb.DataTableComponents do
  @moduledoc """
  Components for rendering tabular data.
  """

  use SheafWeb, :html

  attr :id, :string, default: nil
  attr :columns, :list, required: true
  attr :rows, :list, required: true
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :href, :string, default: nil

  def data_table(assigns) do
    assigns =
      assigns
      |> assign(
        :id,
        assigns[:id] || data_table_id(assigns.columns, assigns.rows)
      )
      |> assign(
        :display_columns,
        display_columns(assigns.columns, assigns.rows)
      )
      |> assign(:display_rows, display_rows(assigns.rows, assigns.columns))
      |> assign(:caption?, caption?(assigns))

    ~H"""
    <section class="flex max-w-full flex-col items-center">
      <figure class="flex w-full max-w-full flex-col items-center">
        <div class="max-w-full overflow-x-auto">
          <table
            class="border-separate border-spacing-0 text-left"
            id={@id}
            phx-hook="DataTable"
          >
            <.table_head columns={@display_columns} />
            <.table_body columns={@display_columns} rows={@display_rows} />
          </table>
        </div>
        <figcaption
          :if={@caption?}
          class="flex w-full max-w-prose min-w-0 items-start gap-2 px-3 pt-2 font-text leading-relaxed text-stone-700 dark:text-stone-300 sm:px-0"
        >
          <div class="min-w-0 flex-1">
            <p
              :if={present?(@title)}
              class="font-medium text-stone-950 dark:text-stone-50"
            >
              <.caption_text text={@title} />
            </p>
            <p :if={present?(@subtitle)}>
              <.caption_text text={@subtitle} />
            </p>
          </div>
          <a
            :if={present?(@href)}
            href={@href}
            class="grid size-6 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
            title="Open result"
            aria-label="Open result"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
          </a>
        </figcaption>
      </figure>
    </section>
    """
  end

  attr :text, :string, required: true

  defp caption_text(assigns) do
    assigns = assign(assigns, :parts, caption_parts(assigns.text))

    ~H"""
    <span :for={part <- @parts}>
      <code
        :if={part.kind == :identifier}
        class="font-mono text-stone-800 dark:text-stone-100"
      >
        {part.text}
      </code>
      <span :if={part.kind == :text}>{part.text}</span>
    </span>
    """
  end

  attr :columns, :list, required: true

  defp table_head(assigns) do
    ~H"""
    <thead class="font-mono">
      <tr>
        <.heading_cell :for={column <- @columns} column={column} />
      </tr>
    </thead>
    """
  end

  attr :column, :map, required: true

  defp heading_cell(assigns) do
    ~H"""
    <th
      class="relative h-16 overflow-visible align-bottom"
      title={@column.name}
      data-table-heading-cell
    >
      <span
        class="sheaf-data-table-heading absolute bottom-0 left-0 z-20 origin-bottom-left whitespace-nowrap border-b border-stone-300 pl-2 font-normal text-xs text-stone-700 dark:border-stone-700 dark:text-stone-300"
        data-table-heading-label
        data-heading={@column.heading}
      >
        {@column.heading}
      </span>
    </th>
    """
  end

  attr :columns, :list, required: true
  attr :rows, :list, required: true

  defp table_body(assigns) do
    ~H"""
    <tbody class="outline outline-1 outline-stone-300 dark:outline-stone-700">
      <.table_row :for={row <- @rows} columns={@columns} row={row} />
    </tbody>
    """
  end

  attr :columns, :list, required: true
  attr :row, :map, required: true

  defp table_row(assigns) do
    ~H"""
    <tr class="group odd:bg-white even:bg-stone-50/70 hover:bg-amber-50/80 dark:odd:bg-stone-900 dark:even:bg-stone-900/60 dark:hover:bg-stone-800/70">
      <.table_cell
        :for={column <- @columns}
        cell={@row.cells[column.name]}
        column={column}
      />
    </tr>
    """
  end

  attr :cell, :map, required: true
  attr :column, :map, required: true

  defp table_cell(assigns) do
    ~H"""
    <td class={[
      "min-w-12 border-l border-stone-300 px-2 align-middle text-stone-800 dark:border-stone-700 dark:text-stone-100",
      cell_class(@column.kind),
      cell_width_class(@column.kind)
    ]}>
      <.scalar_cell :if={@cell.list_values == []} cell={@cell} column={@column} />
      <.list_cell :if={@cell.list_values != []} cell={@cell} column={@column} />
    </td>
    """
  end

  attr :cell, :map, required: true
  attr :column, :map, required: true

  defp scalar_cell(assigns) do
    ~H"""
    <div class={scalar_cell_class(@column.kind)} title={@cell.value}>
      {@cell.value}
    </div>
    """
  end

  attr :cell, :map, required: true
  attr :column, :map, required: true

  defp list_cell(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-2", list_justify_class(@column.kind)]}>
      <span
        :for={value <- @cell.list_values}
        class="max-w-64 shrink-0 truncate text-sm"
        title={value}
      >
        {value}
      </span>
    </div>
    """
  end

  defp display_columns(columns, rows) do
    kinds = column_kinds(columns, rows)

    Enum.map(columns, fn column ->
      %{
        name: column,
        heading: heading(column),
        kind: Map.fetch!(kinds, column)
      }
    end)
  end

  defp display_rows(rows, columns) do
    Enum.map(rows, fn row ->
      %{
        cells:
          Map.new(columns, fn column ->
            {column, display_cell(row, column)}
          end)
      }
    end)
  end

  defp caption?(assigns) do
    present?(assigns[:title]) or present?(assigns[:subtitle]) or
      present?(assigns[:href])
  end

  defp caption_parts(text) when is_binary(text) do
    ~r/\b[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]*\b/
    |> Regex.split(text, include_captures: true)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      if Regex.match?(~r/^[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]*$/, part) do
        %{kind: :identifier, text: String.replace(part, "_", " ")}
      else
        %{kind: :text, text: part}
      end
    end)
  end

  defp caption_parts(_text), do: []

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp data_table_id(columns, rows) do
    "data-table-#{:erlang.phash2({columns, rows})}"
  end

  defp display_cell(row, column) do
    value = cell_value(row, column)

    %{
      value: value,
      list_values: list_values(column, value)
    }
  end

  defp cell_value(row, column) do
    case Map.get(row, column) do
      nil -> ""
      value -> value |> to_string() |> String.replace_suffix(".0", "")
    end
  end

  defp column_kinds(columns, rows) do
    Map.new(columns, fn column ->
      {column, column_kind(column, rows)}
    end)
  end

  defp column_kind(column, rows) do
    values =
      rows
      |> Enum.map(&Map.get(&1, column))
      |> Enum.reject(&blank_value?/1)

    cond do
      identifier_column?(column) ->
        :identifier

      values != [] and Enum.all?(values, &number?/1) ->
        :number

      list_column?(column) ->
        :list

      true ->
        :text
    end
  end

  defp identifier_column?(column) do
    column == "id" or String.ends_with?(column, "_id") or
      String.ends_with?(column, "_iri")
  end

  defp list_column?(column) do
    String.ends_with?(column, "_types") or String.ends_with?(column, "_tags")
  end

  defp number?(value) when is_integer(value) or is_float(value), do: true

  defp number?(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {_number, ""} -> true
      _ -> false
    end
  end

  defp number?(_value), do: false

  defp blank_value?(nil), do: true
  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(_value), do: false

  defp cell_class(:identifier),
    do: "font-mono text-sm text-stone-700 dark:text-stone-300"

  defp cell_class(:number), do: "text-right font-mono text-sm tabular-nums"
  defp cell_class(:list), do: "text-left text-sm"
  defp cell_class(_kind), do: "text-left text-sm"

  defp cell_width_class(:number), do: ""
  defp cell_width_class(:identifier), do: "max-w-64"
  defp cell_width_class(_kind), do: "max-w-80"

  defp scalar_cell_class(:number), do: "whitespace-nowrap"
  defp scalar_cell_class(_kind), do: "truncate whitespace-nowrap"

  defp list_justify_class(:list), do: "justify-start"
  defp list_justify_class(_kind), do: "justify-end"

  defp heading(column) do
    String.replace(column, "_", " ")
  end

  defp list_values(column, value) do
    if list_column?(column) and String.contains?(value, ",") do
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end
end
