defmodule Sheaf.Workspace do
  @moduledoc """
  Workspace-level reading preferences stored as RDF.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.Id
  alias Sheaf.NS.DOC
  require RDF.Graph
  use RDF

  @graph ~I<https://less.rest/sheaf/workspace>

  @doc """
  Returns the IRI for the default workspace, creating it when needed.
  """
  def default do
    Sheaf.Repo.ask(&default_workspace/1) || create_default()
  end

  @doc """
  Records whether a document is excluded from the active workspace corpus.
  """
  def set_document_excluded(document_id, excluded?) when is_binary(document_id) do
    document = Id.iri(document_id)
    mode = if excluded?, do: :assert, else: :retract

    Sheaf.Repo.transact([
      {mode, Graph.new({default(), DOC.excludesDocument(), document}, name: @graph)}
    ])
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
    :ok = Sheaf.Repo.assert(Graph.new({workspace, RDF.type(), DOC.Workspace}, name: @graph))
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
end
