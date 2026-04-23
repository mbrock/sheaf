defmodule Mix.Tasks.Sheaf.SeedSample do
  use Mix.Task

  @shortdoc "Seeds a minimal sample thesis into the configured named graph"

  alias Sheaf.SampleData

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case SampleData.seed_sample_thesis() do
      {:ok, :already_present} ->
        Mix.shell().info("A thesis document is already present in the named graph; not seeding sample data.")

      {:ok, thesis_iri} ->
        Mix.shell().info("Seeded sample thesis at #{thesis_iri}")

      {:error, message} ->
        Mix.raise(message)

      other ->
        Mix.raise("Sample seed failed: #{inspect(other)}")
    end
  end
end
