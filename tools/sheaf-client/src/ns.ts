export const RDF = {
  type: "http://www.w3.org/1999/02/22-rdf-syntax-ns#type",
  first: "http://www.w3.org/1999/02/22-rdf-syntax-ns#first",
  rest: "http://www.w3.org/1999/02/22-rdf-syntax-ns#rest",
  nil: "http://www.w3.org/1999/02/22-rdf-syntax-ns#nil",
}

export const RDFS = {
  label: "http://www.w3.org/2000/01/rdf-schema#label",
}

export const SHEAF = {
  base: "https://less.rest/sheaf/",
  resourceBase: "https://sheaf.less.rest/",
  metadataGraph: "https://less.rest/sheaf/metadata",
  Document: "https://less.rest/sheaf/Document",
  Thesis: "https://less.rest/sheaf/Thesis",
  Paper: "https://less.rest/sheaf/Paper",
  Transcript: "https://less.rest/sheaf/Transcript",
  Spreadsheet: "https://less.rest/sheaf/Spreadsheet",
  Section: "https://less.rest/sheaf/Section",
  ParagraphBlock: "https://less.rest/sheaf/ParagraphBlock",
  ExtractedBlock: "https://less.rest/sheaf/ExtractedBlock",
  Row: "https://less.rest/sheaf/Row",
  children: "https://less.rest/sheaf/children",
  paragraph: "https://less.rest/sheaf/paragraph",
  text: "https://less.rest/sheaf/text",
  sourceHtml: "https://less.rest/sheaf/sourceHtml",
  sourcePage: "https://less.rest/sheaf/sourcePage",
  sourceKey: "https://less.rest/sheaf/sourceKey",
}

export const DCTERMS = {
  creator: "http://purl.org/dc/terms/creator",
  isPartOf: "http://purl.org/dc/terms/isPartOf",
  publisher: "http://purl.org/dc/terms/publisher",
  title: "http://purl.org/dc/terms/title",
}

export const BIBO = {
  numPages: "http://purl.org/ontology/bibo/numPages",
  status: "http://purl.org/ontology/bibo/status",
}

export const CITO = {
  cites: "http://purl.org/spar/cito/cites",
}

export const FABIO = {
  Book: "http://purl.org/spar/fabio/Book",
  BookChapter: "http://purl.org/spar/fabio/BookChapter",
  DoctoralThesis: "http://purl.org/spar/fabio/DoctoralThesis",
  JournalArticle: "http://purl.org/spar/fabio/JournalArticle",
  ScholarlyWork: "http://purl.org/spar/fabio/ScholarlyWork",
  hasIssueIdentifier: "http://purl.org/spar/fabio/hasIssueIdentifier",
  hasPageRange: "http://purl.org/spar/fabio/hasPageRange",
  hasPublicationYear: "http://purl.org/spar/fabio/hasPublicationYear",
  hasVolumeIdentifier: "http://purl.org/spar/fabio/hasVolumeIdentifier",
  isRepresentationOf: "http://purl.org/spar/fabio/isRepresentationOf",
}

export const FOAF = {
  name: "http://xmlns.com/foaf/0.1/name",
}
