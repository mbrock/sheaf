defmodule SheafWeb.AssistantToolResultComponents do
  @moduledoc """
  Render helpers for assistant tool result payloads.
  """

  use SheafWeb, :html

  import SheafWeb.DocumentEntryComponents,
    only: [document_metadata_lines: 1, document_title_line: 1]

  alias Sheaf.Assistant.ToolResults
  alias Sheaf.Assistant.ToolResults.PresentedSpreadsheetQueryResult
  alias SheafWeb.DataTableComponents

  attr :message, :map, required: true
  attr :tool_view, :map, required: true

  def tool_preview_body(
        %{message: %{result: %ToolResults.ListDocuments{} = result}} = assigns
      ) do
    assigns =
      assigns
      |> assign(:documents, Enum.take(result.documents, 8))
      |> assign(:remaining, max(length(result.documents) - 8, 0))

    ~H"""
    <div class="min-w-0">
      <.document_result_item :for={document <- @documents} document={document} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="documents" />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.Document{} = result}} = assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="min-w-0 px-2">
      <div class="text-stone-900 dark:text-stone-50">
        {@result.title}
      </div>
      <.outline_preview entries={@result.outline} />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.Blocks{} = result}} = assigns
      ) do
    assigns =
      assigns
      |> assign(
        :blocks,
        result.blocks |> Enum.filter(&informative_block?/1) |> Enum.take(6)
      )
      |> assign(:remaining, max(length(result.blocks) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.block_result_item :for={block <- @blocks} block={block} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="blocks" />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.Block{} = result}} = assigns
      ) do
    assigns = assign(assigns, :block, result)

    ~H"""
    <.block_result_item block={@block} />
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.SearchResults{} = result}} = assigns
      ) do
    assigns =
      assigns
      |> assign(:exact_results, result.exact_results)
      |> assign(:approximate_results, result.approximate_results)
      |> assign(
        :query,
        tool_arg(Map.get(assigns.message, :input, %{}), :query) || ""
      )

    ~H"""
    <div class="min-w-0">
      <.search_result_group
        label="Exact matches"
        hits={@exact_results}
        query={@query}
      />
      <.search_result_group
        label="Related passages"
        hits={@approximate_results}
        query={@query}
      />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.ListSpreadsheets{} = result}} =
          assigns
      ) do
    assigns =
      assigns
      |> assign(:spreadsheets, Enum.take(result.spreadsheets, 6))
      |> assign(:remaining, max(length(result.spreadsheets) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.spreadsheet_result_item
        :for={spreadsheet <- @spreadsheets}
        spreadsheet={spreadsheet}
      />
      <.more_result_row
        :if={@remaining > 0}
        count={@remaining}
        noun="spreadsheets"
      />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.SpreadsheetSearch{} = result}} =
          assigns
      ) do
    assigns =
      assigns
      |> assign(:hits, Enum.take(result.hits, 6))
      |> assign(:remaining, max(length(result.hits) - 6, 0))

    ~H"""
    <div class="min-w-0">
      <.spreadsheet_hit_item :for={hit <- @hits} hit={hit} />
      <.more_result_row :if={@remaining > 0} count={@remaining} noun="hits" />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.SpreadsheetQuery{} = result}} =
          assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <.query_result_preview result={@result} result_id={@result.result_id} />
    """
  end

  def tool_preview_body(
        %{
          message: %{
            result: %ToolResults.SpreadsheetQueryResultPage{} = result
          }
        } = assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <.query_result_preview result={@result} result_id={@result.id} />
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.ParagraphTags{} = result}} = assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="text-stone-600 dark:text-stone-300">
      <div>
        <span class="text-stone-400 dark:text-stone-500">Tags</span> {Enum.join(
          @result.tags,
          ", "
        )}
      </div>
      <div>
        <span class="text-stone-400 dark:text-stone-500">Blocks</span> {Enum.map_join(
          @result.block_ids,
          ", ",
          &"##{&1}"
        )}
      </div>
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.BlockEdit{} = result}} = assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class=" px-2">
      <div class="flex flex-wrap gap-2 font-micro text-stone-500 dark:text-stone-400">
        <span
          :if={@result.document_id}
          class="border border-stone-200 px-1 dark:border-stone-800"
        >
          doc {@result.document_id}
        </span>
        <span
          :if={@result.block_id}
          class="border border-stone-200 px-1 dark:border-stone-800"
        >
          block {@result.block_id}
        </span>
        <span
          :if={@result.target_id}
          class="border border-stone-200 px-1 dark:border-stone-800"
        >
          target {@result.target_id} {@result.position}
        </span>
      </div>
      <.edit_text_preview
        before_text={@result.previous_text}
        after_text={@result.text}
      />
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.SearchIndexUpdate{} = result}} =
          assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <div class="grid grid-cols-2 gap-x-3 gap-y-1 font-sans text-stone-600 dark:text-stone-300">
      <span class="text-stone-400 dark:text-stone-500">Requested</span>
      <span>{Enum.map_join(@result.block_ids, ", ", &"##{&1}")}</span>
      <span class="text-stone-400 dark:text-stone-500">Affected</span>
      <span>{Enum.map_join(@result.affected_blocks, ", ", &"##{&1}")}</span>
      <span class="text-stone-400 dark:text-stone-500">Embeddings</span>
      <span>
        {@result.embedding_embedded_count}/{@result.embedding_target_count} refreshed
      </span>
      <span class="text-stone-400 dark:text-stone-500">Search rows</span>
      <span>{@result.search_count}</span>
    </div>
    """
  end

  def tool_preview_body(
        %{message: %{result: %ToolResults.Note{} = result}} = assigns
      ) do
    assigns = assign(assigns, :result, result)

    ~H"""
    <a
      href={~p"/#{@result.id}"}
      class="text-stone-700 hover:underline dark:text-stone-200"
    >
      Open note {@result.id}
    </a>
    """
  end

  def tool_preview_body(assigns) do
    ~H"""
    <p class="px-2 text-stone-500 dark:text-stone-400">
      {@tool_view.summary || @tool_view.detail || "Waiting for result"}
    </p>
    """
  end

  attr :result, :any, required: true
  attr :tool_view, :map, required: true

  def presented_spreadsheet_result(assigns) do
    assigns = assign(assigns, :table, presented_table(assigns.result))

    ~H"""
    <article class="overflow-hidden border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
      <header class="flex min-w-0 items-start justify-between gap-2 border-b border-stone-200 bg-stone-50 px-2 dark:border-stone-800 dark:bg-stone-950/40">
        <div class="min-w-0">
          <p class="font-sans font-semibold uppercase text-stone-500 dark:text-stone-400">
            Spreadsheet query result
            <span class={["ml-1 font-normal normal-case", @tool_view.status_class]}>
              {@tool_view.detail}
            </span>
          </p>
          <h3 class="font-semibold text-stone-950 dark:text-stone-50">
            {@table.title}
          </h3>
          <p
            :if={@table.description != ""}
            class="text-stone-600 dark:text-stone-300"
          >
            {@table.description}
          </p>
        </div>
        <a
          :if={@table.result_path}
          href={@table.result_path}
          class="grid size-7 shrink-0 place-items-center rounded-sm text-stone-500 transition-colors hover:bg-stone-200 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800 dark:hover:text-stone-50"
          title="Open result"
          aria-label="Open result"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
        </a>
      </header>
      <div class="overflow-x-auto px-2">
        <DataTableComponents.data_table
          columns={@table.columns}
          rows={@table.rows}
        />
      </div>
      <footer class="border-t border-stone-200 px-2 font-sans text-stone-500 dark:border-stone-800 dark:text-stone-400">
        Showing {@table.returned} {@table.row_label} from offset {@table.offset} of {@table.row_count}
      </footer>
    </article>
    """
  end

  attr :document, :any, required: true

  defp document_result_item(assigns) do
    assigns = assign(assigns, :entry, tool_document_entry(assigns.document))

    ~H"""
    <div class="px-2 last:border-b-0 dark:border-stone-900">
      <.document_title_line
        document={@entry}
        link_title={false}
        show_status_pills={false}
        class="flex min-w-0 items-baseline gap-2 font-sans"
        title_class="min-w-0 flex-1 truncate text-stone-900 dark:text-stone-50"
      />
      <.document_metadata_lines
        document={@entry}
        show_id={true}
        show_kind={true}
        show_status={true}
        show_publisher={false}
        subline_class="flex min-w-0 items-baseline gap-2 truncate font-sans text-stone-500 dark:text-stone-400"
        detail_class="flex min-w-0 items-baseline gap-2 truncate font-sans text-stone-500 dark:text-stone-400"
        authors_class="min-w-0 truncate text-stone-500 dark:text-stone-400"
        id_class="shrink-0 font-micro tabular-nums"
        kind_class="shrink-0"
        status_class="shrink-0 font-micro text-sky-700 dark:text-sky-300"
      />
    </div>
    """
  end

  attr :entries, :list, default: []

  defp outline_preview(assigns) do
    ~H"""
    <ol class="mt-1 font-sans">
      <li :for={entry <- @entries} class="text-stone-600 dark:text-stone-300">
        <span
          :if={Map.get(entry, :number)}
          class="mr-1 tabular-nums text-stone-400 dark:text-stone-500"
        >
          {Map.get(entry, :number)}
        </span>
        <span>{Map.get(entry, :title)}</span>
        <.outline_preview
          :if={Map.get(entry, :children, []) != []}
          entries={Map.get(entry, :children, [])}
        />
      </li>
    </ol>
    """
  end

  attr :block, :any, required: true

  defp block_result_item(assigns) do
    ~H"""
    <section class="min-w-0 border-b border-stone-100 px-2 last:border-b-0 dark:border-stone-900">
      <div class="flex flex-wrap items-baseline gap-x-2 font-sans text-stone-500 dark:text-stone-400">
        <span
          :if={Map.get(@block, :id)}
          class="font-micro tabular-nums text-stone-500 dark:text-stone-400"
        >
          #{Map.get(@block, :id)}
        </span>
        <span :if={Map.get(@block, :document_id)} class="font-micro tabular-nums">
          doc #{Map.get(@block, :document_id)}
        </span>
        <span :if={block_type_label(@block) != ""}>
          {block_type_label(@block)}
        </span>
        <span :if={source_label(Map.get(@block, :source)) != ""}>
          {source_label(Map.get(@block, :source))}
        </span>
      </div>
      <div
        :if={block_heading(@block) != ""}
        class="mt-1  text-stone-900 dark:text-stone-50"
      >
        {block_heading(@block)}
      </div>
      <p
        :if={block_text(@block) != ""}
        class="mt-1 whitespace-pre-wrap text-stone-800 dark:text-stone-100"
      >
        {block_text(@block)}
      </p>
      <ol :if={Map.get(@block, :children, []) != []} class="mt-1 font-sans">
        <li
          :for={child <- Map.get(@block, :children, [])}
          :if={informative_block?(child)}
          class="text-stone-600 dark:text-stone-300"
        >
          <span class="font-micro text-stone-400 dark:text-stone-500">
            #{Map.get(child, :id)}
          </span>
          {block_heading(child) || block_text(child)}
        </li>
      </ol>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :hits, :list, default: []
  attr :query, :string, default: ""

  defp search_result_group(assigns) do
    assigns =
      assigns
      |> assign(:visible_hits, Enum.take(assigns.hits, 5))
      |> assign(:remaining, max(length(assigns.hits) - 5, 0))

    ~H"""
    <section :if={@hits != []} class="last:[&>*:last-child]:after:hidden">
      <.tool_section_label label={@label} count={length(@hits)} />
      <div>
        <.search_hit_item :for={hit <- @visible_hits} hit={hit} query={@query} />
        <.more_result_row :if={@remaining > 0} count={@remaining} noun="passages" />
      </div>
    </section>
    """
  end

  attr :count, :integer, required: true
  attr :noun, :string, required: true

  defp more_result_row(assigns) do
    ~H"""
    <div class="relative px-2 font-sans text-stone-500  dark:bg-stone-950/30 dark:text-stone-400 dark:after:bg-stone-800">
      +{@count} more {@noun}
    </div>
    """
  end

  attr :label, :string, required: true
  attr :count, :integer, default: nil

  defp tool_section_label(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 flex items-center justify-between gap-2 bg-stone-50/90 px-2 font-sans  uppercase text-stone-400 after:absolute after:inset-x-0 after:bottom-0 after:h-px after:bg-stone-200 dark:bg-stone-900/95 dark:text-stone-500 dark:after:bg-stone-800 relative">
      <span>{@label}</span>
      <span :if={is_integer(@count)} class="shrink-0 tabular-nums">{@count}</span>
    </div>
    """
  end

  attr :hit, :any, required: true
  attr :query, :string, default: ""

  defp search_hit_item(assigns) do
    assigns =
      assigns
      |> assign(:block_id, value_at(assigns.hit, :block_id))
      |> assign(:document_title, value_at(assigns.hit, :document_title))
      |> assign(:document_status, value_at(assigns.hit, :document_status))
      |> assign(:context, search_hit_context(assigns.hit))
      |> assign(:score, search_hit_score(assigns.hit))
      |> assign(
        :preview_parts,
        assigns.hit
        |> value_at(:text)
        |> search_display_text()
        |> search_excerpt(assigns.query, 90)
        |> highlighted_search_parts(assigns.query)
      )
      |> assign(
        :parts,
        assigns.hit
        |> value_at(:text)
        |> search_display_text()
        |> highlighted_search_parts(assigns.query)
      )

    ~H"""
    <details class="group relative bg-white after:absolute after:inset-x-0 after:bottom-0 after:h-px after:bg-stone-200 last:after:hidden open:bg-stone-50 dark:bg-stone-950/30 dark:after:bg-stone-800 dark:open:bg-stone-900/80">
      <summary class="flex cursor-pointer list-none gap-x-2 px-2 font-sans transition-colors hover:bg-stone-50 dark:hover:bg-stone-900/70 [&::-webkit-details-marker]:hidden">
        <span class="min-w-0 flex-1">
          <span class="flex min-w-0 items-baseline gap-x-2 overflow-hidden font-sans text-stone-500 dark:text-stone-400">
            <span
              :if={@block_id}
              class="shrink-0 font-micro tabular-nums text-stone-600 dark:text-stone-300"
            >
              #{@block_id}
            </span>
            <span
              :if={@document_title}
              class="min-w-0 truncate  text-stone-700 dark:text-stone-200"
            >
              {@document_title}
            </span>
            <span
              :if={@document_status}
              class={search_status_class(@document_status)}
            >
              {@document_status}
            </span>
          </span>
          <span class="block min-w-0 truncate font-sans text-stone-900 dark:text-stone-100">
            <span :for={{part, highlighted?} <- @preview_parts}>
              <mark
                :if={highlighted?}
                class="bg-amber-200/60 px-0.5 text-inherit dark:bg-amber-400/25"
              >
                {part}
              </mark>
              <span :if={!highlighted?}>{part}</span>
            </span>
          </span>
        </span>
        <span class="w-10 shrink-0 self-start text-right font-sans tabular-nums text-stone-400 dark:text-stone-500">
          {@score}
        </span>
      </summary>
      <div class="relative px-2 before:absolute before:inset-x-0 before:top-0 before:h-px before:bg-stone-200 dark:before:bg-stone-800">
        <div
          :if={present_text?(@context)}
          class="h-5 truncate font-sans text-stone-500 dark:text-stone-400"
        >
          {@context}
        </div>
        <p
          :if={@parts != []}
          class="max-h-24 overflow-y-auto text-stone-800 dark:text-stone-100"
        >
          <span :for={{part, highlighted?} <- @parts}>
            <mark
              :if={highlighted?}
              class="bg-amber-200/60 px-0.5 text-inherit dark:bg-amber-400/25"
            >
              {part}
            </mark>
            <span :if={!highlighted?}>{part}</span>
          </span>
        </p>
      </div>
    </details>
    """
  end

  attr :spreadsheet, :any, required: true

  defp spreadsheet_result_item(assigns) do
    ~H"""
    <section class="border-b border-stone-100 px-2 last:border-b-0 dark:border-stone-900">
      <div class=" text-stone-900 dark:text-stone-50">
        {Map.get(@spreadsheet, :title)}
      </div>
      <ol class="mt-1 font-sans text-stone-600 dark:text-stone-300">
        <li :for={sheet <- Map.get(@spreadsheet, :sheets, [])}>
          <span class="">{Map.get(sheet, :name)}</span>
          <span class="text-stone-500 dark:text-stone-400">
            {Map.get(sheet, :row_count)} rows x {Map.get(sheet, :col_count)} columns
          </span>
        </li>
      </ol>
    </section>
    """
  end

  attr :hit, :any, required: true

  defp spreadsheet_hit_item(assigns) do
    ~H"""
    <article class="border-l border-stone-200 px-2 dark:border-stone-800">
      <div class="font-sans text-stone-500 dark:text-stone-400">
        {Map.get(@hit, :document_title) || Map.get(@hit, :document_id)}
      </div>
      <p class="mt-0.5 text-stone-800 dark:text-stone-100">
        {Map.get(@hit, :text) || Map.get(@hit, :match)}
      </p>
    </article>
    """
  end

  attr :result, :any, required: true
  attr :result_id, :string, default: nil

  defp query_result_preview(assigns) do
    ~H"""
    <div class="px-2">
      <pre
        :if={Map.get(@result, :sql)}
        class="max-h-24 overflow-auto border border-stone-100 bg-stone-50 text-stone-700 dark:border-stone-800 dark:bg-stone-900 dark:text-stone-200"
      ><code>{Map.get(@result, :sql)}</code></pre>
      <div class="overflow-x-auto">
        <table class="min-w-full border-collapse font-sans">
          <thead>
            <tr class="border-b border-stone-200 text-left text-stone-500 dark:border-stone-800 dark:text-stone-400">
              <th :for={column <- Map.get(@result, :columns, [])} class="px-1 ">
                {column}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- Map.get(@result, :rows, [])}
              class="border-b border-stone-100 last:border-b-0 dark:border-stone-900"
            >
              <td
                :for={column <- Map.get(@result, :columns, [])}
                class="px-1 text-stone-700 dark:text-stone-200"
              >
                {cell_value(row, column)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <a
        :if={@result_id}
        href={~p"/#{@result_id}"}
        class="inline-block text-stone-500 hover:underline dark:text-stone-400"
      >
        Open saved result {@result_id}
      </a>
    </div>
    """
  end

  attr :before_text, :string, default: nil
  attr :after_text, :string, default: nil

  defp edit_text_preview(assigns) do
    ~H"""
    <div class="grid gap-1">
      <p
        :if={present_text?(@before_text)}
        class="border-l border-red-300 bg-red-50/50 px-1.5 text-red-800 dark:border-red-900 dark:bg-red-950/20 dark:text-red-200"
      >
        {@before_text}
      </p>
      <p
        :if={present_text?(@after_text)}
        class="border-l border-emerald-400 bg-emerald-50/50 px-1.5 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/20 dark:text-emerald-100"
      >
        {@after_text}
      </p>
    </div>
    """
  end

  defp tool_document_entry(document) do
    %{
      id: Map.get(document, :id),
      kind: Map.get(document, :kind),
      path: nil,
      title: Map.get(document, :title),
      excluded?: false,
      cited?: Map.get(document, :cited?, false),
      has_document?: Map.get(document, :has_document?, true),
      metadata: %{
        authors: Map.get(document, :authors, []),
        year: Map.get(document, :year),
        kind: Map.get(document, :metadata_kind) || Map.get(document, :kind),
        page_count: Map.get(document, :page_count),
        status: Map.get(document, :status)
      }
    }
  end

  defp block_type_label(block) do
    block
    |> Map.get(:type)
    |> case do
      nil -> ""
      type -> type |> to_string() |> clean_machine_label()
    end
  end

  defp block_heading(block) do
    cond do
      present_text?(Map.get(block, :title)) ->
        Map.get(block, :title)

      Map.get(block, :ancestry, []) != [] ->
        block_context_line(Map.get(block, :ancestry, []))

      true ->
        ""
    end
  end

  defp block_context_line(context) do
    context
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :title) || Map.get(&1, :id)))
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" / ")
  end

  defp block_text(block), do: Map.get(block, :text) |> text_value()

  defp informative_block?(block) when is_map(block) do
    present_text?(Map.get(block, :title)) or
      present_text?(Map.get(block, :text)) or
      present_text?(Map.get(block, :preview))
  end

  defp informative_block?(_block), do: false

  defp clean_machine_label("NORMAL_TEXT"), do: ""

  defp clean_machine_label(value),
    do: value |> String.replace("_", " ") |> String.downcase()

  defp source_label(source) when is_map(source) do
    [value_at(source, :type), source_page_label(value_at(source, :page))]
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" ")
  end

  defp source_label(_source), do: ""

  defp source_page_label(page) when page in [nil, "", "nil"], do: nil
  defp source_page_label(page), do: "p. #{page}"

  defp search_hit_context(hit) do
    [
      search_kind_label(value_at(hit, :kind)),
      source_page_label(value_at(hit, :source_page)),
      search_coding_label(value_at(hit, :coding)),
      search_outline_label(value_at(hit, :context) || [])
    ]
    |> Enum.reject(&(!present_text?(&1)))
    |> Enum.join(" · ")
  end

  defp search_kind_label(:extracted), do: "source"
  defp search_kind_label(:paragraph), do: "paragraph"
  defp search_kind_label(:row), do: "coded row"
  defp search_kind_label(nil), do: nil

  defp search_kind_label(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
  end

  defp search_coding_label(coding) when is_map(coding) do
    [
      row_label(value_at(coding, :row)),
      value_at(coding, :source),
      value_at(coding, :category_title)
    ]
    |> Enum.reject(&(!present_text?(&1)))
    |> Enum.join(" · ")
  end

  defp search_coding_label(_coding), do: nil

  defp search_outline_label(context) do
    context
    |> List.wrap()
    |> Enum.map(fn entry ->
      if is_map(entry),
        do: value_at(entry, :title) || value_at(entry, :id),
        else: nil
    end)
    |> Enum.filter(&present_text?/1)
    |> Enum.take(-2)
    |> Enum.join(" / ")
  end

  defp search_hit_score(hit) do
    case value_at(hit, :score) do
      score when is_float(score) -> "#{round(score * 100)}%"
      score when is_integer(score) -> "#{score}"
      _score -> ""
    end
  end

  defp search_status_class("draft") do
    "shrink-0 font-micro text-sky-700 dark:text-sky-300"
  end

  defp search_status_class("mikael") do
    "shrink-0 font-micro text-emerald-700 dark:text-emerald-300"
  end

  defp search_status_class(_status) do
    "shrink-0 font-micro text-stone-500 dark:text-stone-400"
  end

  defp search_display_text(text) do
    text
    |> text_value()
    |> String.replace(~r/\s+/, " ")
  end

  defp search_excerpt(text, query, radius) do
    text = text_value(text)
    query = text_value(query)

    cond do
      text == "" ->
        ""

      query == "" ->
        String.slice(text, 0, radius * 2)

      true ->
        haystack = String.downcase(text)
        needle = String.downcase(query)

        case :binary.match(haystack, needle) do
          {index, length} ->
            start = max(index - radius, 0)
            finish = min(index + length + radius, String.length(text))
            prefix = if start > 0, do: "... ", else: ""
            suffix = if finish < String.length(text), do: " ...", else: ""
            prefix <> String.slice(text, start, finish - start) <> suffix

          :nomatch ->
            String.slice(text, 0, radius * 2)
        end
    end
  end

  defp highlighted_search_parts(text, query) do
    text = text_value(text)
    query = text_value(query)

    cond do
      text == "" ->
        []

      query == "" ->
        [{text, false}]

      true ->
        split_highlighted_text(text, query)
    end
  end

  defp split_highlighted_text(text, query) do
    pattern = Regex.compile!(Regex.escape(query), "iu")
    normalized_query = String.downcase(query)

    pattern
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      {part, String.downcase(part) == normalized_query}
    end)
  end

  defp row_label(nil), do: nil
  defp row_label(row), do: "row #{row}"

  defp value_at(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      "nil" -> nil
      value -> value
    end
  end

  defp value_at(_value, _key), do: nil

  defp cell_value(row, column) when is_map(row) do
    value = Map.get(row, column) || Map.get(row, to_string(column))
    if is_nil(value), do: "", else: to_string(value)
  end

  defp cell_value(_row, _column), do: ""

  defp present_text?(value) when is_binary(value), do: text_value(value) != ""
  defp present_text?(nil), do: false
  defp present_text?(value), do: value |> to_string() |> text_value() != ""

  defp text_value(value) when is_binary(value) do
    value = String.trim(value)
    if String.downcase(value) == "nil", do: "", else: value
  end

  defp text_value(_value), do: ""

  defp tool_arg(input, key) when is_map(input) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  defp tool_arg(_, _), do: nil

  defp presented_table(%PresentedSpreadsheetQueryResult{} = result) do
    labels = presented_column_labels(result.columns, result.column_specs)

    %{
      title: result.title || "Spreadsheet query result",
      description: result.description || "",
      columns: Enum.map(result.columns, &Map.fetch!(labels, &1)),
      rows: Enum.map(result.rows, &presented_row(&1, result.columns, labels)),
      returned: length(result.rows),
      row_label: if(length(result.rows) == 1, do: "row", else: "rows"),
      offset: result.offset || 0,
      row_count: result.row_count || length(result.rows),
      result_path: result_path(result.id)
    }
  end

  defp presented_table(_result) do
    %{
      title: "Spreadsheet query result",
      description: "",
      columns: [],
      rows: [],
      returned: 0,
      row_label: "rows",
      offset: 0,
      row_count: 0,
      result_path: nil
    }
  end

  defp presented_column_labels(columns, specs) do
    specs_by_name =
      Map.new(specs || [], fn spec ->
        {Map.get(spec, :name) || Map.get(spec, "name"), spec}
      end)

    columns
    |> Enum.map(fn column ->
      spec = Map.get(specs_by_name, column, %{})
      label = Map.get(spec, :label) || Map.get(spec, "label") || column
      {column, label}
    end)
    |> uniquify_labels()
    |> Map.new()
  end

  defp uniquify_labels(column_labels) do
    {labeled, _seen} =
      Enum.map_reduce(column_labels, %{}, fn {column, label}, seen ->
        count = Map.get(seen, label, 0) + 1
        display_label = if count == 1, do: label, else: "#{label} #{count}"
        {{column, display_label}, Map.put(seen, label, count)}
      end)

    labeled
  end

  defp presented_row(row, columns, labels) do
    Map.new(columns, fn column ->
      {Map.fetch!(labels, column), Map.get(row, column)}
    end)
  end

  defp result_path(nil), do: nil
  defp result_path(""), do: nil
  defp result_path(id), do: ~p"/#{id}"
end
