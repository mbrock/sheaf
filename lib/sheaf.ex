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
  Fetches the default graph from Quadlog.
  """
  def fetch_graph do
    with {:ok, dataset} <- fetch_dataset() do
      {:ok, Dataset.default_graph(dataset)}
    end
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

        Tracer.set_attribute("sheaf.statement_count", Data.statement_count(graph))
        {:ok, graph}
      end
    end
  end

  @doc """
  Replaces a named graph in Quadlog.
  """
  def put_graph(graph_name, %Graph{} = graph) do
    graph_name = RDF.iri(graph_name)
    graph = Graph.change_name(graph, graph_name)

    Tracer.with_span "sheaf.put_graph", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "put_graph"},
        {"sheaf.graph", to_string(graph_name)},
        {"sheaf.statement_count", Data.statement_count(graph)}
      ]
    } do
      replace_graph(graph_name, graph)
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
    {result, _bindings} = Code.eval_string(code)
    result
  end

  @doc """
  Loads the whole dataset from Quadlog, applies `fun`, and replaces the dataset
  with the result.
  """
  def migrate(fun) when is_function(fun, 1) do
    Tracer.with_span "sheaf.migrate", %{kind: :internal} do
      with {:ok, dataset} <- fetch_dataset(),
           %Dataset{} = migrated_dataset <- fun.(dataset),
           :ok <- put_dataset(migrated_dataset) do
        Tracer.set_attribute("sheaf.statement_count", Data.statement_count(migrated_dataset))
        {:ok, migrated_dataset}
      end
    end
  end

  @doc """
  Fetches the whole dataset from Quadlog.
  """
  def fetch_dataset do
    Tracer.with_span "sheaf.fetch_dataset", %{
      kind: :internal,
      attributes: [{"db.system", "quadlog"}, {"db.operation", "fetch_dataset"}]
    } do
      with :ok <- Sheaf.Repo.load_once({nil, nil, nil, nil}) do
        dataset = Sheaf.Repo.dataset()
        Tracer.set_attribute("sheaf.statement_count", Data.statement_count(dataset))
        {:ok, dataset}
      end
    end
  end

  defp put_dataset(%Dataset{} = dataset) do
    Tracer.with_span "sheaf.put_dataset", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "put_dataset"},
        {"sheaf.statement_count", Data.statement_count(dataset)}
      ]
    } do
      Sheaf.Repo.transact("dataset replacement", fn current ->
        Enum.map(Dataset.graphs(current), &{:retract, &1}) ++
          Enum.map(Dataset.graphs(dataset), &{:assert, &1})
      end)
    end
  end

  defp replace_graph(graph_name, %Graph{} = graph) do
    with :ok <- Sheaf.Repo.load_once({nil, nil, nil, graph_name}) do
      old_graph = Dataset.graph(Sheaf.Repo.dataset(), graph_name) || Graph.new(name: graph_name)

      Sheaf.Repo.transact("replace #{graph_name}", [
        {:retract, old_graph},
        {:assert, graph}
      ])
    end
  end
end
