defmodule Sheaf.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "creates and reuses the default workspace in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    assert workspace = Sheaf.Workspace.default()
    assert ^workspace = Sheaf.Workspace.default()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), RDF.type(), DOC.Workspace, RDF.iri(Sheaf.Workspace.graph())}
           )
  end

  @tag :tmp_dir
  test "loads the default workspace after the Repo cache is cleared", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    workspace = Sheaf.Workspace.default()
    assert :ok = Sheaf.Repo.clear_cache()

    assert ^workspace = Sheaf.Workspace.default()
  end

  @tag :tmp_dir
  test "sets and clears document exclusions in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    document = Id.iri("DOC999")
    assert :ok = Sheaf.Workspace.set_document_excluded("DOC999", true)
    workspace = Sheaf.Workspace.default()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), DOC.excludesDocument(), document,
              RDF.iri(Sheaf.Workspace.graph())}
           )

    assert :ok = Sheaf.Workspace.set_document_excluded("DOC999", false)

    refute RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), DOC.excludesDocument(), document,
              RDF.iri(Sheaf.Workspace.graph())}
           )
  end

  defp start_repo!(tmp_dir) do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})
  end
end
