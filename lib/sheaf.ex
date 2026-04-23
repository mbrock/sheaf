defmodule Sheaf do
  @moduledoc """
  """

  @doc """
  Generates a new unique IRI for a resource.
  """
  def mint do
    Sheaf.Id.iri(Sheaf.Id.generate())
  end

  def fetch_graph(graph_name) when is_binary(graph_name) do
    """
    CONSTRUCT { ?s ?p ?o } WHERE { ?s ?p ?o . }
    """
    |> SPARQL.Client.construct(query_endpoint(),
      default_graph: graph_name
    )
  end

  defp query_endpoint, do: Application.get_env(:sheaf, __MODULE__, [])[:query_endpoint]
end
