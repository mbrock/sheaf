defmodule Sheaf.SampleData do
  @moduledoc """
  Minimal sample thesis data for the first milestone.
  """

  alias SPARQL.Query.Result
  alias Sheaf.Fuseki
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS

  @sample_outline [
    {:section, "Introduction",
     [
       {:paragraph,
        "This workspace is for a master's thesis drafted as addressable blocks."},
       {:section, "Research Questions",
        [
          {:paragraph,
           "The first milestone is a readable outline fetched directly from Fuseki via SPARQL."}
        ]},
       {:paragraph,
        "Later milestones can add provenance, annotation, and relational structure without replacing the current block identities."}
     ]},
    {:section, "Method",
     [
       {:paragraph,
        "Each container stores its ordering in an rdf:Seq, while paragraphs remain leaf blocks with plain text content."}
     ]},
    {:section, "Working Notes",
     [
       {:paragraph,
        "This sample document only exists to prove the rendering path end to end."}
     ]}
  ]

  def seed_sample_thesis do
    case thesis_exists?() do
      {:ok, true} -> {:ok, :already_present}
      {:ok, false} -> insert_sample_thesis()
      error -> error
    end
  end

  def thesis_exists? do
    query = """
    ASK {
      GRAPH #{Fuseki.graph_ref()} {
        ?document a #{Fuseki.iri_ref(SheafNS.Thesis)} .
      }
    }
    """

    case Fuseki.ask(query) do
      {:ok, %Result{} = result} -> {:ok, Fuseki.ok_boolean?(result)}
      error -> error
    end
  end

  def insert_sample_thesis do
    document_id = Id.generate()
    document_iri = Id.iri(document_id)
    sequence_iri = Id.iri(Id.generate())
    {child_iris, child_statements} = materialize_blocks(@sample_outline)

    statements =
      [
        statement(document_iri, [
          {"a", [term(SheafNS.Document), term(SheafNS.Thesis)]},
          {term(SheafNS.title()), [Fuseki.literal("Working Thesis")]},
          {term(SheafNS.children()), [Fuseki.iri_ref(sequence_iri)]}
        ]),
        sequence_statement(sequence_iri, child_iris)
      ] ++ child_statements

    update = """
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

    INSERT DATA {
      GRAPH #{Fuseki.graph_ref()} {
        #{Enum.join(statements, "\n\n")}
      }
    }
    """

    case Fuseki.update(update) do
      :ok -> {:ok, document_iri}
      error -> error
    end
  end

  defp materialize_blocks(blocks) do
    blocks
    |> Enum.map(&materialize_block/1)
    |> Enum.unzip()
    |> then(fn {iris, statement_lists} -> {iris, List.flatten(statement_lists)} end)
  end

  defp materialize_block({:paragraph, text}) do
    paragraph_iri = Id.iri(Id.generate())

    {paragraph_iri,
     [
       statement(paragraph_iri, [
         {"a", [term(SheafNS.Paragraph)]},
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
end
