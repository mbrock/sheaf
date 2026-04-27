defmodule Sheaf.Workspace do
  @moduledoc """
  Workspace-level reading preferences stored as RDF.
  """

  alias Sheaf.Id

  @graph "https://less.rest/sheaf/workspace"
  @label "Ieva's thesis workspace"

  @doc """
  Returns the IRI for the default workspace, creating it when needed.
  """
  def ensure_default do
    case Sheaf.select("default workspace select", default_workspace_query()) do
      {:ok, %{results: [row | _]}} ->
        {:ok, row |> Map.fetch!("workspace") |> RDF.Term.value() |> to_string()}

      {:ok, %{results: []}} ->
        create_default()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records whether a document is excluded from the active workspace corpus.
  """
  def set_document_excluded(document_id, excluded?) when is_binary(document_id) do
    document = Id.iri(document_id) |> to_string()

    if excluded? do
      with {:ok, workspace} <- ensure_default() do
        Sheaf.update("workspace exclusion insert", insert_exclusion_update(workspace, document))
      end
    else
      Sheaf.update("workspace exclusion delete", delete_exclusion_update(document))
    end
  end

  @doc """
  Records the person whose authored work the active workspace is organized around.
  """
  def set_owner(person_id) when is_binary(person_id) do
    person = Id.iri(person_id) |> to_string()

    with {:ok, workspace} <- ensure_default() do
      Sheaf.update("workspace owner insert", insert_owner_update(workspace, person))
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
    workspace = Sheaf.mint() |> to_string()

    case Sheaf.update("default workspace insert", insert_workspace_update(workspace)) do
      :ok -> {:ok, workspace}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp default_workspace_query do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>

    SELECT ?workspace WHERE {
      GRAPH <#{@graph}> {
        ?workspace a sheaf:Workspace .
      }
    }
    ORDER BY ?workspace
    LIMIT 1
    """
  end

  defp insert_workspace_update(workspace) do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    INSERT DATA {
      GRAPH <#{@graph}> {
        <#{workspace}> a sheaf:Workspace ;
          rdfs:label "#{@label}" .
      }
    }
    """
  end

  defp insert_exclusion_update(workspace, document) do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    INSERT DATA {
      GRAPH <#{@graph}> {
        <#{workspace}> a sheaf:Workspace ;
          rdfs:label "#{@label}" ;
          sheaf:excludesDocument <#{document}> .
      }
    }
    """
  end

  defp insert_owner_update(workspace, person) do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    DELETE {
      GRAPH <#{@graph}> {
        <#{workspace}> sheaf:hasWorkspaceOwner ?previous .
      }
    }
    INSERT {
      GRAPH <#{@graph}> {
        <#{workspace}> a sheaf:Workspace ;
          rdfs:label "#{@label}" ;
          sheaf:hasWorkspaceOwner <#{person}> .
      }
    }
    WHERE {
      OPTIONAL {
        GRAPH <#{@graph}> {
          <#{workspace}> sheaf:hasWorkspaceOwner ?previous .
        }
      }
    }
    """
  end

  defp delete_exclusion_update(document) do
    """
    PREFIX sheaf: <https://less.rest/sheaf/>

    DELETE WHERE {
      GRAPH <#{@graph}> {
        ?workspace sheaf:excludesDocument <#{document}> .
      }
    }
    """
  end
end
