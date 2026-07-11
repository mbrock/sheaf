defmodule Sheaf.DocumentMentionsTest do
  use ExUnit.Case, async: true
  use RDF

  alias Sheaf.DocumentMentions
  alias Sheaf.NS.{AS, DOC}

  test "groups direct and block mentions into distinct document contexts" do
    note = ~I<https://example.com/NOTE01>
    session = ~I<https://example.com/CHAT01>
    document = ~I<https://example.com/DOC001>
    block = ~I<https://example.com/BLK001>

    graph =
      RDF.Graph.new([
        {note, RDF.type(), DOC.ResearchNote},
        {note, RDF.NS.RDFS.label(), "A useful synthesis"},
        {note, AS.context(), session},
        {note, AS.published(), ~U[2026-07-12 10:00:00Z]},
        {note, DOC.mentions(), document},
        {note, DOC.mentions(), block}
      ])

    assert %{
             "DOC001" => [
               %{
                 id: "CHAT01",
                 path: "/CHAT01",
                 title: "A useful synthesis",
                 mention_count: 1
               } = mention
             ]
           } =
             DocumentMentions.from_graph(
               graph,
               MapSet.new(["DOC001"]),
               %{"BLK001" => "DOC001"}
             )

    assert mention.published_at == ~U[2026-07-12 10:00:00Z]
  end
end
