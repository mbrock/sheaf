defmodule Sheaf.Repo do
  @moduledoc """
  The application's named in-memory RDF dataset backed by Quadlog.
  """

  @workspace_graph "https://less.rest/sheaf/workspace"
  @metadata_graph "https://less.rest/sheaf/metadata"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    config = Application.get_env(:sheaf, __MODULE__, [])
    path = Keyword.get(opts, :path) || Keyword.fetch!(config, :path)

    with {:ok, pid} <-
           Quadlog.start_link(path,
             name: __MODULE__,
             pattern: {nil, nil, nil, RDF.iri(@workspace_graph)}
           ),
         :ok <- load({nil, nil, nil, RDF.iri(@metadata_graph)}) do
      {:ok, pid}
    end
  end

  def dataset, do: Quadlog.dataset(__MODULE__)
  def ask(fun), do: Quadlog.ask(__MODULE__, fun)
  def load(pattern), do: Quadlog.load(__MODULE__, pattern)
  def assert(tx, graph), do: Quadlog.assert(__MODULE__, tx, graph)
  def retract(tx, graph), do: Quadlog.retract(__MODULE__, tx, graph)
  def transact(tx, changes), do: Quadlog.transact(__MODULE__, tx, changes)

  def workspace_graph, do: @workspace_graph
  def metadata_graph, do: @metadata_graph
end
