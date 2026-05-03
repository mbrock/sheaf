defmodule Sheaf.AdminTest do
  use ExUnit.Case, async: false
  use RDF

  import ExUnit.CaptureIO

  @tag :tmp_dir
  test "backs up the quadlog sqlite database directly", %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo.sqlite3")
    backup_path = Path.join(tmp_dir, "backup.sqlite3")

    start_supervised!({Sheaf.Repo, path: repo_path})

    graph =
      RDF.Graph.new(
        {~I<https://example.com/subject>, ~I<https://example.com/predicate>, "value"},
        name: RDF.iri(Sheaf.Repo.workspace_graph())
      )

    assert :ok = Sheaf.Repo.assert("test tx", graph)

    assert capture_io(fn -> Sheaf.Admin.backup(["--output", backup_path]) end) =~
             "Backed up the Quadlog dataset"

    assert File.exists?(backup_path)

    {:ok, conn} = Exqlite.start_link(database: backup_path)
    {:ok, result} = Exqlite.query(conn, "SELECT COUNT(*) FROM quads")

    assert [[1]] = result.rows
  end
end
