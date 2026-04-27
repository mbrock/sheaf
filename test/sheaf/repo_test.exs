defmodule Sheaf.RepoTest do
  use ExUnit.Case, async: true
  use RDF

  @tag :tmp_dir
  test "starts a named quadlog with workspace and metadata loaded", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "repo.sqlite3")
    workspace_graph = RDF.iri(Sheaf.Repo.workspace_graph())
    metadata_graph = RDF.iri(Sheaf.Repo.metadata_graph())
    workspace = {~I<https://example.com/workspace>, ~I<https://example.com/p>, "workspace"}
    metadata = {~I<https://example.com/work>, ~I<https://example.com/p>, "metadata"}
    document = {~I<https://example.com/document>, ~I<https://example.com/p>, "document"}

    {:ok, log} = Quadlog.start_link(path)
    assert :ok = Quadlog.assert(log, "tx-1", RDF.Graph.new(workspace, name: workspace_graph))
    assert :ok = Quadlog.assert(log, "tx-2", RDF.Graph.new(metadata, name: metadata_graph))
    assert :ok = Quadlog.assert(log, "tx-3", RDF.Graph.new(document, name: elem(document, 0)))
    GenServer.stop(log)

    start_supervised!({Sheaf.Repo, path: path})

    assert RDF.Data.include?(Sheaf.Repo.dataset(), Tuple.append(workspace, workspace_graph))
    assert RDF.Data.include?(Sheaf.Repo.dataset(), Tuple.append(metadata, metadata_graph))
    refute RDF.Data.include?(Sheaf.Repo.dataset(), Tuple.append(document, elem(document, 0)))
  end
end
