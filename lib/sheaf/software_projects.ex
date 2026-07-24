defmodule Sheaf.SoftwareProjects do
  @moduledoc """
  Reads software projects and their synchronized Git repositories from Quadlog.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{DOC, PROV}

  @recent_commit_limit 12

  @doc """
  Lists software projects attached to the current workspace.
  """
  def list do
    Tracer.with_span "Sheaf.SoftwareProjects.list", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "list_software_projects"}
      ]
    } do
      workspace = Sheaf.Workspace.default()
      workspace_graph = RDF.iri(Sheaf.Workspace.graph())

      with {:ok, rows} <-
             Sheaf.Repo.match_rows(
               {workspace, DOC.hasSoftwareProject(), nil, workspace_graph}
             ) do
        projects =
          rows
          |> Enum.map(&row_object/1)
          |> Enum.uniq()
          |> Enum.flat_map(fn project ->
            case get(project) do
              {:ok, project} -> [project]
              {:error, _reason} -> []
            end
          end)
          |> Enum.sort_by(&String.downcase(&1.title))

        Tracer.set_attribute("sheaf.software_project_count", length(projects))
        {:ok, projects}
      end
    end
  end

  @doc """
  Loads one workspace software project by short id or IRI.
  """
  def get(id_or_iri) do
    Tracer.with_span "Sheaf.SoftwareProjects.get", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "get_software_project"}
      ]
    } do
      project = project_iri(id_or_iri)
      workspace = Sheaf.Workspace.default()
      workspace_graph = RDF.iri(Sheaf.Workspace.graph())

      Tracer.set_attribute("sheaf.software_project", to_string(project))

      with {:ok, membership_rows} <-
             Sheaf.Repo.match_rows(
               {workspace, DOC.hasSoftwareProject(), project, workspace_graph}
             ),
           true <- membership_rows != [],
           {:ok, project_rows} <-
             Sheaf.Repo.match_rows({project, nil, nil, workspace_graph}),
           repository when not is_nil(repository) <-
             first_object(project_rows, DOC.hasSourceRepository()),
           {:ok, repository_rows} <-
             Sheaf.Repo.match_rows({repository, nil, nil, nil}),
           {:ok, project} <-
             build_project(
               project,
               project_rows,
               repository,
               repository_rows
             ) do
        Tracer.set_attributes([
          {"sheaf.git.repository", project.repository.iri},
          {"sheaf.git.commit_count", project.commit_count},
          {"sheaf.git.reference_count", project.reference_count},
          {"sheaf.git.source_file_count", project.source_file_count}
        ])

        {:ok, project}
      else
        false -> {:error, :not_found}
        nil -> {:error, :missing_source_repository}
        {:error, _reason} = error -> error
      end
    end
  end

  defp build_project(project, project_rows, repository, repository_rows) do
    with {:ok, member_rows} <-
           Sheaf.Repo.match_rows(
             {nil, DOC.inGitRepository(), repository, nil}
           ),
         members = member_rows |> Enum.map(&row_subject/1) |> MapSet.new(),
         {:ok, type_rows} <-
           Sheaf.Repo.match_rows({nil, RDF.type(), nil, nil}),
         commits = typed_members(type_rows, members, DOC.GitCommit),
         source_files = typed_members(type_rows, members, DOC.GitSourceFile),
         {:ok, commit_rows} <- rows_for_subjects(commits),
         {:ok, source_file_rows} <- rows_for_subjects(source_files),
         {:ok, reference_rows} <-
           Sheaf.Repo.match_rows(
             {repository, DOC.hasGitReference(), nil, nil}
           ),
         references = Enum.map(reference_rows, &row_object/1),
         {:ok, reference_detail_rows} <- rows_for_subjects(references),
         {:ok, sync_rows} <-
           Sheaf.Repo.match_rows({nil, PROV.used(), repository, nil}),
         synchronization_activities = Enum.map(sync_rows, &row_subject/1),
         {:ok, synchronization_rows} <-
           rows_for_subjects(synchronization_activities) do
      commits = build_commits(commits, commit_rows)
      head_iri = first_object(repository_rows, DOC.gitHead())
      head = Enum.find(commits, &(&1.iri == to_string(head_iri)))

      references =
        build_references(references, reference_detail_rows, head_iri)

      source_files = build_source_files(source_files, source_file_rows)

      synchronized_at =
        latest_timestamp(synchronization_rows, PROV.endedAtTime())

      id = Id.id_from_iri(project)

      {:ok,
       %{
         id: id,
         iri: to_string(project),
         path: "/#{id}",
         title: first_value(project_rows, RDFS.label()) || "Software project",
         kind: :software_project,
         repository: %{
           iri: to_string(repository),
           id: Id.id_from_iri(repository),
           label:
             first_value(repository_rows, RDFS.label()) || "Git repository",
           identity: first_value(repository_rows, DOC.repositoryIdentity()),
           checkout_path: first_value(repository_rows, DOC.checkoutPath()),
           remote_url: first_value(repository_rows, DOC.remoteUrl()),
           object_format:
             first_value(repository_rows, DOC.gitObjectFormat()) || "sha1"
         },
         head: head,
         head_references: Enum.filter(references, & &1.head?),
         references: references,
         reference_count: length(references),
         recent_commits: Enum.take(commits, @recent_commit_limit),
         commit_count: length(commits),
         source_files: source_files,
         source_file_count: length(source_files),
         synchronized_at: synchronized_at
       }}
    end
  end

  defp rows_for_subjects([]), do: {:ok, []}

  defp rows_for_subjects(subjects),
    do: Sheaf.Repo.match_rows({subjects, nil, nil, nil})

  defp typed_members(rows, members, type) do
    type = RDF.iri(type)

    rows
    |> Enum.flat_map(fn row ->
      if row_object(row) == type and MapSet.member?(members, row_subject(row)),
        do: [row_subject(row)],
        else: []
    end)
    |> Enum.uniq()
  end

  defp build_commits(commits, rows) do
    rows
    |> Enum.group_by(&row_subject/1)
    |> then(fn grouped ->
      Enum.map(commits, fn commit ->
        commit_rows = Map.get(grouped, commit, [])
        object_id = first_value(commit_rows, DOC.gitObjectId())

        %{
          iri: to_string(commit),
          object_id: object_id,
          short_id: short_object_id(object_id),
          message: first_value(commit_rows, DOC.commitMessage()) || "Commit",
          author: first_value(commit_rows, DOC.authorName()),
          authored_at: first_value(commit_rows, DOC.authoredAt()),
          committed_at: first_value(commit_rows, DOC.committedAt())
        }
      end)
    end)
    |> Enum.sort_by(
      &timestamp_sort_value(&1.committed_at || &1.authored_at),
      :desc
    )
  end

  defp build_references(references, rows, head_iri) do
    rows
    |> Enum.group_by(&row_subject/1)
    |> then(fn grouped ->
      Enum.map(references, fn reference ->
        reference_rows = Map.get(grouped, reference, [])
        target = first_object(reference_rows, DOC.pointsToGitObject())
        name = first_value(reference_rows, DOC.gitReferenceName())

        %{
          iri: to_string(reference),
          name: name,
          display_name: reference_display_name(name),
          kind: reference_kind(name),
          target_iri: target && to_string(target),
          head?: not is_nil(head_iri) and target == head_iri
        }
      end)
    end)
    |> Enum.sort_by(&{reference_sort_order(&1.kind), &1.display_name})
  end

  defp build_source_files(source_files, rows) do
    rows
    |> Enum.group_by(&row_subject/1)
    |> then(fn grouped ->
      Enum.map(source_files, fn source_file ->
        source_rows = Map.get(grouped, source_file, [])

        %{
          iri: to_string(source_file),
          path:
            first_value(source_rows, DOC.sourcePath()) ||
              first_value(source_rows, RDFS.label()) ||
              to_string(source_file),
          language: first_value(source_rows, DOC.sourceLanguage()),
          block_iri:
            source_rows
            |> first_object(DOC.hasSourceFileBlock())
            |> then(&(&1 && to_string(&1)))
        }
      end)
    end)
    |> Enum.sort_by(&String.downcase(&1.path))
  end

  defp latest_timestamp(rows, predicate) do
    rows
    |> values(predicate)
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp first_object(rows, predicate) do
    predicate = RDF.iri(predicate)

    Enum.find_value(rows, fn row ->
      if row_predicate(row) == predicate, do: row_object(row)
    end)
  end

  defp first_value(rows, predicate) do
    rows
    |> values(predicate)
    |> List.first()
  end

  defp values(rows, predicate) do
    predicate = RDF.iri(predicate)

    rows
    |> Enum.flat_map(fn row ->
      if row_predicate(row) == predicate,
        do: [term_value(row_object(row))],
        else: []
    end)
  end

  defp project_iri(%RDF.IRI{} = iri), do: iri

  defp project_iri(value) when is_binary(value) do
    if String.starts_with?(value, ["http://", "https://"]),
      do: RDF.iri(value),
      else: Id.iri(value)
  end

  defp row_subject({_graph, subject, _predicate, _object}), do: subject
  defp row_predicate({_graph, _subject, predicate, _object}), do: predicate
  defp row_object({_graph, _subject, _predicate, object}), do: object

  defp term_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

  defp short_object_id(nil), do: nil
  defp short_object_id(object_id), do: String.slice(object_id, 0, 10)

  defp timestamp_sort_value(%DateTime{} = timestamp),
    do: DateTime.to_unix(timestamp, :microsecond)

  defp timestamp_sort_value(_timestamp), do: 0

  defp reference_display_name("refs/heads/" <> name), do: name
  defp reference_display_name("refs/remotes/" <> name), do: name
  defp reference_display_name("refs/tags/" <> name), do: name
  defp reference_display_name(name), do: name || "reference"

  defp reference_kind("refs/heads/" <> _name), do: :branch
  defp reference_kind("refs/remotes/" <> _name), do: :remote
  defp reference_kind("refs/tags/" <> _name), do: :tag
  defp reference_kind(_name), do: :reference

  defp reference_sort_order(:branch), do: 0
  defp reference_sort_order(:tag), do: 1
  defp reference_sort_order(:remote), do: 2
  defp reference_sort_order(:reference), do: 3
end
