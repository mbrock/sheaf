defmodule Sheaf.Workspace do
  @moduledoc """
  Workspace-level reading preferences stored as RDF.
  """

  alias RDF.{Description, Graph}
  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.DOC
  require RDF.Graph
  use RDF

  @graph ~I<https://less.rest/sheaf/workspace>
  @label "Thesis workspace"

  @doc """
  Returns the IRI for the default workspace, creating it when needed.
  """
  def default do
    Sheaf.Repo.ask(&default_workspace/1) || create_default()
  end

  @doc """
  Returns the IRI for the default workspace in an `:ok` tuple.
  """
  def ensure_default, do: {:ok, default()}

  @doc """
  Records whether a document is excluded from the active workspace corpus.
  """
  def set_document_excluded(document_id, excluded?) when is_binary(document_id) do
    workspace = default()
    document = Id.iri(document_id)
    mode = if excluded?, do: :assert, else: :retract

    Sheaf.Repo.transact([
      {mode, Graph.new({workspace, DOC.excludesDocument(), document}, name: @graph)}
    ])
  end

  @doc """
  Records the person whose authored work the active workspace is organized around.
  """
  def set_owner(person_id) when is_binary(person_id) do
    workspace = default()
    person = Id.iri(person_id)
    previous = workspace_objects(workspace, DOC.hasWorkspaceOwner())

    changes =
      Enum.map(previous, fn owner ->
        {:retract, Graph.new({workspace, DOC.hasWorkspaceOwner(), owner}, name: @graph)}
      end) ++
        [{:assert, Graph.new({workspace, DOC.hasWorkspaceOwner(), person}, name: @graph)}]

    Sheaf.Repo.transact(changes)
  end

  @doc """
  Returns project-specific assistant instructions stored on the default workspace.
  """
  def assistant_instructions do
    if is_nil(Process.whereis(Sheaf.Repo)) do
      {:ok, nil}
    else
      assistant_instructions_from_repo()
    end
  end

  defp assistant_instructions_from_repo do
    workspace = default()

    instructions =
      workspace
      |> workspace_objects(DOC.assistantInstructions())
      |> Enum.find_value(&term_value/1)
      |> blank_to_nil()

    {:ok, instructions}
  end

  @doc """
  Stores project-specific assistant instructions on the default workspace.
  """
  def set_assistant_instructions(instructions) when is_binary(instructions) do
    workspace = default()
    instructions = String.trim(instructions)
    previous = workspace_objects(workspace, DOC.assistantInstructions())

    retractions =
      Enum.map(previous, fn old_instructions ->
        {:retract,
         Graph.new({workspace, DOC.assistantInstructions(), old_instructions}, name: @graph)}
      end)

    assertions =
      case instructions do
        "" ->
          []

        instructions ->
          [
            {:assert,
             Graph.new({workspace, DOC.assistantInstructions(), RDF.literal(instructions)},
               name: @graph
             )}
          ]
      end

    Sheaf.Repo.transact(retractions ++ assertions)
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

    graph =
      Graph.new(
        [
          {workspace, RDF.type(), DOC.Workspace},
          {workspace, RDFS.label(), RDF.literal(@label)}
        ],
        name: @graph
      )

    :ok = Sheaf.Repo.assert(graph)
    workspace
  end

  defp default_workspace(dataset) do
    dataset
    |> RDF.Dataset.get(@graph, Graph.new())
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {RDF.type(), DOC.Workspace}))
    |> Enum.map(&Description.subject/1)
    |> case do
      [workspace] -> workspace
      [] -> nil
      _ -> raise "multiple workspaces not implemented"
    end
  end

  defp workspace_objects(workspace, predicate) do
    Sheaf.Repo.ask(fn dataset ->
      dataset
      |> RDF.Dataset.get(@graph, Graph.new())
      |> RDF.Data.description(workspace)
      |> Description.get(predicate, [])
    end)
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
