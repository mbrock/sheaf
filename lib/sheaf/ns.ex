defmodule Sheaf.NS do
  use RDF.Vocabulary.Namespace

  defvocab Sheaf,
    base_iri: "https://example.com/sheaf/",
    terms: [
      :Document,
      :Thesis,
      :Transcript,
      :Section,
      :Paragraph,
      :children,
      :heading,
      :text,
      :title
    ]
end
