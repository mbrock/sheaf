defmodule SheafWeb.AssistantMarkdownComponents do
  @moduledoc """
  Phoenix components for rendering assistant Markdown from MDEx AST nodes.
  """

  use SheafWeb, :html

  alias SheafWeb.AssistantMarkdown
  alias SheafWeb.DataTableComponents

  attr :text, :string, required: true

  def markdown(assigns) do
    assigns = assign(assigns, :document, AssistantMarkdown.document(assigns.text))

    ~H"""
    <.nodes nodes={@document.nodes} />
    """
  end

  attr :nodes, :list, required: true

  defp nodes(assigns) do
    ~H"""
    <.render_node :for={node <- @nodes} node={node} />
    """
  end

  attr :node, :any, required: true

  defp render_node(%{node: %MDEx.Paragraph{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <p><.nodes nodes={@nodes} /></p>
    """
  end

  defp render_node(%{node: %MDEx.Heading{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:nodes, node.nodes)
      |> assign(:level, node.level |> max(1) |> min(6))

    ~H"""
    <h1 :if={@level == 1}><.nodes nodes={@nodes} /></h1>
    <h2 :if={@level == 2}><.nodes nodes={@nodes} /></h2>
    <h3 :if={@level == 3}><.nodes nodes={@nodes} /></h3>
    <h4 :if={@level == 4}><.nodes nodes={@nodes} /></h4>
    <h5 :if={@level == 5}><.nodes nodes={@nodes} /></h5>
    <h6 :if={@level == 6}><.nodes nodes={@nodes} /></h6>
    """
  end

  defp render_node(%{node: %MDEx.Text{} = node} = assigns) do
    assigns = assign(assigns, :literal, node.literal)

    ~H"""
    {@literal}
    """
  end

  defp render_node(%{node: %MDEx.SoftBreak{}} = assigns) do
    ~H"""
    {"\n"}
    """
  end

  defp render_node(%{node: %MDEx.LineBreak{}} = assigns) do
    ~H"""
    <br />
    """
  end

  defp render_node(%{node: %MDEx.Code{} = node} = assigns) do
    assigns = assign(assigns, :literal, node.literal)

    ~H"""
    <code>{@literal}</code>
    """
  end

  defp render_node(%{node: %MDEx.CodeBlock{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:literal, node.literal)
      |> assign(:language, code_language(node.info))

    ~H"""
    <pre><code class={@language && "language-#{@language}"}>{@literal}</code></pre>
    """
  end

  defp render_node(%{node: %MDEx.Strong{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <strong><.nodes nodes={@nodes} /></strong>
    """
  end

  defp render_node(%{node: %MDEx.Emph{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <em><.nodes nodes={@nodes} /></em>
    """
  end

  defp render_node(%{node: %MDEx.Strikethrough{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <del><.nodes nodes={@nodes} /></del>
    """
  end

  defp render_node(%{node: %MDEx.Link{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:nodes, node.nodes)
      |> assign(:href, safe_href(node.url))
      |> assign(:title, blank_to_nil(node.title))

    ~H"""
    <a :if={@href} href={@href} title={@title}><.nodes nodes={@nodes} /></a>
    <span :if={!@href}><.nodes nodes={@nodes} /></span>
    """
  end

  defp render_node(%{node: %MDEx.Image{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:src, safe_href(node.url))
      |> assign(:alt, text_content(node.nodes))
      |> assign(:title, blank_to_nil(node.title))

    ~H"""
    <img :if={@src} src={@src} alt={@alt} title={@title} />
    <span :if={!@src}>{@alt}</span>
    """
  end

  defp render_node(%{node: %MDEx.List{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:items, node.nodes)
      |> assign(:start, node.start)
      |> assign(:ordered?, node.list_type == :ordered)

    ~H"""
    <ol :if={@ordered?} start={@start}>
      <.nodes nodes={@items} />
    </ol>
    <ul :if={!@ordered?}>
      <.nodes nodes={@items} />
    </ul>
    """
  end

  defp render_node(%{node: %MDEx.ListItem{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <li><.nodes nodes={@nodes} /></li>
    """
  end

  defp render_node(%{node: %MDEx.TaskItem{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:checked, node.checked)
      |> assign(:nodes, node.nodes)

    ~H"""
    <li>
      <input type="checkbox" checked={@checked} disabled />
      <.nodes nodes={@nodes} />
    </li>
    """
  end

  defp render_node(%{node: %MDEx.BlockQuote{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <blockquote><.nodes nodes={@nodes} /></blockquote>
    """
  end

  defp render_node(%{node: %MDEx.MultilineBlockQuote{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <blockquote><.nodes nodes={@nodes} /></blockquote>
    """
  end

  defp render_node(%{node: %MDEx.ThematicBreak{}} = assigns) do
    ~H"""
    <hr />
    """
  end

  defp render_node(%{node: %MDEx.Table{} = table} = assigns) do
    {columns, rows} = table_data(table)

    assigns =
      assigns
      |> assign(:columns, columns)
      |> assign(:rows, rows)

    ~H"""
    <DataTableComponents.data_table columns={@columns} rows={@rows} />
    """
  end

  defp render_node(%{node: %MDEx.HtmlInline{} = node} = assigns) do
    assigns = assign(assigns, :literal, node.literal)

    ~H"""
    {@literal}
    """
  end

  defp render_node(%{node: %MDEx.HtmlBlock{} = node} = assigns) do
    assigns = assign(assigns, :literal, node.literal)

    ~H"""
    <p>{@literal}</p>
    """
  end

  defp render_node(%{node: %{nodes: nodes}} = assigns) when is_list(nodes) do
    assigns = assign(assigns, :nodes, nodes)

    ~H"""
    <.nodes nodes={@nodes} />
    """
  end

  defp render_node(%{node: %{literal: literal}} = assigns) when is_binary(literal) do
    assigns = assign(assigns, :literal, literal)

    ~H"""
    {@literal}
    """
  end

  defp render_node(assigns) do
    ~H"""
    """
  end

  defp table_data(%MDEx.Table{nodes: rows}) do
    {header_rows, body_rows} = Enum.split_with(rows, &match?(%MDEx.TableRow{header: true}, &1))

    columns =
      header_rows
      |> List.first()
      |> row_values()
      |> unique_columns()

    body =
      body_rows
      |> Enum.map(&row_values/1)
      |> Enum.map(&row_map(columns, &1))

    {columns, body}
  end

  defp row_values(%MDEx.TableRow{nodes: cells}), do: Enum.map(cells, &cell_text/1)
  defp row_values(_row), do: []

  defp row_map(columns, values) do
    columns
    |> Enum.with_index()
    |> Map.new(fn {column, index} -> {column, Enum.at(values, index, "")} end)
  end

  defp unique_columns(columns) do
    columns
    |> Enum.with_index()
    |> Enum.map(fn
      {"", index} -> "column_#{index + 1}"
      {column, _index} -> column
    end)
    |> Enum.reduce({[], %{}}, fn column, {columns, counts} ->
      count = Map.get(counts, column, 0)
      next_counts = Map.put(counts, column, count + 1)
      unique_column = if count == 0, do: column, else: "#{column}_#{count + 1}"

      {[unique_column | columns], next_counts}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp cell_text(%MDEx.TableCell{nodes: nodes}) do
    nodes
    |> text_content()
    |> String.replace(~r/[[:blank:]]+/, " ")
    |> String.trim()
  end

  defp text_content(nodes) when is_list(nodes), do: Enum.map_join(nodes, "", &text_content/1)
  defp text_content(%MDEx.Text{literal: literal}), do: literal
  defp text_content(%MDEx.Code{literal: literal}), do: literal
  defp text_content(%MDEx.SoftBreak{}), do: " "
  defp text_content(%MDEx.LineBreak{}), do: " "
  defp text_content(%{nodes: nodes}) when is_list(nodes), do: text_content(nodes)
  defp text_content(%{literal: literal}) when is_binary(literal), do: literal
  defp text_content(_node), do: ""

  defp code_language(info) do
    info
    |> to_string()
    |> String.split()
    |> List.first()
    |> blank_to_nil()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp safe_href(nil), do: nil

  defp safe_href(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      String.starts_with?(url, ["/", "#"]) -> url
      uri.scheme in ["http", "https", "mailto"] -> url
      true -> nil
    end
  end
end
