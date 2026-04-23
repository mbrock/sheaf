defmodule Sheaf.InterviewsTest do
  use ExUnit.Case, async: true

  alias Sheaf.Interviews
  alias Sheaf.Interviews.{Interview, Segment, Utterance}

  test "statements_for projects interviews into ordered RDF resources" do
    interviews = [
      %Interview{
        id: "1",
        source_key: "1",
        filename: "FGD_7 22.01.m4a",
        audio_hash: "hash-root",
        duration: "02:20:21",
        current_position: "02:20:49",
        context_segments: 1,
        model_name: "gemini-2.0-flash-exp",
        segments: [
          %Segment{
            index: 1,
            start_time: "00:00:00",
            end_time: "00:02:00",
            audio_hash: "hash-segment",
            utterances: [
              %Utterance{
                index: 1,
                speaker: "S1",
                text: "Opening line.",
                audio_hash: "hash-segment"
              },
              %Utterance{
                index: 2,
                speaker: "S2",
                text: "Response line.",
                audio_hash: nil
              }
            ]
          }
        ]
      }
    ]

    statements = Interviews.statements_for(interviews)
    joined = Enum.join(statements, "\n")

    assert Enum.any?(
             statements,
             &String.starts_with?(&1, "<https://example.com/sheaf/audio/hash-root>")
           )

    assert Enum.any?(
             statements,
             &String.starts_with?(&1, "<https://example.com/sheaf/audio/hash-segment>")
           )

    assert String.contains?(joined, "<https://example.com/sheaf/interviews/1>")
    assert String.contains?(joined, "<https://example.com/sheaf/interviews/1/children>")
    assert String.contains?(joined, "rdf:_1 <https://example.com/sheaf/interviews/1/segments/1>")

    assert String.contains?(
             joined,
             "<https://example.com/sheaf/interviews/1/segments/1/children>"
           )

    assert String.contains?(
             joined,
             "rdf:_2 <https://example.com/sheaf/interviews/1/segments/1/utterances/2>"
           )

    assert String.contains?(joined, ~s("Opening line."))
    assert String.contains?(joined, ~s("S2"))
    assert String.contains?(joined, "https://less.rest/sheaf/Interview")
    assert String.contains?(joined, "https://less.rest/sheaf/Utterance")
    assert String.contains?(joined, "https://less.rest/sheaf/ParagraphBlock")
    assert String.contains?(joined, "https://less.rest/sheaf/paragraph")
  end
end
