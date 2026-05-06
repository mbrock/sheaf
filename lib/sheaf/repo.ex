defmodule Sheaf.Repo do
  @moduledoc """
  The application's named in-memory RDF dataset backed by Quadlog.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @workspace_graph "https://less.rest/sheaf/workspace"
  @metadata_graph "https://less.rest/sheaf/metadata"

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    config = Application.get_env(:sheaf, __MODULE__, [])
    path = Keyword.get(opts, :path) || Keyword.fetch!(config, :path)

    Tracer.with_span "sheaf.repo.start", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "start"},
        {"db.name", path},
        {"sheaf.workspace_graph", @workspace_graph},
        {"sheaf.metadata_graph", @metadata_graph}
      ]
    } do
      with {:ok, pid} <-
             Quadlog.start_link(path,
               name: __MODULE__,
               pattern: {nil, nil, nil, RDF.iri(@workspace_graph)}
             ),
           :ok <- load({nil, nil, nil, RDF.iri(@metadata_graph)}) do
        Tracer.set_attribute(
          "sheaf.statement_count",
          RDF.Data.statement_count(dataset())
        )

        {:ok, pid}
      end
    end
  end

  def dataset do
    Tracer.with_span "sheaf.repo.dataset", %{kind: :internal} do
      dataset = Quadlog.dataset(__MODULE__)

      Tracer.set_attribute(
        "sheaf.statement_count",
        RDF.Data.statement_count(dataset)
      )

      dataset
    end
  end

  def path, do: Quadlog.path(__MODULE__)

  def ask(fun) do
    Tracer.with_span "sheaf.repo.ask", %{kind: :internal} do
      Quadlog.ask(__MODULE__, fun)
    end
  end

  def match(pattern) do
    Tracer.with_span "sheaf.repo.match", %{
      kind: :internal,
      attributes: pattern_attributes("match", pattern)
    } do
      case Quadlog.match(__MODULE__, pattern) do
        {:ok, dataset} = ok ->
          Tracer.set_attribute(
            "sheaf.statement_count",
            RDF.Data.statement_count(dataset)
          )

          ok

        error ->
          error
      end
    end
  end

  def match_rows(pattern) do
    Tracer.with_span "sheaf.repo.match_rows", %{
      kind: :internal,
      attributes: pattern_attributes("match_rows", pattern)
    } do
      case Quadlog.match_rows(__MODULE__, pattern) do
        {:ok, rows} = ok ->
          Tracer.set_attribute("sheaf.row_count", length(rows))
          ok

        error ->
          error
      end
    end
  end

  def load(pattern) do
    Tracer.with_span "sheaf.repo.load", %{
      kind: :internal,
      attributes: pattern_attributes("load", pattern)
    } do
      Quadlog.load(__MODULE__, pattern)
    end
  end

  def load_once(pattern) do
    Tracer.with_span "sheaf.repo.load_once", %{
      kind: :internal,
      attributes: pattern_attributes("load_once", pattern)
    } do
      Quadlog.load_once(__MODULE__, pattern)
    end
  end

  def clear_cache do
    Tracer.with_span "sheaf.repo.clear_cache", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "clear_cache"}
      ]
    } do
      Sheaf.Documents.clear_cache()

      with :ok <- Quadlog.clear_cache(__MODULE__),
           :ok <- load({nil, nil, nil, RDF.iri(@workspace_graph)}),
           :ok <- load({nil, nil, nil, RDF.iri(@metadata_graph)}) do
        set_dataset_count_attribute()
        :ok
      end
    end
  end

  def assert(graph), do: assert(Sheaf.mint(), graph)

  def assert(tx, graph),
    do:
      transact(
        tx,
        [{:assert, graph}],
        [{"sheaf.change", "assert"}] ++ graph_attributes(graph)
      )

  def retract(graph), do: retract(Sheaf.mint(), graph)

  def retract(tx, graph),
    do:
      transact(
        tx,
        [{:retract, graph}],
        [{"sheaf.change", "retract"}] ++ graph_attributes(graph)
      )

  def transact(changes), do: transact(Sheaf.mint(), changes)
  def transact(tx, changes), do: transact(tx, changes, [])

  def transact(tx, changes, metadata) do
    Tracer.with_span "sheaf.repo.transact", %{
      kind: :internal,
      attributes: tx_attributes(tx) ++ changes_attributes(changes) ++ metadata
    } do
      result = Quadlog.transact(__MODULE__, tx, changes)

      if result == :ok do
        Sheaf.Documents.clear_cache()
      end

      result
    end
  end

  def workspace_graph, do: @workspace_graph
  def metadata_graph, do: @metadata_graph

  defp set_dataset_count_attribute do
    Tracer.set_attribute(
      "sheaf.statement_count",
      RDF.Data.statement_count(Quadlog.dataset(__MODULE__))
    )
  end

  defp tx_attributes(tx),
    do: [
      {"db.system", "quadlog"},
      {"db.operation", "transact"},
      {"sheaf.tx", value(tx)}
    ]

  defp graph_attributes(graph) do
    [
      {"sheaf.graph", value(graph.name)},
      {"sheaf.statement_count", RDF.Data.statement_count(graph)}
    ]
  end

  defp changes_attributes(changes) when is_function(changes, 1) do
    [{"sheaf.changes", "function"}]
  end

  defp changes_attributes(changes) do
    [{"sheaf.change_count", length(changes)}]
  end

  defp pattern_attributes(operation, {subject, predicate, object, graph}) do
    [
      {"db.system", "quadlog"},
      {"db.operation", operation},
      {"sheaf.pattern.subject", value(subject)},
      {"sheaf.pattern.predicate", value(predicate)},
      {"sheaf.pattern.object", value(object)},
      {"sheaf.pattern.graph", value(graph)}
    ]
  end

  defp value(nil), do: nil
  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(term), do: RDF.Term.value(term) |> to_string()
end
