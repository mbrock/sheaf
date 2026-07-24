defmodule Sheaf.Git.Sync do
  @moduledoc """
  Incrementally projects Git repository topology and selected text into Quadlog.

  Immutable Git object facts are asserted only once. The much smaller graph of
  mutable references is replaced atomically after a successful snapshot.
  """

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.Git.RDF, as: GitRDF
  alias Sheaf.Git.Repository
  alias Sheaf.NS.{DOC, PROV}
  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Synchronizes a local Git working tree into the active Sheaf repository.
  """
  def sync(path, opts \\ []) when is_binary(path) do
    Tracer.with_span "sheaf.git.sync", %{
      kind: :internal,
      attributes: [
        {"sheaf.git.path", Path.expand(path)},
        {"db.system", "quadlog"},
        {"db.operation", "git_sync"}
      ]
    } do
      started_at = DateTime.utc_now() |> DateTime.truncate(:second)

      with {:ok, snapshot} <- Repository.snapshot(path, opts),
           {:ok, registry} <- repository_registry(snapshot, opts),
           {:ok, known_object_ids} <- known_object_ids(registry.repository),
           object_graph =
             GitRDF.object_graph(
               snapshot,
               registry.repository,
               known_object_ids
             ),
           object_graph =
             add_repository_header(object_graph, snapshot, registry),
           refs_graph =
             GitRDF.references_graph(
               snapshot,
               registry.repository,
               registry.refs_graph
             ),
           text_graph =
             GitRDF.text_graph(
               snapshot,
               registry.repository,
               registry.text_graph
             ),
           {:ok, old_refs_graph} <- Sheaf.fetch_graph(registry.refs_graph),
           {:ok, old_text_graph} <- Sheaf.fetch_graph(registry.text_graph),
           {text_retractions, text_assertions} <-
             graph_delta(old_text_graph, text_graph),
           workspace_changes <- workspace_changes(snapshot, registry),
           activity_graph <-
             synchronization_activity(
               snapshot,
               registry.repository,
               started_at
             ),
           changes <-
             synchronization_changes(
               object_graph,
               old_refs_graph,
               refs_graph,
               text_retractions,
               text_assertions,
               workspace_changes,
               activity_graph
             ),
           :ok <-
             Sheaf.Repo.transact(
               "synchronize Git repository #{snapshot.identity}",
               changes,
               [
                 {"sheaf.git.repository", to_string(registry.repository)},
                 {"sheaf.git.identity", snapshot.identity},
                 {"sheaf.git.new_object_count",
                  new_object_count(snapshot, known_object_ids)},
                 {"sheaf.git.text_fragment_count", length(snapshot.fragments)}
               ]
             ) do
        summary = %{
          project: registry.project,
          repository: registry.repository,
          refs_graph: registry.refs_graph,
          root: snapshot.root,
          identity: snapshot.identity,
          head: snapshot.head,
          object_format: snapshot.object_format,
          object_count: map_size(snapshot.objects),
          new_object_count: new_object_count(snapshot, known_object_ids),
          reference_count: length(snapshot.refs),
          text_fragment_count: length(snapshot.fragments),
          asserted_statement_count:
            RDF.Data.statement_count(object_graph) +
              RDF.Data.statement_count(text_assertions),
          references_changed?: not graph_equal?(old_refs_graph, refs_graph),
          text_changed?:
            RDF.Data.statement_count(text_retractions) > 0 or
              RDF.Data.statement_count(text_assertions) > 0,
          created?: registry.created?
        }

        Tracer.set_attributes([
          {"sheaf.git.repository", to_string(registry.repository)},
          {"sheaf.git.object_count", summary.object_count},
          {"sheaf.git.new_object_count", summary.new_object_count},
          {"sheaf.git.reference_count", summary.reference_count},
          {"sheaf.git.text_fragment_count", summary.text_fragment_count},
          {"sheaf.git.asserted_statement_count",
           summary.asserted_statement_count}
        ])

        {:ok, summary}
      end
    end
  end

  defp repository_registry(snapshot, opts) do
    with {:ok, existing} <- find_repository(snapshot.identity) do
      case existing do
        nil -> create_registry(snapshot, opts)
        repository -> existing_registry(repository)
      end
    end
  end

  defp find_repository(identity) do
    with {:ok, rows} <-
           Sheaf.Repo.match_rows(
             {nil, DOC.repositoryIdentity(), nil,
              RDF.iri(Sheaf.Workspace.graph())}
           ) do
      repository =
        Enum.find_value(rows, fn {_graph, subject, _predicate, object} ->
          if term_value(object) == identity, do: subject
        end)

      {:ok, repository}
    end
  end

  defp create_registry(snapshot, opts) do
    workspace = Sheaf.Workspace.default()

    project =
      opts
      |> Keyword.get_lazy(:project_iri, &Sheaf.mint/0)
      |> RDF.iri()

    repository =
      opts
      |> Keyword.get_lazy(:repository_iri, &Sheaf.mint/0)
      |> RDF.iri()

    refs_graph =
      opts
      |> Keyword.get_lazy(:refs_graph, &Sheaf.mint/0)
      |> RDF.iri()

    text_graph =
      opts
      |> Keyword.get_lazy(:text_graph, &Sheaf.mint/0)
      |> RDF.iri()

    {:ok,
     %{
       workspace: workspace,
       project: project,
       repository: repository,
       refs_graph: refs_graph,
       text_graph: text_graph,
       project_label: Keyword.get(opts, :project, snapshot.label),
       created?: true
     }}
  end

  defp existing_registry(repository) do
    workspace = Sheaf.Workspace.default()

    with {:ok, project_rows} <-
           Sheaf.Repo.match_rows(
             {nil, DOC.hasSourceRepository(), repository,
              RDF.iri(Sheaf.Workspace.graph())}
           ),
         {:ok, refs_rows} <-
           Sheaf.Repo.match_rows(
             {repository, DOC.hasGitReferenceGraph(), nil,
              RDF.iri(Sheaf.Workspace.graph())}
           ),
         {:ok, text_rows} <-
           Sheaf.Repo.match_rows(
             {repository, DOC.hasGitTextGraph(), nil,
              RDF.iri(Sheaf.Workspace.graph())}
           ) do
      project =
        case project_rows do
          [{_graph, project, _predicate, _object} | _] -> project
          [] -> Sheaf.mint()
        end

      refs_graph =
        case refs_rows do
          [{_graph, _subject, _predicate, refs_graph} | _] -> refs_graph
          [] -> Sheaf.mint()
        end

      text_graph =
        case text_rows do
          [{_graph, _subject, _predicate, text_graph} | _] -> text_graph
          [] -> Sheaf.mint()
        end

      {:ok,
       %{
         workspace: workspace,
         project: project,
         repository: repository,
         refs_graph: refs_graph,
         text_graph: text_graph,
         project_label: nil,
         created?: false
       }}
    end
  end

  defp known_object_ids(repository) do
    with {:ok, rows} <-
           Sheaf.Repo.match_rows({nil, DOC.gitObjectId(), nil, repository}) do
      rows
      |> Enum.map(fn {_graph, _subject, _predicate, object} ->
        term_value(object)
      end)
      |> MapSet.new()
      |> then(&{:ok, &1})
    end
  end

  defp add_repository_header(graph, _snapshot, %{created?: false}), do: graph

  defp add_repository_header(graph, snapshot, registry) do
    graph
    |> Graph.add({registry.repository, RDF.type(), DOC.GitRepository})
    |> Graph.add(
      {registry.repository, RDFS.label(), "#{snapshot.label} Git repository"}
    )
    |> Graph.add(
      {registry.repository, DOC.repositoryIdentity(), snapshot.identity}
    )
    |> Graph.add(
      {registry.repository, DOC.gitObjectFormat(), snapshot.object_format}
    )
    |> Graph.add(
      {registry.repository, DOC.hasGitReferenceGraph(), registry.refs_graph}
    )
    |> Graph.add(
      {registry.repository, DOC.hasGitTextGraph(), registry.text_graph}
    )
    |> add_optional(
      registry.repository,
      DOC.remoteUrl(),
      snapshot.remote_url
    )
  end

  defp workspace_changes(snapshot, %{created?: true} = registry) do
    graph =
      Graph.new(
        [
          {registry.workspace, DOC.hasSoftwareProject(), registry.project},
          {registry.project, RDF.type(), DOC.SoftwareProject},
          {registry.project, RDFS.label(), registry.project_label},
          {registry.project, DOC.hasSourceRepository(), registry.repository},
          {registry.repository, RDF.type(), DOC.GitRepository},
          {registry.repository, DOC.repositoryIdentity(), snapshot.identity},
          {registry.repository, DOC.checkoutPath(), snapshot.root},
          {registry.repository, DOC.gitObjectFormat(),
           snapshot.object_format},
          {registry.repository, DOC.hasGitReferenceGraph(),
           registry.refs_graph},
          {registry.repository, DOC.hasGitTextGraph(), registry.text_graph}
        ],
        name: Sheaf.Workspace.graph()
      )
      |> add_optional(
        registry.repository,
        DOC.remoteUrl(),
        snapshot.remote_url
      )

    [{:assert, graph}]
  end

  defp workspace_changes(snapshot, registry) do
    graph_name = RDF.iri(Sheaf.Workspace.graph())

    with {:ok, rows} <-
           Sheaf.Repo.match_rows(
             {registry.repository, DOC.checkoutPath(), nil, graph_name}
           ) do
      previous =
        rows
        |> Enum.map(fn {_graph, subject, predicate, object} ->
          {subject, predicate, object}
        end)
        |> Graph.new(name: graph_name)

      current =
        Graph.new(
          {registry.repository, DOC.checkoutPath(), snapshot.root},
          name: graph_name
        )

      changes =
        if graph_equal?(previous, current) do
          []
        else
          []
          |> maybe_change(:retract, previous)
          |> maybe_change(:assert, current)
        end

      if registry.project_label do
        project_graph =
          Graph.new(
            [
              {registry.workspace, DOC.hasSoftwareProject(),
               registry.project},
              {registry.project, RDF.type(), DOC.SoftwareProject},
              {registry.project, RDFS.label(), registry.project_label},
              {registry.project, DOC.hasSourceRepository(),
               registry.repository},
              {registry.repository, DOC.hasGitReferenceGraph(),
               registry.refs_graph},
              {registry.repository, DOC.hasGitTextGraph(),
               registry.text_graph}
            ],
            name: graph_name
          )

        changes ++ [{:assert, project_graph}]
      else
        changes
      end
    else
      _error -> []
    end
  end

  defp synchronization_activity(snapshot, repository, started_at) do
    activity = Sheaf.mint()

    Graph.new(
      [
        {activity, RDF.type(), DOC.GitSynchronization},
        {activity, RDFS.label(), "Git repository synchronization"},
        {activity, PROV.used(), repository},
        {activity, PROV.startedAtTime(), started_at},
        {activity, PROV.endedAtTime(),
         DateTime.utc_now() |> DateTime.truncate(:second)}
      ],
      name: activity
    )
    |> then(fn graph ->
      if snapshot.head do
        Graph.add(
          graph,
          {activity, DOC.gitHead(),
           GitRDF.object_iri(snapshot.object_format, snapshot.head)}
        )
      else
        graph
      end
    end)
  end

  defp synchronization_changes(
         object_graph,
         old_refs_graph,
         refs_graph,
         text_retractions,
         text_assertions,
         workspace_changes,
         activity_graph
       ) do
    []
    |> maybe_change(:assert, object_graph)
    |> Kernel.++(workspace_changes)
    |> maybe_replace_graph(old_refs_graph, refs_graph)
    |> maybe_change(:retract, text_retractions)
    |> maybe_change(:assert, text_assertions)
    |> maybe_change(:assert, activity_graph)
  end

  defp graph_delta(old_graph, new_graph) do
    old = MapSet.new(Graph.triples(old_graph))
    new = MapSet.new(Graph.triples(new_graph))

    {
      Graph.new(Enum.to_list(MapSet.difference(old, new)),
        name: old_graph.name
      ),
      Graph.new(Enum.to_list(MapSet.difference(new, old)),
        name: new_graph.name
      )
    }
  end

  defp maybe_replace_graph(changes, old_graph, new_graph) do
    if graph_equal?(old_graph, new_graph) do
      changes
    else
      changes
      |> maybe_change(:retract, old_graph)
      |> maybe_change(:assert, new_graph)
    end
  end

  defp maybe_change(changes, _mode, graph)
       when not is_struct(graph, Graph),
       do: changes

  defp maybe_change(changes, mode, graph) do
    if RDF.Data.statement_count(graph) == 0 do
      changes
    else
      changes ++ [{mode, graph}]
    end
  end

  defp graph_equal?(left, right) do
    MapSet.new(Graph.triples(left)) == MapSet.new(Graph.triples(right))
  end

  defp new_object_count(snapshot, known_object_ids) do
    Enum.count(snapshot.objects, fn {oid, _object} ->
      not MapSet.member?(known_object_ids, oid)
    end)
  end

  defp add_optional(graph, _subject, _predicate, value)
       when value in [nil, ""],
       do: graph

  defp add_optional(graph, subject, predicate, value),
    do: Graph.add(graph, {subject, predicate, value})

  defp term_value(term), do: term |> RDF.Term.value() |> to_string()
end
