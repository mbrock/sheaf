defmodule Sheaf.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "creates and reuses the default workspace in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    assert {:ok, workspace} = Sheaf.Workspace.ensure_default()
    assert {:ok, ^workspace} = Sheaf.Workspace.ensure_default()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), RDF.type(), DOC.Workspace, RDF.iri(Sheaf.Workspace.graph())}
           )
  end

  @tag :tmp_dir
  test "sets and clears document exclusions in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    document = Id.iri("DOC999")
    assert :ok = Sheaf.Workspace.set_document_excluded("DOC999", true)
    {:ok, workspace} = Sheaf.Workspace.ensure_default()

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

  @tag :tmp_dir
  test "replaces workspace owner in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    first = Id.iri("OWNER1")
    second = Id.iri("OWNER2")

    assert :ok = Sheaf.Workspace.set_owner("OWNER1")
    {:ok, workspace} = Sheaf.Workspace.ensure_default()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), DOC.hasWorkspaceOwner(), first,
              RDF.iri(Sheaf.Workspace.graph())}
           )

    assert :ok = Sheaf.Workspace.set_owner("OWNER2")

    refute RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), DOC.hasWorkspaceOwner(), first,
              RDF.iri(Sheaf.Workspace.graph())}
           )

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), DOC.hasWorkspaceOwner(), second,
              RDF.iri(Sheaf.Workspace.graph())}
           )
  end

  defp start_repo!(tmp_dir) do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})
  end
end
