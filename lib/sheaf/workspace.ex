defmodule Sheaf.Workspace do
  @moduledoc """
  Workspace-level reading preferences stored as RDF.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.Id
  alias Sheaf.NS.DOC
  require RDF.Graph

  @graph "https://less.rest/sheaf/workspace"
  @label "Ieva's thesis workspace"

  @doc """
  Returns the IRI for the default workspace, creating it when needed.
  """
  def ensure_default do
    with :ok <- load_workspace_graph() do
      case Sheaf.Repo.ask(&default_workspace/1) do
        nil -> create_default()
        workspace -> {:ok, workspace |> RDF.Term.value() |> to_string()}
      end
    end
  end

  @doc """
  Records whether a document is excluded from the active workspace corpus.
  """
  def set_document_excluded(document_id, excluded?) when is_binary(document_id) do
    document = Id.iri(document_id)

    if excluded? do
      with {:ok, workspace} <- ensure_default() do
        workspace
        |> RDF.iri()
        |> exclusion_graph(document)
        |> Sheaf.Repo.assert()
      end
    else
      document
      |> exclusion_retraction_graph()
      |> Sheaf.Repo.retract()
    end
  end

  @doc """
  Records the person whose authored work the active workspace is organized around.
  """
  def set_owner(person_id) when is_binary(person_id) do
    person = Id.iri(person_id)

    with {:ok, workspace} <- ensure_default() do
      workspace = RDF.iri(workspace)
      previous = Sheaf.Repo.ask(&workspace_owners(&1, workspace))

      changes =
        Enum.map(previous, &{:retract, owner_graph(workspace, &1)}) ++
          [{:assert, owner_graph(workspace, person)}]

      Sheaf.Repo.transact(changes)
    end
  end

  def graph, do: @graph

  def exclusion_filter(variable \\ "?doc") do
    """
    FILTER NOT EXISTS {
      GRAPH <#{@graph}> {
        ?workspace a sheaf:Workspace ;
          sheaf:excludesDocument #{variable} .
      }
    }
    """
    |> String.trim()
  end

  defp create_default do
    workspace = Sheaf.mint()

    case Sheaf.Repo.assert(workspace_resource_graph(workspace)) do
      :ok -> {:ok, workspace |> RDF.Term.value() |> to_string()}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp load_workspace_graph do
    Sheaf.Repo.load_once({nil, nil, nil, RDF.iri(@graph)})
  end

  defp default_workspace(dataset) do
    dataset
    |> dataset_workspace_graph()
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {RDF.type(), DOC.Workspace}))
    |> Enum.map(&Description.subject/1)
    |> Enum.sort_by(&to_string/1)
    |> List.first()
  end

  defp dataset_workspace_graph(dataset) do
    RDF.Dataset.graph(dataset, @graph) || Graph.new()
  end

  defp workspace_resource_graph(workspace) do
    RDF.Graph.new(
      RDF.Graph.build workspace: workspace, label: @label do
        @prefix RDF.NS.RDFS

        workspace
        |> a(Sheaf.NS.DOC.Workspace)
        |> RDFS.label(label)
      end,
      name: @graph
    )
  end

  defp exclusion_graph(workspace, document) do
    workspace_resource_graph(workspace)
    |> Graph.add({workspace, DOC.excludesDocument(), document})
  end

  defp exclusion_retraction_graph(document) do
    Sheaf.Repo.ask(fn dataset ->
      dataset
      |> dataset_workspace_graph()
      |> RDF.Data.descriptions()
      |> Enum.filter(&Description.include?(&1, {DOC.excludesDocument(), document}))
      |> Enum.reduce(Graph.new(name: @graph), fn description, graph ->
        Graph.add(graph, {Description.subject(description), DOC.excludesDocument(), document})
      end)
    end)
  end

  defp owner_graph(workspace, person) do
    workspace_resource_graph(workspace)
    |> Graph.add({workspace, DOC.hasWorkspaceOwner(), person})
  end

  defp workspace_owners(dataset, workspace) do
    dataset
    |> dataset_workspace_graph()
    |> RDF.Data.description(workspace)
    |> Description.get(DOC.hasWorkspaceOwner(), [])
  end
end
