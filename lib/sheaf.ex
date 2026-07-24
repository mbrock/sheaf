defmodule Sheaf do
  @moduledoc """
  Core helpers for minting resource IRIs and working with Sheaf's RDF store.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.{Data, Dataset, Graph}

  @doc """
  Generates a new unique IRI for a resource.
  """
  def mint do
    Sheaf.Id.iri(Sheaf.Id.generate())
  end

  @doc """
  Fetches a named graph from Quadlog.
  """
  def fetch_graph(graph_name) do
    graph_name = RDF.iri(graph_name)

    Tracer.with_span "sheaf.fetch_graph", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "fetch_graph"},
        {"sheaf.graph", to_string(graph_name)}
      ]
    } do
      with :ok <- Sheaf.Repo.load_once({nil, nil, nil, graph_name}) do
        graph =
          Sheaf.Repo.ask(fn dataset ->
            Dataset.graph(dataset, graph_name) || Graph.new(name: graph_name)
          end)

        Tracer.set_attribute(
          "sheaf.statement_count",
          Data.statement_count(graph)
        )

        {:ok, graph}
      end
    end
  end

  @doc """
  Replaces a named graph in Quadlog.
  """
  def put_graph(graph_name, %Graph{} = graph) do
    put_graph(graph_name, graph, [])
  end

  @doc """
  Replaces a named graph and applies related RDF changes atomically.

  This is useful when the graph is not valid without accompanying metadata:
  callers either observe the complete resource or no change at all.
  """
  def put_graph(graph_name, %Graph{} = graph, related_changes)
      when is_list(related_changes) do
    graph_name = RDF.iri(graph_name)
    graph = Graph.change_name(graph, graph_name)

    Tracer.with_span "sheaf.put_graph", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "put_graph"},
        {"sheaf.graph", to_string(graph_name)},
        {"sheaf.statement_count", Data.statement_count(graph)},
        {"sheaf.related_change_count", length(related_changes)}
      ]
    } do
      replace_graph(graph_name, graph, related_changes)
    end
  end

  @doc """
  SPARQL querying was removed with the Quadlog migration.
  """
  def query(_label, _query, _opts \\ []), do: {:error, :sparql_removed}

  @doc """
  SPARQL querying was removed with the Quadlog migration.
  """
  def select(_label, _query, _opts \\ []), do: {:error, :sparql_removed}

  @doc """
  SPARQL updates were removed with the Quadlog migration.
  """
  def update(_label, _update, _opts \\ []), do: {:error, :sparql_removed}

  @doc false
  def rpc_eval(gl, code) when is_pid(gl) and is_binary(code) do
    Process.group_leader(self(), gl)

    try do
      {result, _bindings} = Code.eval_string(code, [], file: "bin/rpc")
      {:ok, result}
    rescue
      error ->
        {:error, Exception.format(:error, error, __STACKTRACE__)}
    catch
      kind, reason ->
        {:error, Exception.format(kind, reason, __STACKTRACE__)}
    end
  end

  defp replace_graph(graph_name, %Graph{} = graph, related_changes) do
    with :ok <- Sheaf.Repo.load_once({nil, nil, nil, graph_name}) do
      old_graph =
        Dataset.graph(Sheaf.Repo.dataset(), graph_name) ||
          Graph.new(name: graph_name)

      Sheaf.Repo.transact(
        "replace #{graph_name}",
        [
          {:retract, old_graph},
          {:assert, graph}
        ] ++ related_changes
      )
    end
  end
end
