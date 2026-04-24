defmodule Sheaf.NS do
  @moduledoc """
  RDF vocabularies used by Sheaf.
  """

  use RDF.Vocabulary.Namespace
  require RDF.Turtle

  defvocab(DOC,
    base_iri: "https://less.rest/sheaf/",
    file: "../sheaf-schema.ttl"
  )

  defvocab(PROV,
    base_iri: "http://www.w3.org/ns/prov#",
    file: "../prov-o.ttl",
    terms: [
      :Entity,
      was_invalidated_by: "wasInvalidatedBy",
      was_revision_of: "wasRevisionOf"
    ]
  )
end
