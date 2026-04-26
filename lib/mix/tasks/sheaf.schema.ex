defmodule Mix.Tasks.Sheaf.Schema do
  @moduledoc """
  Uploads the tracked schema and ontology support graphs.
  """

  use Mix.Task

  @shortdoc "Uploads tracked schema and ontology support graphs"

  alias RDF.Serialization
  alias Sheaf.NS.DOC

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Sheaf.put_graph(DOC.__base_iri__(), Serialization.read_file!(schema_path()))
    Mix.shell().info("Uploaded schema graph #{DOC.__base_iri__()}")

    Sheaf.put_graph(extension_graph(), Serialization.read_file!(extension_path()))
    Mix.shell().info("Uploaded schema extension graph #{extension_graph()}")

    Sheaf.put_graph(imported_ontologies_graph(), imported_ontologies())
    Mix.shell().info("Uploaded imported ontology graph #{imported_ontologies_graph()}")
  end

  defp schema_path do
    Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")
  end

  defp extension_path do
    Application.app_dir(:sheaf, "priv/sheaf-ext.ttl")
  end

  defp extension_graph, do: "https://less.rest/sheaf/ext"

  defp imported_ontologies do
    imported_ontology_paths()
    |> Enum.map(&Serialization.read_file!/1)
    |> Enum.reduce(RDF.Graph.new(), &RDF.Graph.add(&2, &1))
  end

  defp imported_ontology_paths do
    :sheaf
    |> Application.app_dir("priv/ontologies/*")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp imported_ontologies_graph, do: "https://less.rest/sheaf/imported-ontologies"
end
