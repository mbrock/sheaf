defmodule Mix.Tasks.Sheaf.Smoke do
  use Mix.Task

  @shortdoc "Verifies named-graph read/write access against Fuseki"

  alias SPARQL.Query.Result
  alias Sheaf.Fuseki
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
      Mix.shell().info("Fuseki named-graph smoke test passed for #{Fuseki.graph()}")
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
    update = """
    INSERT DATA {
      GRAPH #{Fuseki.graph_ref()} {
        #{Fuseki.iri_ref(probe_iri)} #{Fuseki.iri_ref(SheafNS.title())} #{Fuseki.literal(probe_value)} .
      }
    }
    """

    Fuseki.update(update)
  end

  defp read_probe(probe_iri, probe_value) do
    query = """
    SELECT ?value
    WHERE {
      GRAPH #{Fuseki.graph_ref()} {
        #{Fuseki.iri_ref(probe_iri)} #{Fuseki.iri_ref(SheafNS.title())} ?value .
      }
    }
    """

    case Fuseki.select(query) do
      {:ok, %Result{results: [%{"value" => %RDF.Literal{} = literal} | _]}} ->
        {:ok, to_string(RDF.Term.value(literal)) == probe_value}

      {:ok, %Result{results: []}} ->
        {:ok, false}

      error ->
        error
    end
  end

  defp delete_probe(probe_iri) do
    update = """
    DELETE WHERE {
      GRAPH #{Fuseki.graph_ref()} {
        #{Fuseki.iri_ref(probe_iri)} ?predicate ?object .
      }
    }
    """

    Fuseki.update(update)
  end
end
