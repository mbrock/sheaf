defmodule Sheaf.NS do
  use RDF.Vocabulary.Namespace

  defvocab(SHEAF,
    base_iri: "https://less.rest/sheaf/",
    terms: [
      :AudioBlob,
      :Block,
      :Document,
      :Interview,
      :ParagraphBlock,
      :Thesis,
      :Transcript,
      :Section,
      :Segment,
      :Paragraph,
      :Utterance,
      :audio,
      :children,
      :contextSegments,
      :currentPosition,
      :duration,
      :endTime,
      :filename,
      :heading,
      :mimeType,
      :modelName,
      :paragraph,
      :sourceKey,
      :speaker,
      :startTime,
      :text,
      :title
    ]
  )
end
