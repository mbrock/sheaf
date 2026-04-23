defmodule Mix.Tasks.Sheaf.Smoke do
  use Mix.Task

  @shortdoc "Verifies named-graph read/write access against the configured SPARQL store"

  alias RDF.Graph
  alias Sheaf.GraphStore
  alias Sheaf.Id
  alias Sheaf.NS.Sheaf, as: SheafNS

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    probe_id = "SMK" <> Id.generate()
    probe_iri = Id.iri(probe_id)
    probe_value = "smoke #{probe_id}"

    with :ok <- insert_probe(probe_iri, probe_value),
         {:ok, true} <- read_probe(probe_iri, probe_value),
         :ok <- delete_probe(probe_iri) do
      Mix.shell().info("Named-graph smoke test passed for #{GraphStore.default_graph()}")
    else
      {:ok, false} ->
        Mix.raise("Probe triple was not visible after insert")

      {:error, message} ->
        Mix.raise(message)

      error ->
        Mix.raise("Smoke test failed: #{inspect(error)}")
    end
  end

  defp insert_probe(probe_iri, probe_value) do
    GraphStore.insert_graph(
      GraphStore.default_graph(),
      Graph.new({probe_iri, SheafNS.title(), probe_value}, name: GraphStore.default_graph())
    )
  end

  defp read_probe(probe_iri, probe_value) do
    with {:ok, graph} <- GraphStore.fetch_graph() do
      value =
        graph
        |> Graph.description(probe_iri)
        |> RDF.Description.first(SheafNS.title())

      {:ok, match?(%RDF.Literal{}, value) and to_string(RDF.Term.value(value)) == probe_value}
    end
  end

  defp delete_probe(probe_iri) do
    GraphStore.delete_graph_data(
      GraphStore.default_graph(),
      Graph.new({probe_iri, SheafNS.title(), probe_value(probe_iri)},
        name: GraphStore.default_graph()
      )
    )
  end

  defp probe_value(probe_iri), do: "smoke " <> Id.id_from_iri(probe_iri)
end
