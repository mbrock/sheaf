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
    file: "../activitystreams2.ttl"
  )

  defvocab(CSVW,
    base_iri: "http://www.w3.org/ns/csvw#",
    terms: ~w[
      Column
      Schema
      Table
      TableGroup
      column
      datatype
      name
      table
      tableSchema
      title
    ]
  )

  defvocab(DCAT,
    base_iri: "http://www.w3.org/ns/dcat#",
    terms: ~w[
      Dataset
      Distribution
      byteSize
      distribution
      mediaType
    ]
  )

  defvocab(PROV,
    base_iri: "http://www.w3.org/ns/prov#",
    file: "../prov-o.ttl"
  )

  defvocab(BFO,
    base_iri: "https://node.town/bfo#",
    file: "../sheaf-ext.ttl"
  )

  defvocab(BIBO,
    base_iri: "http://purl.org/ontology/bibo/",
    terms: ~w[
      Journal
      doi
      degree
      isbn
      issn
      numPages
      pageEnd
      pageStart
      volume
    ]
  )

  defvocab(BIRO,
    base_iri: "http://purl.org/spar/biro/",
    terms: ~w[
      BibliographicReference
      ReferenceList
      references
    ]
  )

  defvocab(CITO,
    base_iri: "http://purl.org/spar/cito/",
    terms: ~w[
      cites
    ]
  )

  defvocab(CO,
    base_iri: "http://purl.org/co/",
    terms: ~w[
      Collection
      Set
      element
      elementOf
    ]
  )

  defvocab(DCTERMS,
    base_iri: "http://purl.org/dc/terms/",
    terms: ~w[
      creator
      date
      format
      identifier
      isPartOf
      publisher
      title
    ]
  )

  defvocab(DEO,
    base_iri: "http://purl.org/spar/deo/",
    terms: ~w[
      BibliographicReference
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
