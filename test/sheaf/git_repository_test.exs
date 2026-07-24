defmodule Sheaf.Git.RepositoryTest do
  use ExUnit.Case, async: true

  alias Sheaf.Git.RDF, as: GitRDF
  alias Sheaf.Git.Repository
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "reads standard Git history and materializes one block per HEAD file",
       %{
         tmp_dir: tmp_dir
       } do
    repository = git_fixture!(tmp_dir)

    assert {:ok, snapshot} = Repository.snapshot(repository)

    assert snapshot.identity == "remote:https://example.com/moppe.git"
    assert snapshot.object_format == "sha1"
    assert snapshot.head
    assert Enum.any?(snapshot.refs, &(&1.name == "refs/heads/main"))
    assert Enum.any?(snapshot.refs, &(&1.name == "refs/heads/feature"))

    refute Enum.any?(
             snapshot.refs,
             &String.starts_with?(&1.name, "refs/codex/")
           )

    assert Enum.any?(snapshot.commits, fn {_oid, commit} ->
             length(commit.parents) == 2 and commit.message == "Merge feature"
           end)

    assert Enum.any?(snapshot.trees, fn {_oid, tree} ->
             Enum.any?(tree.entries, &(&1.name == "README.md"))
           end)

    assert [%{text: readme_text}] =
             Enum.filter(snapshot.source_files, &(&1.path == "README.md"))

    assert readme_text ==
             "# A small repository\n\nOne line.\nTwo lines.\nThree lines.\n"

    readme = Enum.find(snapshot.source_files, &(&1.path == "README.md"))
    copy = Enum.find(snapshot.source_files, &(&1.path == "README-copy.md"))
    assert readme.oid == copy.oid

    refute Enum.any?(snapshot.source_files, &(&1.path == "image.bin"))
  end

  @tag :tmp_dir
  test "projects Git objects to deterministic RDF identities", %{
    tmp_dir: tmp_dir
  } do
    repository = git_fixture!(tmp_dir)
    assert {:ok, snapshot} = Repository.snapshot(repository)

    repository_iri = RDF.iri("https://sheaf.less.rest/REPOSITORY")
    graph = GitRDF.object_graph(snapshot, repository_iri)
    text_graph = GitRDF.text_graph(snapshot, repository_iri, repository_iri)
    head_iri = GitRDF.object_iri(snapshot.object_format, snapshot.head)
    triples = MapSet.new(RDF.Graph.triples(graph))
    text_triples = MapSet.new(RDF.Graph.triples(text_graph))
    source_file_iri = GitRDF.source_file_iri(repository_iri, "README.md")
    block_iri = GitRDF.source_file_block_iri(source_file_iri)

    source_directory_iri =
      GitRDF.source_directory_iri(repository_iri, "src")

    nested_source_file_iri =
      GitRDF.source_file_iri(repository_iri, "src/demo.cpp")

    assert MapSet.member?(
             triples,
             {head_iri, RDF.type(), RDF.iri(DOC.GitCommit)}
           )

    assert MapSet.member?(
             triples,
             {head_iri, DOC.gitObjectId(), RDF.literal(snapshot.head)}
           )

    assert to_string(head_iri) ==
             Sheaf.Id.base_iri() <>
               "git/objects/#{snapshot.object_format}/#{snapshot.head}"

    known = MapSet.new([snapshot.head])
    incremental = GitRDF.object_graph(snapshot, repository_iri, known)

    refute Enum.any?(RDF.Graph.triples(incremental), fn
             {^head_iri, predicate, _object} ->
               predicate == DOC.gitObjectId()

             _triple ->
               false
           end)

    assert RDF.Data.statement_count(text_graph) > 0

    assert MapSet.member?(
             text_triples,
             {repository_iri, RDF.type(), RDF.iri(DOC.Document)}
           )

    assert MapSet.member?(
             text_triples,
             {repository_iri, RDF.type(), RDF.iri(DOC.GitRepository)}
           )

    assert source_directory_iri in Sheaf.Document.children(
             text_graph,
             repository_iri
           )

    assert nested_source_file_iri in Sheaf.Document.children(
             text_graph,
             source_directory_iri
           )

    nested_block_iri = GitRDF.source_file_block_iri(nested_source_file_iri)

    assert Enum.map(
             Sheaf.Document.breadcrumbs(text_graph, nested_block_iri),
             & &1.title
           ) == ["project", "src", "src/demo.cpp"]

    assert MapSet.member?(
             text_triples,
             {source_file_iri, RDF.type(), RDF.iri(DOC.GitSourceFile)}
           )

    assert MapSet.member?(
             text_triples,
             {source_file_iri, DOC.hasSourceFileBlock(), block_iri}
           )

    assert MapSet.member?(
             text_triples,
             {block_iri, RDF.type(), RDF.iri(DOC.SourceFileBlock)}
           )

    assert MapSet.member?(
             text_triples,
             {block_iri, DOC.text(),
              RDF.literal(
                "# A small repository\n\nOne line.\nTwo lines.\nThree lines.\n"
              )}
           )

    assert to_string(block_iri) == to_string(source_file_iri) <> "#content"
  end

  defp git_fixture!(tmp_dir) do
    repository = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(repository, "src"))

    git!(tmp_dir, ["init", "-b", "main", repository])
    git!(repository, ["config", "user.name", "Sheaf Test"])
    git!(repository, ["config", "user.email", "sheaf@example.com"])

    git!(repository, [
      "remote",
      "add",
      "origin",
      "https://example.com/moppe.git"
    ])

    File.write!(
      Path.join(repository, "README.md"),
      "# A small repository\n\nOne line.\nTwo lines.\nThree lines.\n"
    )

    File.cp!(
      Path.join(repository, "README.md"),
      Path.join(repository, "README-copy.md")
    )

    File.write!(
      Path.join(repository, "src/demo.cpp"),
      "int answer() {\n  return 42;\n}\n"
    )

    File.write!(Path.join(repository, "image.bin"), <<0, 1, 2, 3>>)
    git!(repository, ["add", "."])
    git!(repository, ["commit", "-m", "Initial project"])

    git!(repository, ["switch", "-c", "feature"])
    File.write!(Path.join(repository, "feature.txt"), "feature work\n")
    git!(repository, ["add", "feature.txt"])
    git!(repository, ["commit", "-m", "Add feature"])

    git!(repository, ["switch", "main"])
    File.write!(Path.join(repository, "main.txt"), "main work\n")
    git!(repository, ["add", "main.txt"])
    git!(repository, ["commit", "-m", "Advance main"])
    git!(repository, ["merge", "--no-ff", "feature", "-m", "Merge feature"])
    git!(repository, ["update-ref", "refs/codex/internal", "HEAD"])

    repository
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end
end

defmodule Sheaf.Git.SyncTest do
  use ExUnit.Case, async: false

  alias Sheaf.Git.Sync
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "registers a repository and makes repeat synchronization incremental",
       %{
         tmp_dir: tmp_dir
       } do
    repo_path = Path.join(tmp_dir, "quadlog.sqlite3")
    start_supervised!({Sheaf.Repo, path: repo_path})

    repository = create_repository!(tmp_dir)
    project = Sheaf.Id.iri("TEST-PROJECT")
    mirrored_repository = Sheaf.Id.iri("TEST-REPOSITORY")
    refs_graph = Sheaf.Id.iri("TEST-REFS")
    text_graph = Sheaf.Id.iri("TEST-TEXT")

    opts = [
      project: "Test project",
      project_iri: project,
      repository_iri: mirrored_repository,
      refs_graph: refs_graph,
      text_graph: text_graph
    ]

    assert {:ok, first} = Sync.sync(repository, opts)
    assert first.created?
    assert first.new_object_count == first.object_count
    assert first.source_file_count > 0
    assert first.references_changed?

    assert {:ok, second} = Sync.sync(repository, opts)
    refute second.created?
    assert second.new_object_count == 0
    assert second.asserted_statement_count == 0
    refute second.references_changed?

    assert {:ok, rows} =
             Sheaf.Repo.match_rows(
               {nil, DOC.repositoryIdentity(), nil,
                RDF.iri(Sheaf.Workspace.graph())}
             )

    assert Enum.any?(rows, fn {_graph, subject, _predicate, _object} ->
             subject == mirrored_repository
           end)

    assert {:ok, text_rows} =
             Sheaf.TextUnits.fetch_rows(kinds: ["sourceFile"])

    assert Enum.any?(text_rows, fn row ->
             row["kind"] == RDF.literal("sourceFile") and
               String.contains?(
                 to_string(row["searchText"]),
                 "README.md"
               )
           end)

    readme_row =
      Enum.find(text_rows, &(to_string(&1["sourcePath"]) == "README.md"))

    assert to_string(readme_row["iri"]) ==
             to_string(
               Sheaf.Git.RDF.source_file_iri(
                 mirrored_repository,
                 "README.md"
               )
             ) <> "#content"

    assert to_string(readme_row["text"]) == "# Searchable project\n"
    assert readme_row["doc"] == mirrored_repository
    assert readme_row["breadcrumbs"] == ["sync-project", "README.md"]
    assert readme_row["previous"] == nil
    assert readme_row["following"] == nil
    refute Map.has_key?(readme_row, "startLine")
    refute Map.has_key?(readme_row, "endLine")

    assert {:ok, logical_graph} =
             Sheaf.Corpus.graph_iri(mirrored_repository)

    assert logical_graph.name == text_graph

    assert Sheaf.Git.RDF.source_file_iri(mirrored_repository, "README.md") in Sheaf.Document.children(
             logical_graph,
             mirrored_repository
           )

    search_path = Path.join(tmp_dir, "source-search.sqlite3")

    assert {:ok, %{kinds: %{"sourceFile" => 1}}} =
             Sheaf.Search.Index.sync(
               db_path: search_path,
               kinds: ["sourceFile"]
             )

    assert {:ok, [scoped_hit]} =
             Sheaf.Search.Index.search("searchable project",
               db_path: search_path,
               document_id: "TEST-REPOSITORY",
               kinds: ["sourceFile"]
             )

    assert scoped_hit.doc_iri == to_string(mirrored_repository)

    assert {:ok, commit_rows} =
             Sheaf.TextUnits.fetch_rows(kinds: ["gitCommit"])

    assert Enum.any?(commit_rows, fn row ->
             row["kind"] == RDF.literal("gitCommit") and
               to_string(row["text"]) == "Initial project"
           end)

    File.write!(
      Path.join(repository, "README.md"),
      "# Revised codebase\n\nOnly current source should be searchable.\n"
    )

    git!(repository, ["add", "README.md"])
    git!(repository, ["commit", "-m", "Revise project"])

    assert {:ok, third} = Sync.sync(repository, opts)
    assert third.new_object_count > 0
    assert third.text_changed?

    assert {:ok, current_text_rows} =
             Sheaf.TextUnits.fetch_rows(kinds: ["sourceFile"])

    current_text =
      current_text_rows
      |> Enum.map(&to_string(&1["text"]))
      |> Enum.join("\n")

    assert current_text =~ "Only current source should be searchable"
    refute current_text =~ "Searchable project"
  end

  defp create_repository!(tmp_dir) do
    repository = Path.join(tmp_dir, "sync-project")
    File.mkdir_p!(repository)

    git!(tmp_dir, ["init", "-b", "main", repository])
    git!(repository, ["config", "user.name", "Sheaf Test"])
    git!(repository, ["config", "user.email", "sheaf@example.com"])
    File.write!(Path.join(repository, "README.md"), "# Searchable project\n")
    git!(repository, ["add", "README.md"])
    git!(repository, ["commit", "-m", "Initial project"])
    repository
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end
end
