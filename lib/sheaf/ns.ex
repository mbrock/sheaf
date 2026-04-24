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

  defvocab(AS,
    base_iri: "https://www.w3.org/ns/activitystreams#",
    terms: [
      :Application,
      :Note,
      :content,
      :context,
      :published,
      attributed_to: "attributedTo"
    ]
  )

  defvocab(PROV,
    base_iri: "http://www.w3.org/ns/prov#",
    file: "../prov-o.ttl",
    terms: [
      :Entity,
      :SoftwareAgent,
      was_invalidated_by: "wasInvalidatedBy",
      was_revision_of: "wasRevisionOf"
    ]
  )

  defvocab(BIBO,
    base_iri: "http://purl.org/ontology/bibo/",
    terms: ~w[
      Journal
      doi
      issn
      pageEnd
      pageStart
      volume
    ]
  )

  defvocab(DCTERMS,
    base_iri: "http://purl.org/dc/terms/",
    terms: ~w[
      creator
      date
      identifier
      isPartOf
      publisher
      title
    ]
  )

  defvocab(DOI,
    base_iri: "http://dx.doi.org/",
    terms: [],
    strict: false
  )

  defvocab(FABIO,
    base_iri: "http://purl.org/spar/fabio/",
    terms: ~w[
      Book
      BookChapter
      ComputerFile
      DoctoralThesis
      JournalArticle
      PositionPaper
      ResearchPaper
      ScholarlyWork
      hasDOI
      hasIssueIdentifier
      hasPageRange
      hasPublicationYear
      hasVolumeIdentifier
      isPortrayalOf
      isRepresentationOf
    ]
  )

  defvocab(FOAF,
    base_iri: "http://xmlns.com/foaf/0.1/",
    terms: ~w[
      Organization
      Person
      familyName
      givenName
      name
    ]
  )

  defvocab(FRBR,
    base_iri: "http://purl.org/vocab/frbr/core#",
    terms: ~w[
      exemplarOf
      partOf
      realizationOf
    ]
  )

  defvocab(PRISM,
    base_iri: "http://prismstandard.org/namespaces/basic/2.1/",
    terms: ~w[
      doi
      endingPage
      issn
      issueIdentifier
      startingPage
      volume
    ]
  )
end
