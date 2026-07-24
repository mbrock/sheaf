defmodule Sheaf.SoftwareProjectsTest do
  use ExUnit.Case, async: false

  alias RDF.NS.RDFS
  alias Sheaf.NS.{DOC, PROV}
  alias Sheaf.SoftwareProjects

  @tag :tmp_dir
  test "lists and describes workspace software projects", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "software-projects.sqlite3")
    start_supervised!({Sheaf.Repo, path: path})

    workspace = Sheaf.Workspace.default()
    workspace_graph = RDF.iri(Sheaf.Workspace.graph())
    project = Sheaf.Id.iri("PROJ01")
    repository = Sheaf.Id.iri("REPO01")
    refs_graph = Sheaf.Id.iri("REFS01")
    text_graph = Sheaf.Id.iri("TEXT01")
    activity = Sheaf.Id.iri("SYNC01")
    commit_one = RDF.iri("#{Sheaf.Id.base_iri()}git/objects/sha1/111111")
    commit_two = RDF.iri("#{Sheaf.Id.base_iri()}git/objects/sha1/222222")
    reference = RDF.iri("#{repository}/refs/heads/main")
    source_file = RDF.iri("#{repository}/source-files/README")
    source_block = RDF.iri("#{source_file}#content")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {workspace, DOC.hasSoftwareProject(), project},
                   {project, RDF.type(), DOC.SoftwareProject},
                   {project, RDFS.label(), "Example engine"},
                   {project, DOC.hasSourceRepository(), repository},
                   {repository, RDF.type(), DOC.GitRepository},
                   {repository, RDFS.label(),
                    "Example engine Git repository"},
                   {repository, DOC.repositoryIdentity(),
                    "remote:https://example.com/engine.git"},
                   {repository, DOC.checkoutPath(), "/work/engine"},
                   {repository, DOC.remoteUrl(),
                    "https://example.com/engine.git"},
                   {repository, DOC.gitObjectFormat(), "sha1"}
                 ],
                 name: workspace_graph
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {commit_one, RDF.type(), DOC.GitObject},
                   {commit_one, RDF.type(), DOC.GitCommit},
                   {commit_one, DOC.inGitRepository(), repository},
                   {commit_one, DOC.gitObjectId(),
                    "1111111111111111111111111111111111111111"},
                   {commit_one, DOC.commitMessage(), "Initial project"},
                   {commit_one, DOC.authorName(), "Ada"},
                   {commit_one, DOC.committedAt(), ~U[2026-07-20 10:00:00Z]},
                   {commit_two, RDF.type(), DOC.GitObject},
                   {commit_two, RDF.type(), DOC.GitCommit},
                   {commit_two, DOC.inGitRepository(), repository},
                   {commit_two, DOC.gitObjectId(),
                    "2222222222222222222222222222222222222222"},
                   {commit_two, DOC.commitMessage(),
                    "Add renderer\n\nDetails"},
                   {commit_two, DOC.authorName(), "Grace"},
                   {commit_two, DOC.committedAt(), ~U[2026-07-21 10:00:00Z]}
                 ],
                 name: repository
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {repository, DOC.gitHead(), commit_two},
                   {repository, DOC.hasGitReference(), reference},
                   {reference, RDF.type(), DOC.GitReference},
                   {reference, DOC.inGitRepository(), repository},
                   {reference, DOC.gitReferenceName(), "refs/heads/main"},
                   {reference, DOC.pointsToGitObject(), commit_two}
                 ],
                 name: refs_graph
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {source_file, RDF.type(), DOC.GitSourceFile},
                   {source_file, DOC.inGitRepository(), repository},
                   {source_file, DOC.sourcePath(), "README.md"},
                   {source_file, DOC.sourceLanguage(), "Markdown"},
                   {source_file, DOC.hasSourceFileBlock(), source_block}
                 ],
                 name: text_graph
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {activity, RDF.type(), DOC.GitSynchronization},
                   {activity, PROV.used(), repository},
                   {activity, PROV.endedAtTime(), ~U[2026-07-21 10:05:00Z]}
                 ],
                 name: activity
               )
             )

    assert {:ok, [listed]} = SoftwareProjects.list()
    assert listed.id == "PROJ01"

    assert {:ok, loaded} = SoftwareProjects.get("PROJ01")
    assert loaded.title == "Example engine"
    assert loaded.path == "/PROJ01"
    assert loaded.repository.id == "REPO01"
    assert loaded.repository.checkout_path == "/work/engine"
    assert loaded.commit_count == 2
    assert loaded.source_file_count == 1
    assert loaded.reference_count == 1
    assert loaded.head.short_id == "2222222222"

    assert Enum.map(loaded.recent_commits, & &1.message) == [
             "Add renderer\n\nDetails",
             "Initial project"
           ]

    assert [%{display_name: "main", head?: true}] = loaded.head_references

    assert [%{path: "README.md", language: "Markdown"}] =
             loaded.source_files

    assert loaded.synchronized_at == ~U[2026-07-21 10:05:00Z]
    assert {:error, :not_found} = SoftwareProjects.get("ABSENT")
  end
end
