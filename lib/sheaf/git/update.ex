defmodule Sheaf.Git.Update do
  @moduledoc """
  Safely fast-forwards a registered repository and refreshes its Sheaf mirrors.

  This is intentionally narrower than a general Git command surface. It only
  operates on a checkout path already attached to a workspace software project,
  refuses local changes, and requires the current branch to have an upstream.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Sheaf.Embedding
  alias Sheaf.Git.Sync
  alias Sheaf.Search

  @doc """
  Pulls and synchronizes a registered software project's repository.
  """
  def pull_and_sync(project_id, opts \\ []) do
    Tracer.with_span "sheaf.git.update", %{
      kind: :internal,
      attributes: [
        {"db.system", "git"},
        {"db.operation", "pull_and_sync"},
        {"sheaf.software_project.id", to_string(project_id)}
      ]
    } do
      with {:ok, project} <- Sheaf.SoftwareProjects.get(project_id),
           :ok <- validate_checkout(project.repository.checkout_path),
           :ok <- require_clean_worktree(project.repository.checkout_path),
           {:ok, upstream} <- upstream(project.repository.checkout_path),
           {:ok, before_head} <- head(project.repository.checkout_path),
           {:ok, pull_output} <-
             git(project.repository.checkout_path, [
               "pull",
               "--ff-only",
               "--no-stat"
             ]),
           {:ok, after_head} <- head(project.repository.checkout_path),
           {:ok, backup_path} <- maybe_backup(opts),
           {:ok, git_summary} <-
             Sync.sync(project.repository.checkout_path,
               project_iri: project.iri
             ),
           {:ok, search_summary} <- maybe_sync_search(opts),
           {:ok, embedding_summary} <- maybe_sync_embeddings(opts) do
        summary = %{
          project_id: project.id,
          project_title: project.title,
          checkout_path: project.repository.checkout_path,
          upstream: upstream,
          before_head: before_head,
          after_head: after_head,
          changed?: before_head != after_head,
          pull_output: String.trim(pull_output),
          backup_path: backup_path,
          git: git_summary,
          search: search_summary,
          embeddings: embedding_summary
        }

        Tracer.set_attributes([
          {"sheaf.git.checkout_path", project.repository.checkout_path},
          {"sheaf.git.upstream", upstream},
          {"sheaf.git.before_head", before_head},
          {"sheaf.git.after_head", after_head},
          {"sheaf.git.changed", summary.changed?},
          {"sheaf.git.pull_output", summary.pull_output},
          {"sheaf.git.source_file_count", git_summary.source_file_count},
          {"sheaf.git.new_object_count", git_summary.new_object_count}
        ])

        {:ok, summary}
      else
        {:error, reason} = error ->
          Tracer.set_attribute("error.type", inspect(reason))
          error
      end
    end
  rescue
    error ->
      Tracer.record_exception(error, __STACKTRACE__)
      {:error, {:update_exception, Exception.message(error)}}
  catch
    kind, reason ->
      {:error, {:update_failure, kind, reason}}
  end

  defp validate_checkout(nil), do: {:error, :missing_checkout_path}

  defp validate_checkout(path) when is_binary(path) do
    cond do
      Path.type(path) != :absolute ->
        {:error, {:invalid_checkout_path, path}}

      not File.dir?(path) ->
        {:error, {:checkout_not_found, path}}

      true ->
        case git(path, ["rev-parse", "--is-inside-work-tree"]) do
          {:ok, output} ->
            if String.trim(output) == "true",
              do: :ok,
              else: {:error, {:not_a_git_worktree, path}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp require_clean_worktree(path) do
    with {:ok, output} <-
           git(path, ["status", "--porcelain", "--untracked-files=normal"]) do
      if String.trim(output) == "",
        do: :ok,
        else: {:error, {:dirty_worktree, output}}
    end
  end

  defp upstream(path) do
    with {:ok, output} <-
           git(path, [
             "rev-parse",
             "--abbrev-ref",
             "--symbolic-full-name",
             "@{upstream}"
           ]) do
      case String.trim(output) do
        "" -> {:error, :missing_upstream}
        upstream -> {:ok, upstream}
      end
    else
      {:error, _reason} -> {:error, :missing_upstream}
    end
  end

  defp head(path) do
    with {:ok, output} <- git(path, ["rev-parse", "HEAD"]) do
      {:ok, String.trim(output)}
    end
  end

  defp git(path, args) do
    Tracer.with_span "sheaf.git.command", %{
      kind: :client,
      attributes: [
        {"db.system", "git"},
        {"db.operation", List.first(args)},
        {"sheaf.git.checkout_path", path},
        {"sheaf.git.arguments", Enum.join(args, " ")}
      ]
    } do
      case System.cmd("git", ["-C", path | args],
             stderr_to_stdout: true,
             env: [{"GIT_TERMINAL_PROMPT", "0"}]
           ) do
        {output, 0} ->
          Tracer.set_attribute("sheaf.git.output", output)
          {:ok, output}

        {output, status} ->
          reason = %{
            command: ["git", "-C", path | args],
            exit_status: status,
            output: String.trim(output)
          }

          Tracer.set_attributes([
            {"error.type", "git_command_failed"},
            {"process.exit.code", status},
            {"sheaf.git.output", output}
          ])

          {:error, {:git_command_failed, reason}}
      end
    end
  rescue
    error in ErlangError ->
      {:error, {:git_executable_failed, Exception.message(error)}}
  end

  defp maybe_backup(opts) do
    if Keyword.get(opts, :backup?, true),
      do: backup_dataset(opts),
      else: {:ok, nil}
  end

  defp backup_dataset(opts) do
    source = Sheaf.Repo.path()

    path =
      Keyword.get_lazy(opts, :backup_path, fn ->
        name =
          "sheaf-#{System.system_time(:second)}-#{System.unique_integer([:positive])}.sqlite3"

        Path.join(["output", "backups", name])
      end)

    Tracer.with_span "sheaf.git.update.backup", %{
      kind: :internal,
      attributes: [
        {"db.system", "sqlite"},
        {"db.operation", "backup"},
        {"db.name", source},
        {"sheaf.backup.path", path}
      ]
    } do
      File.mkdir_p!(Path.dirname(path))

      case Exqlite.start_link(database: source) do
        {:ok, conn} ->
          try do
            case Exqlite.query(conn, "VACUUM main INTO ?", [path],
                   timeout: :infinity
                 ) do
              {:ok, _result} -> {:ok, path}
              {:error, reason} -> {:error, {:backup_failed, reason}}
            end
          after
            GenServer.stop(conn)
          end

        {:error, reason} ->
          {:error, {:backup_failed, reason}}
      end
    end
  end

  defp maybe_sync_search(opts) do
    if Keyword.get(opts, :sync_search?, true),
      do: Search.Index.sync(),
      else: {:ok, nil}
  end

  defp maybe_sync_embeddings(opts) do
    if Keyword.get(opts, :sync_embeddings?, true),
      do: Embedding.Index.sync(),
      else: {:ok, nil}
  end
end
