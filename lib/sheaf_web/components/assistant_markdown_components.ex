defmodule SheafWeb.AssistantMarkdownComponents do
  @moduledoc """
  Phoenix components for rendering assistant Markdown from MDEx AST nodes.
  """

  use SheafWeb, :html

  alias SheafWeb.AssistantMarkdown
  alias SheafWeb.DataTableComponents

  attr :text, :string, required: true
  attr :block_ref_target, :any, default: nil
  attr :resolve_block_previews, :boolean, default: false

  def markdown(assigns) do
    assigns =
      assigns
      |> assign(:document, AssistantMarkdown.document(assigns.text))

    ~H"""
    <.nodes nodes={@document.nodes} block_ref_target={@block_ref_target} />
    """
  end

  attr :nodes, :list, required: true
  attr :block_ref_target, :any, default: nil

  defp nodes(assigns) do
    assigns = assign(assigns, :nodes, attach_ref_punctuation(assigns.nodes))

    ~H"""
    <.render_node
      :for={{node, trailing_punctuation} <- @nodes}
      node={node}
      trailing_punctuation={trailing_punctuation}
      block_ref_target={@block_ref_target}
    />
    """
  end

  attr :node, :any, required: true
  attr :trailing_punctuation, :string, default: nil
  attr :block_ref_target, :any, default: nil

  defp render_node(%{node: %MDEx.Paragraph{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <p><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></p>
    """
  end

  defp render_node(%{node: %MDEx.Heading{} = node} = assigns) do
    assigns =
      assigns
      |> assign(:nodes, node.nodes)
      |> assign(:level, node.level |> max(1) |> min(6))

    ~H"""
    <h1 :if={@level == 1}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h1>
    <h2 :if={@level == 2}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h2>
    <h3 :if={@level == 3}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h3>
    <h4 :if={@level == 4}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h4>
    <h5 :if={@level == 5}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h5>
    <h6 :if={@level == 6}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></h6>
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
    <strong><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></strong>
    """
  end

  defp render_node(%{node: %MDEx.Emph{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <em><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></em>
    """
  end

  defp render_node(%{node: %MDEx.Strikethrough{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <del><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></del>
    """
  end

  defp render_node(%{node: %MDEx.Link{} = node} = assigns) do
    href = safe_href(node.url)
    resource_id = resource_link_id(href)

    assigns =
      assigns
      |> assign(:nodes, node.nodes)
      |> assign(:href, href)
      |> assign(:title, blank_to_nil(node.title))
      |> assign(:resource_id, resource_id)

    ~H"""
    <.resource_ref_link
      :if={@href && @resource_id && @block_ref_target}
      title={@title}
      resource_id={@resource_id}
      block_ref_target={@block_ref_target}
      trailing_punctuation={@trailing_punctuation}
    />
    <a :if={@href && (!@resource_id || !@block_ref_target)} href={@href} title={@title}>
      <.nodes nodes={@nodes} block_ref_target={@block_ref_target} />
    </a>
    <span :if={!@href}><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></span>
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
      <.nodes nodes={@items} block_ref_target={@block_ref_target} />
    </ol>
    <ul :if={!@ordered?}>
      <.nodes nodes={@items} block_ref_target={@block_ref_target} />
    </ul>
    """
  end

  defp render_node(%{node: %MDEx.ListItem{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <li><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></li>
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
      <.nodes nodes={@nodes} block_ref_target={@block_ref_target} />
    </li>
    """
  end

  defp render_node(%{node: %MDEx.BlockQuote{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <blockquote><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></blockquote>
    """
  end

  defp render_node(%{node: %MDEx.MultilineBlockQuote{} = node} = assigns) do
    assigns = assign(assigns, :nodes, node.nodes)

    ~H"""
    <blockquote><.nodes nodes={@nodes} block_ref_target={@block_ref_target} /></blockquote>
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
    <.nodes nodes={@nodes} block_ref_target={@block_ref_target} />
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

  defp attach_ref_punctuation(nodes) do
    nodes
    |> do_attach_ref_punctuation([])
    |> Enum.reverse()
  end

  defp do_attach_ref_punctuation(
         [%MDEx.Link{} = link, %MDEx.Text{literal: literal} = text | rest],
         acc
       ) do
    case leading_punctuation_after_ref(link, literal) do
      {punctuation, literal} ->
        do_attach_ref_punctuation([%{text | literal: literal} | rest], [
          {link, punctuation} | acc
        ])

      nil ->
        do_attach_ref_punctuation([text | rest], [{link, nil} | acc])
    end
  end

  defp do_attach_ref_punctuation([node | rest], acc) do
    do_attach_ref_punctuation(rest, [{node, nil} | acc])
  end

  defp do_attach_ref_punctuation([], acc), do: acc

  defp leading_punctuation_after_ref(%MDEx.Link{} = link, literal) do
    with resource_id when is_binary(resource_id) <- resource_link_id(safe_href(link.url)),
         [_, punctuation, rest] <- Regex.run(~r/^[ \t]*([,.;:!?\)\]\}]+)(.*)$/s, literal) do
      {punctuation, rest}
    else
      _other -> nil
    end
  end

  attr :title, :string, default: nil
  attr :resource_id, :string, required: true
  attr :block_ref_target, :any, required: true
  attr :trailing_punctuation, :string, default: nil

  defp resource_ref_link(assigns) do
    ~H"""
    <span class="block-preview relative inline-block align-baseline">
      <button
        type="button"
        title={@title}
        aria-label={"##{@resource_id}"}
        class="block-preview-trigger cursor-pointer"
        phx-click="show_resource_preview"
        phx-value-id={@resource_id}
        phx-target={@block_ref_target}
      >{@resource_id}</button>
    </span>{@trailing_punctuation}
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

  defp resource_link_id("/b/" <> id), do: id |> String.split(["?", "#"], parts: 2) |> hd()

  defp resource_link_id("/" <> id) do
    case String.split(id, ["/", "?", "#"], parts: 2) do
      [id] when id != "" -> id
      [id, _rest] when id != "" -> id
      _other -> nil
    end
  end

  defp resource_link_id(_href), do: nil
end
