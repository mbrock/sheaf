defmodule Mix.Tasks.Sheaf.Schema do
  @moduledoc """
  Uploads `priv/sheaf-schema.ttl` to the configured schema named graph.
  """

  use Mix.Task

  @shortdoc "Uploads priv/sheaf-schema.ttl to the schema named graph"

  alias RDF.Serialization
  alias Sheaf.NS.DOC

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Sheaf.put_graph(DOC.__base_iri__(), Serialization.read_file!(schema_path()))
    Mix.shell().info("Uploaded schema graph #{DOC.__base_iri__()}")
  end

  defp schema_path do
    Application.app_dir(:sheaf, "priv/sheaf-schema.ttl")
  end
end
