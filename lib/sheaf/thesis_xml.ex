defmodule Sheaf.ThesisXml do
  @moduledoc """
  Imports local thesis XML files into the main Sheaf graph using the block
  vocabulary already expected by the UI.
  """

  import SweetXml

  alias Sheaf.Fuseki
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS
  alias Sheaf.Prov

  @default_max_update_bytes 200_000

  defmodule SourceDocument do
    defstruct [:path, :title, blocks: []]
  end

  def default_paths do
    Application.app_dir(:sheaf, "priv/thesis-*.xml")
    |> Path.wildcard()
    |> Enum.sort()
  end

  def import(opts \\ []) do
    paths = Keyword.get(opts, :paths, default_paths())
    replace? = Keyword.get(opts, :replace, true)
    max_update_bytes = Keyword.get(opts, :max_update_bytes, @default_max_update_bytes)

    with {:ok, documents} <- load_source_documents(paths),
         :ok <- maybe_clear_graph(replace?),
         {:ok, inserted_statements} <-
           insert_batches(statements_for_documents(documents), max_update_bytes) do
      {:ok,
       %{
         graph: Fuseki.graph(),
         documents: length(documents),
         statements: inserted_statements,
         title: thesis_title(documents)
       }}
    end
  end

  def load_source_documents(paths \\ default_paths()) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, docs} ->
      case parse_file(path) do
        {:ok, doc} -> {:cont, {:ok, docs ++ [doc]}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  def parse_file(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> parse_string(path)
    else
      {:error, "XML source not found at #{path}"}
    end
  end

  def parse_string(xml, source_name \\ "inline.xml") when is_binary(xml) do
    doc = SweetXml.parse(xml)

    items =
      doc
      |> xpath(~x"/doc/*"l)
      |> Enum.flat_map(&node_to_item/1)

    {:ok,
     %SourceDocument{
       path: source_name,
       title: source_title(items, source_name),
       blocks: build_blocks(items)
     }}
  rescue
    error -> {:error, "Failed to parse #{source_name}: #{Exception.message(error)}"}
  end

  def statements_for_documents(documents) when is_list(documents) do
    thesis_iri = Id.iri(Id.generate())
    sequence_iri = Id.iri(Id.generate())
    {child_iris, child_statements} = materialize_blocks(root_blocks_for_documents(documents))

    [
      statement(thesis_iri, [
        {"a", [term(SheafNS.Document), term(SheafNS.Thesis)]},
        {term(SheafNS.title()), [Fuseki.literal(thesis_title(documents))]},
        {term(SheafNS.children()), [Fuseki.iri_ref(sequence_iri)]}
      ]),
      sequence_statement(sequence_iri, child_iris)
      | child_statements
    ]
  end

  defp node_to_item(node) do
    tag = xpath(node, ~x"name()"s)
    text = node |> xpath(~x"string()"s) |> normalize_text()

    case {tag, text} do
      {"p", ""} -> []
      {"p", value} -> [%{type: :paragraph, text: value}]
      {"h1", ""} -> []
      {"h1", value} -> [%{type: :heading, level: 1, text: value}]
      {"h2", ""} -> []
      {"h2", value} -> [%{type: :heading, level: 2, text: value}]
      {"h3", ""} -> []
      {"h3", value} -> [%{type: :heading, level: 3, text: value}]
      _ -> []
    end
  end

  defp source_title(items, source_name) do
    leading_paragraph_title(items) || first_heading_title(items) || fallback_title(source_name)
  end

  defp leading_paragraph_title(items) do
    items
    |> Enum.take_while(&(&1.type != :heading))
    |> Enum.filter(&(&1.type == :paragraph))
    |> Enum.map(& &1.text)
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp first_heading_title(items) do
    items
    |> Enum.find(&(&1.type == :heading))
    |> case do
      nil -> nil
      heading -> heading.text
    end
  end

  defp fallback_title(source_name) do
    source_name
    |> Path.basename(".xml")
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp build_blocks(items) do
    root = %{level: 0, children: []}

    items
    |> Enum.reduce([root], fn item, stack ->
      case item do
        %{type: :paragraph, text: text} ->
          append_child(stack, {:paragraph, text})

        %{type: :heading, level: level, text: text} ->
          stack
          |> close_sections(level)
          |> then(&[%{level: level, heading: text, children: []} | &1])
      end
    end)
    |> finalize_stack()
    |> hd()
    |> Map.fetch!(:children)
  end

  defp close_sections([root], _level), do: [root]

  defp close_sections([current, parent | rest], level) when current.level >= level do
    close_sections(
      [append_to_container(parent, {:section, current.heading, current.children}) | rest],
      level
    )
  end

  defp close_sections(stack, _level), do: stack

  defp finalize_stack([root]), do: [root]

  defp finalize_stack([current, parent | rest]) do
    finalize_stack([
      append_to_container(parent, {:section, current.heading, current.children}) | rest
    ])
  end

  defp append_child([current | rest], child) do
    [%{current | children: current.children ++ [child]} | rest]
  end

  defp append_to_container(container, child) do
    %{container | children: container.children ++ [child]}
  end

  defp thesis_title([]), do: "Working Thesis"
  defp thesis_title([first | _rest]), do: first.title

  def root_blocks_for_documents(documents) when is_list(documents) do
    [primary, meanings, skills | _rest] = documents ++ [nil, nil, nil]

    primary_sections = restructure_primary_document(primary)

    [
      primary_sections[:front_matter],
      primary_sections[:introduction],
      primary_sections[:chapter_2],
      primary_sections[:chapter_3],
      chapter_section(meanings, "4."),
      chapter_section(skills, "5."),
      primary_sections[:literature]
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp restructure_primary_document(nil), do: %{}

  defp restructure_primary_document(%SourceDocument{blocks: blocks}) do
    {front_matter, remaining} = Enum.split_while(blocks, &match?({:paragraph, _}, &1))

    Enum.reduce(remaining, %{front_matter: front_matter_section(front_matter)}, fn block, acc ->
      case block do
        {:section, "TABLE OF CONTENTS", _children} ->
          acc

        {:section, "INTRODUCTION", _children} = section ->
          Map.put(acc, :introduction, section)

        {:section, <<"2.", _::binary>>, _children} = section ->
          Map.put(acc, :chapter_2, section)

        {:section, <<"3.", _::binary>>, _children} = section ->
          Map.put(acc, :chapter_3, section)

        {:section, "LITERATURE", _children} = section ->
          Map.put(acc, :literature, section)

        {:section, "PIEVIENOT", _children} = section ->
          attach_notes_section(acc, section)

        _other ->
          acc
      end
    end)
  end

  defp attach_notes_section(acc, notes_section) do
    cond do
      Map.has_key?(acc, :chapter_3) and not Map.has_key?(acc, :literature) ->
        Map.update!(acc, :chapter_3, &append_child_section(&1, notes_section))

      Map.has_key?(acc, :literature) and Map.has_key?(acc, :chapter_3) ->
        Map.update!(acc, :chapter_3, &append_child_section(&1, notes_section))

      Map.has_key?(acc, :chapter_2) ->
        Map.update!(acc, :chapter_2, &append_child_section(&1, notes_section))

      true ->
        acc
    end
  end

  defp front_matter_section([]), do: nil
  defp front_matter_section(paragraphs), do: {:section, "Front Matter", paragraphs}

  defp chapter_section(nil, _prefix), do: nil

  defp chapter_section(%SourceDocument{} = document, prefix) do
    {:section, prefix <> " " <> document.title, unwrap_document_blocks(document)}
  end

  defp unwrap_document_blocks(%SourceDocument{
         title: title,
         blocks: [{:section, heading, children}]
       })
       when heading == title do
    children
  end

  defp unwrap_document_blocks(%SourceDocument{blocks: blocks}), do: blocks

  defp append_child_section({:section, heading, children}, child_section) do
    {:section, heading, children ++ [child_section]}
  end

  defp materialize_blocks(blocks) do
    blocks
    |> Enum.map(&materialize_block/1)
    |> Enum.unzip()
    |> then(fn {iris, statement_lists} -> {iris, List.flatten(statement_lists)} end)
  end

  defp materialize_block({:paragraph, text}) do
    block_iri = Id.iri(Id.generate())
    paragraph_iri = Id.iri(Id.generate())

    {block_iri,
     [
       statement(block_iri, [
         {"a", [term(SheafNS.ParagraphBlock)]},
         {term(SheafNS.paragraph()), [Fuseki.iri_ref(paragraph_iri)]}
       ]),
       statement(paragraph_iri, [
         {"a", [term(SheafNS.Paragraph), term(Prov.entity())]},
         {term(SheafNS.text()), [Fuseki.literal(text)]}
       ])
     ]}
  end

  defp materialize_block({:section, heading, children}) do
    section_iri = Id.iri(Id.generate())
    sequence_iri = Id.iri(Id.generate())
    {child_iris, child_statements} = materialize_blocks(children)

    {section_iri,
     [
       statement(section_iri, [
         {"a", [term(SheafNS.Section)]},
         {term(SheafNS.heading()), [Fuseki.literal(heading)]},
         {term(SheafNS.children()), [Fuseki.iri_ref(sequence_iri)]}
       ]),
       sequence_statement(sequence_iri, child_iris)
       | child_statements
     ]}
  end

  defp maybe_clear_graph(false), do: :ok
  defp maybe_clear_graph(true), do: Fuseki.update("CLEAR SILENT GRAPH #{Fuseki.graph_ref()}")

  defp insert_batches(statements, _max_update_bytes) when statements == [], do: {:ok, 0}

  defp insert_batches(statements, max_update_bytes) do
    statements
    |> chunk_statements(max_update_bytes)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, inserted} ->
      update = """
      PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

      INSERT DATA {
        GRAPH #{Fuseki.graph_ref()} {
          #{Enum.join(chunk, "\n\n")}
        }
      }
      """

      case Fuseki.update(update) do
        :ok -> {:cont, {:ok, inserted + length(chunk)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp chunk_statements(statements, max_update_bytes) do
    {chunks, current_chunk, _current_size} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {chunks, current_chunk, current_size} ->
        statement_size = byte_size(statement) + 2

        if current_chunk != [] and current_size + statement_size > max_update_bytes do
          {[Enum.reverse(current_chunk) | chunks], [statement], statement_size}
        else
          {chunks, [statement | current_chunk], current_size + statement_size}
        end
      end)

    chunks =
      if current_chunk == [] do
        chunks
      else
        [Enum.reverse(current_chunk) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp sequence_statement(sequence_iri, child_iris) do
    statement(sequence_iri, [
      {"a", ["rdf:Seq"]}
      | Enum.with_index(child_iris, 1)
        |> Enum.map(fn {child_iri, index} ->
          {"rdf:_#{index}", [Fuseki.iri_ref(child_iri)]}
        end)
    ])
  end

  defp statement(subject, predicate_objects) do
    body =
      predicate_objects
      |> Enum.map(fn {predicate, objects} -> "#{predicate} #{Enum.join(objects, ", ")}" end)
      |> Enum.join(" ;\n  ")

    "#{Fuseki.iri_ref(subject)} #{body} ."
  end

  defp term(iri), do: Fuseki.iri_ref(iri)

  defp normalize_text(text) do
    text
    |> String.replace("\uFEFF", "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
