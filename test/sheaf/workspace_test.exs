defmodule Sheaf.WorkspaceTest do
  use ExUnit.Case, async: false

  alias Sheaf.Id
  alias Sheaf.NS.DOC
  alias RDF.NS.RDFS

  @tag :tmp_dir
  test "creates and reuses the default workspace in Repo", %{tmp_dir: tmp_dir} do
    start_repo!(tmp_dir)

    assert workspace = Sheaf.Workspace.default()
    assert ^workspace = Sheaf.Workspace.default()

    assert RDF.Data.include?(
             Sheaf.Repo.dataset(),
             {RDF.iri(workspace), RDF.type(), DOC.Workspace,
              RDF.iri(Sheaf.Workspace.graph())}
           )
  end

  @tag :tmp_dir
  test "loads the default workspace after the Repo cache is cleared", %{
    tmp_dir: tmp_dir
  } do
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

  @tag :tmp_dir
  test "places documents in reusable flat folders and clears them", %{
    tmp_dir: tmp_dir
  } do
    start_repo!(tmp_dir)

    assert :ok =
             Sheaf.Workspace.set_document_folder("DOC999", "Trail systems")

    assert :ok =
             Sheaf.Workspace.set_document_folder("DOC888", "Trail systems")

    graph =
      Sheaf.Repo.ask(&RDF.Dataset.graph(&1, Sheaf.Workspace.graph()))

    folders =
      graph
      |> RDF.Graph.triples()
      |> Enum.flat_map(fn
        {folder, predicate, object} ->
          if predicate == RDF.type() and object == RDF.iri(DOC.Folder),
            do: [folder],
            else: []
      end)

    assert [folder] = folders
    assert RDF.Data.include?(graph, {folder, RDFS.label(), "Trail systems"})

    assert RDF.Data.include?(
             graph,
             {Id.iri("DOC999"), DOC.inFolder(), folder}
           )

    assert RDF.Data.include?(
             graph,
             {Id.iri("DOC888"), DOC.inFolder(), folder}
           )

    assert :ok = Sheaf.Workspace.set_document_folder("DOC999", "")

    refute RDF.Data.include?(
             graph = current_workspace_graph(),
             {Id.iri("DOC999"), DOC.inFolder(), folder}
           )

    assert RDF.Data.include?(
             graph,
             {Id.iri("DOC888"), DOC.inFolder(), folder}
           )
  end

  defp start_repo!(tmp_dir) do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})
  end

  defp current_workspace_graph do
    Sheaf.Repo.ask(&RDF.Dataset.graph(&1, Sheaf.Workspace.graph()))
  end
end
