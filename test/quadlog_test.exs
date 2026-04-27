defmodule QuadlogTest do
  use ExUnit.Case, async: true
  use RDF

  @tag :tmp_dir
  test "persists and replays RDF dataset changes", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    graph_name = ~I<https://example.com/graph>
    alice = ~I<https://example.com/alice>
    bob = ~I<https://example.com/bob>
    blank = RDF.bnode("someone")

    graph =
      RDF.Graph.new(
        [
          {alice, ~I<https://example.com/knows>, bob},
          {alice, ~I<https://example.com/name>, RDF.literal("Alice", language: "en")},
          {blank, ~I<https://example.com/age>, RDF.literal(42)}
        ],
        name: graph_name
      )

    {:ok, log} = Quadlog.start_link(path)

    assert :ok = Quadlog.assert(log, "tx-1", graph)

    assert RDF.Data.include?(
             Quadlog.dataset(log),
             {alice, ~I<https://example.com/name>, RDF.literal("Alice", language: "en"),
              graph_name}
           )

    GenServer.stop(log)

    {:ok, log} = Quadlog.start_link(path)

    assert RDF.Graph.isomorphic?(
             RDF.Dataset.graph(Quadlog.dataset(log), graph_name),
             graph
           )
  end

  @tag :tmp_dir
  test "asks questions against the current dataset", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    triple = {~I<https://example.com/s>, ~I<https://example.com/p>, "first"}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.graph(triple))

    assert [{elem(triple, 0), elem(triple, 1), RDF.literal("first")}] ==
             Quadlog.ask(log, fn dataset -> RDF.Dataset.triples(dataset) end)
  end

  @tag :tmp_dir
  test "transacts from a function of the current dataset", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    first = {~I<https://example.com/s>, ~I<https://example.com/p>, "first"}
    second = {~I<https://example.com/s>, ~I<https://example.com/p>, "second"}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.graph(first))

    assert :ok =
             Quadlog.transact(log, "tx-2", fn dataset ->
               if RDF.Data.include?(dataset, first) do
                 [{:assert, RDF.graph(second)}]
               else
                 []
               end
             end)

    assert RDF.Data.include?(Quadlog.dataset(log), second)
  end

  @tag :tmp_dir
  test "loads only selected graphs at startup", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    graph_a = ~I<https://example.com/graph-a>
    graph_b = ~I<https://example.com/graph-b>
    triple_a = {~I<https://example.com/a>, ~I<https://example.com/p>, "a"}
    triple_b = {~I<https://example.com/b>, ~I<https://example.com/p>, "b"}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.Graph.new(triple_a, name: graph_a))
    assert :ok = Quadlog.assert(log, "tx-2", RDF.Graph.new(triple_b, name: graph_b))

    GenServer.stop(log)
    {:ok, log} = Quadlog.start_link(path, pattern: {nil, nil, nil, graph_a})

    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_a, graph_a))
    refute RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_b, graph_b))
  end

  @tag :tmp_dir
  test "loads a pattern later", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    graph_a = ~I<https://example.com/graph-a>
    graph_b = ~I<https://example.com/graph-b>
    triple_a = {~I<https://example.com/a>, ~I<https://example.com/p>, "a"}
    triple_b = {~I<https://example.com/b>, ~I<https://example.com/p>, "b"}
    deleted = {~I<https://example.com/deleted>, ~I<https://example.com/p>, "deleted"}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.Graph.new(triple_a, name: graph_a))
    assert :ok = Quadlog.assert(log, "tx-2", RDF.Graph.new([triple_b, deleted], name: graph_b))
    assert :ok = Quadlog.retract(log, "tx-3", RDF.Graph.new(deleted, name: graph_b))

    GenServer.stop(log)
    {:ok, log} = Quadlog.start_link(path, pattern: {nil, nil, nil, graph_a})

    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_a, graph_a))
    refute RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_b, graph_b))

    assert :ok = Quadlog.load(log, {nil, nil, nil, graph_b})

    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_a, graph_a))
    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple_b, graph_b))
    refute RDF.Data.include?(Quadlog.dataset(log), Tuple.append(deleted, graph_b))
  end

  @tag :tmp_dir
  test "load_once memoizes loaded patterns until the cache is cleared", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    graph = ~I<https://example.com/graph>
    triple = {~I<https://example.com/a>, ~I<https://example.com/p>, "a"}
    pattern = {nil, nil, nil, graph}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.Graph.new(triple, name: graph))

    GenServer.stop(log)
    {:ok, log} = Quadlog.start_link(path, pattern: {nil, nil, nil, nil})
    assert :ok = Quadlog.clear_cache(log)

    refute RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple, graph))

    assert :ok = Quadlog.load_once(log, pattern)
    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple, graph))

    assert :ok = Quadlog.clear_cache(log)
    refute RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple, graph))

    assert :ok = Quadlog.load_once(log, pattern)
    assert RDF.Data.include?(Quadlog.dataset(log), Tuple.append(triple, graph))
  end

  @tag :tmp_dir
  test "loads an iri SPOG pattern", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    graph = ~I<https://example.com/graph>
    subject = ~I<https://example.com/s>
    predicate = ~I<https://example.com/p>
    object = ~I<https://example.com/o>
    other = ~I<https://example.com/other>

    {:ok, log} = Quadlog.start_link(path)

    assert :ok =
             Quadlog.assert(
               log,
               "tx-1",
               RDF.Graph.new(
                 [
                   {subject, predicate, object},
                   {subject, predicate, other},
                   {other, predicate, object}
                 ],
                 name: graph
               )
             )

    GenServer.stop(log)
    {:ok, log} = Quadlog.start_link(path, pattern: {subject, predicate, object, nil})

    assert RDF.Data.include?(Quadlog.dataset(log), {subject, predicate, object, graph})
    refute RDF.Data.include?(Quadlog.dataset(log), {subject, predicate, other, graph})
    refute RDF.Data.include?(Quadlog.dataset(log), {other, predicate, object, graph})
  end

  @tag :tmp_dir
  test "retractions remove statements when replayed", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "quadlog.sqlite3")
    triple = {~I<https://example.com/s>, ~I<https://example.com/p>, "first"}

    {:ok, log} = Quadlog.start_link(path)

    assert :ok = Quadlog.assert(log, "tx-1", RDF.graph(triple))
    assert :ok = Quadlog.retract(log, "tx-2", RDF.graph(triple))

    refute RDF.Data.include?(Quadlog.dataset(log), triple)

    GenServer.stop(log)
    {:ok, log} = Quadlog.start_link(path)

    refute RDF.Data.include?(Quadlog.dataset(log), triple)
  end
end
