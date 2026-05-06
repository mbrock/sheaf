defmodule Sheaf.RepoTest do
  use ExUnit.Case, async: false
  use RDF

  @tag :tmp_dir
  test "starts a named quadlog with workspace and metadata loaded", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "repo.sqlite3")
    workspace_graph = RDF.iri(Sheaf.Repo.workspace_graph())
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    workspace =
      {~I<https://example.com/workspace>, ~I<https://example.com/p>,
       "workspace"}

    metadata =
      {~I<https://example.com/work>, ~I<https://example.com/p>, "metadata"}

    document =
      {~I<https://example.com/document>, ~I<https://example.com/p>,
       "document"}

    {:ok, log} = Quadlog.start_link(path)

    assert :ok =
             Quadlog.assert(
               log,
               "tx-1",
               RDF.Graph.new(workspace, name: workspace_graph)
             )

    assert :ok =
             Quadlog.assert(
               log,
               "tx-2",
               RDF.Graph.new(metadata, name: metadata_graph)
             )

    assert :ok =
             Quadlog.assert(
               log,
               "tx-3",
               RDF.Graph.new(document, name: elem(document, 0))
             )

    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(workspace, workspace_graph)
           )

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(metadata, metadata_graph)
           )

    refute RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(document, elem(document, 0))
           )
  end

  @tag :tmp_dir
  test "clears opportunistic cache while keeping core graphs loaded", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "repo.sqlite3")
    workspace_graph = RDF.iri(Sheaf.Repo.workspace_graph())
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())

    workspace =
      {~I<https://example.com/workspace>, ~I<https://example.com/p>,
       "workspace"}

    metadata =
      {~I<https://example.com/work>, ~I<https://example.com/p>, "metadata"}

    document_graph = ~I<https://example.com/document>

    document =
      {~I<https://example.com/document>, ~I<https://example.com/p>,
       "document"}

    {:ok, log} = Quadlog.start_link(path)

    assert :ok =
             Quadlog.assert(
               log,
               "tx-1",
               RDF.Graph.new(workspace, name: workspace_graph)
             )

    assert :ok =
             Quadlog.assert(
               log,
               "tx-2",
               RDF.Graph.new(metadata, name: metadata_graph)
             )

    assert :ok =
             Quadlog.assert(
               log,
               "tx-3",
               RDF.Graph.new(document, name: document_graph)
             )

    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(workspace, workspace_graph)
           )

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(metadata, metadata_graph)
           )

    assert :ok = Sheaf.Repo.load_once({nil, nil, nil, document_graph})

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(document, document_graph)
           )

    assert :ok = Sheaf.Repo.clear_cache()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(workspace, workspace_graph)
           )

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(metadata, metadata_graph)
           )

    refute RDF.Data.include?(
             Sheaf.Repo.dataset(),
             Tuple.append(document, document_graph)
           )
  end

  @tag :tmp_dir
  test "write helpers mint transaction ids", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "repo.sqlite3")

    graph =
      RDF.Graph.new(
        {~I<https://example.com/s>, ~I<https://example.com/p>, "value"}
      )

    start_supervised!({Sheaf.Repo, path: path})

    assert :ok = Sheaf.Repo.assert(graph)
    assert :ok = Sheaf.Repo.retract(graph)
    assert :ok = Sheaf.Repo.transact([{:assert, graph}])

    assert {txs, 3} =
             Sheaf.Repo.ask(fn _dataset ->
               {:ok, conn} = Exqlite.start_link(database: path)

               {:ok, result} =
                 Exqlite.query(
                   conn,
                   "SELECT DISTINCT tx FROM changes ORDER BY tx"
                 )

               txs = Enum.map(result.rows, fn [tx] -> tx end)
               {txs, length(txs)}
             end)

    resource_base = Application.fetch_env!(:sheaf, :resource_base)
    assert Enum.all?(txs, &String.starts_with?(&1, resource_base))
  end
end
