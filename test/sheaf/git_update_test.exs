defmodule Sheaf.Git.UpdateTest do
  use ExUnit.Case, async: false

  alias Sheaf.Git.{Sync, Update}

  @tag :tmp_dir
  test "fast-forwards a clean registered checkout and refreshes its RDF projection",
       %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "quadlog.sqlite3")
    start_supervised!({Sheaf.Repo, path: repo_path})

    remote = Path.join(tmp_dir, "remote.git")
    seed = Path.join(tmp_dir, "seed")
    checkout = Path.join(tmp_dir, "checkout")
    contributor = Path.join(tmp_dir, "contributor")

    git!(tmp_dir, ["init", "--bare", remote])
    git!(tmp_dir, ["init", "-b", "main", seed])
    configure_author!(seed)
    File.write!(Path.join(seed, "README.md"), "# Initial project\n")
    git!(seed, ["add", "README.md"])
    git!(seed, ["commit", "-m", "Initial project"])
    git!(seed, ["remote", "add", "origin", remote])
    git!(seed, ["push", "-u", "origin", "main"])
    git!(remote, ["symbolic-ref", "HEAD", "refs/heads/main"])

    git!(tmp_dir, ["clone", remote, checkout])
    configure_author!(checkout)

    project = Sheaf.Id.iri("PROJECT")

    assert {:ok, first_sync} =
             Sync.sync(checkout,
               project: "Example project",
               project_iri: project,
               repository_iri: Sheaf.Id.iri("REPOSITORY"),
               refs_graph: Sheaf.Id.iri("REFERENCES"),
               text_graph: Sheaf.Id.iri("SOURCE-TEXT")
             )

    git!(tmp_dir, ["clone", remote, contributor])
    configure_author!(contributor)
    File.write!(Path.join(contributor, "README.md"), "# Updated upstream\n")
    git!(contributor, ["add", "README.md"])
    git!(contributor, ["commit", "-m", "Update upstream"])
    git!(contributor, ["push", "origin", "main"])

    assert {:ok, summary} =
             Update.pull_and_sync("PROJECT",
               backup?: false,
               sync_search?: false,
               sync_embeddings?: false
             )

    assert summary.changed?
    assert summary.before_head == first_sync.head
    assert summary.after_head != summary.before_head
    assert summary.upstream == "origin/main"
    assert summary.backup_path == nil

    assert File.read!(Path.join(checkout, "README.md")) ==
             "# Updated upstream\n"

    assert {:ok, loaded} = Sheaf.SoftwareProjects.get("PROJECT")
    assert loaded.head.object_id == summary.after_head
    assert loaded.head.message == "Update upstream"

    no_op_backup = Path.join(tmp_dir, "no-op-backup.sqlite3")

    assert {:ok, no_op} =
             Update.pull_and_sync("PROJECT",
               backup_path: no_op_backup,
               sync_search?: false,
               sync_embeddings?: false
             )

    refute no_op.changed?
    refute no_op.repository_changed?
    refute no_op.refs_changed?
    refute no_op.mirror_stale?
    assert no_op.before_head == no_op.after_head
    assert no_op.pull_output == "Already up to date."
    assert no_op.backup_path == nil
    assert no_op.git == nil
    assert no_op.search == nil
    assert no_op.embeddings == nil
    refute File.exists?(no_op_backup)

    File.write!(Path.join(checkout, "LOCAL.txt"), "uncommitted\n")

    assert {:error, {:dirty_worktree, output}} =
             Update.pull_and_sync("PROJECT",
               backup?: false,
               sync_search?: false,
               sync_embeddings?: false
             )

    assert output =~ "LOCAL.txt"
  end

  defp configure_author!(path) do
    git!(path, ["config", "user.name", "Sheaf Test"])
    git!(path, ["config", "user.email", "sheaf@example.com"])
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end
end
