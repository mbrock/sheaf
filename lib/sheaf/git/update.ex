defmodule Sheaf.Git.Update do
  @moduledoc """
  Safely fast-forwards a registered repository and refreshes its Sheaf mirrors.

  This is intentionally narrower than a general Git command surface. It only
  operates on a checkout path already attached to a workspace software project,
  refuses local changes, and requires the current branch to have an upstream.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Sheaf.Git.Sync
  alias Sheaf.SearchMaintenance

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
           {:ok, before_refs} <- refs(project.repository.checkout_path),
           {:ok, pull_output} <-
             git(project.repository.checkout_path, [
               "pull",
               "--ff-only",
               "--no-stat"
             ]),
           {:ok, after_head} <- head(project.repository.checkout_path),
           {:ok, after_refs} <- refs(project.repository.checkout_path) do
        changed? = before_head != after_head
        refs_changed? = before_refs != after_refs
        mirror_stale? = mirrored_head(project) != after_head

        if changed? or refs_changed? or mirror_stale? do
          refresh_changed_repository(
            project,
            upstream,
            before_head,
            after_head,
            refs_changed?,
            mirror_stale?,
            pull_output,
            opts
          )
        else
          summary =
            update_summary(
              project,
              upstream,
              before_head,
              after_head,
              refs_changed?,
              mirror_stale?,
              pull_output
            )

          set_update_attributes(summary, nil)
          Tracer.set_attribute("sheaf.git.maintenance_skipped", true)
          {:ok, summary}
        end
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

  defp refs(path) do
    git(path, [
      "for-each-ref",
      "--format=%(refname)%00%(objectname)"
    ])
  end

  defp refresh_changed_repository(
         project,
         upstream,
         before_head,
         after_head,
         refs_changed?,
         mirror_stale?,
         pull_output,
         opts
       ) do
    with {:ok, git_summary} <-
           Sync.sync(project.repository.checkout_path,
             project_iri: project.iri
           ),
         {:ok, index_summary} <-
           SearchMaintenance.refresh_git_sync(git_summary, opts) do
      summary =
        project
        |> update_summary(
          upstream,
          before_head,
          after_head,
          refs_changed?,
          mirror_stale?,
          pull_output
        )
        |> Map.merge(%{
          git: git_summary,
          search: index_summary.search,
          embeddings: index_summary.embedding
        })

      set_update_attributes(summary, git_summary)
      Tracer.set_attribute("sheaf.git.maintenance_skipped", false)
      {:ok, summary}
    end
  end

  defp update_summary(
         project,
         upstream,
         before_head,
         after_head,
         refs_changed?,
         mirror_stale?,
         pull_output
       ) do
    %{
      project_id: project.id,
      project_title: project.title,
      checkout_path: project.repository.checkout_path,
      upstream: upstream,
      before_head: before_head,
      after_head: after_head,
      changed?: before_head != after_head,
      repository_changed?:
        before_head != after_head or refs_changed? or mirror_stale?,
      refs_changed?: refs_changed?,
      mirror_stale?: mirror_stale?,
      pull_output: String.trim(pull_output),
      git: nil,
      search: nil,
      embeddings: nil
    }
  end

  defp set_update_attributes(summary, git_summary) do
    Tracer.set_attributes([
      {"sheaf.git.checkout_path", summary.checkout_path},
      {"sheaf.git.upstream", summary.upstream},
      {"sheaf.git.before_head", summary.before_head},
      {"sheaf.git.after_head", summary.after_head},
      {"sheaf.git.changed", summary.changed?},
      {"sheaf.git.refs_changed", summary.refs_changed?},
      {"sheaf.git.mirror_stale", summary.mirror_stale?},
      {"sheaf.git.repository_changed", summary.repository_changed?},
      {"sheaf.git.pull_output", summary.pull_output},
      {"sheaf.git.source_file_count",
       if(git_summary, do: git_summary.source_file_count, else: 0)},
      {"sheaf.git.new_object_count",
       if(git_summary, do: git_summary.new_object_count, else: 0)}
    ])
  end

  defp mirrored_head(%{head: %{object_id: object_id}})
       when is_binary(object_id),
       do: object_id

  defp mirrored_head(_project), do: nil

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
end
