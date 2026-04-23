defmodule Mix.Tasks.Sheaf.MigrateParagraphs do
  use Mix.Task

  @shortdoc "Migrates inline text blocks to append-only paragraph revisions"

  alias Sheaf.Fuseki
  alias Sheaf.GraphMigration
  alias Sheaf.Interviews

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args,
        switches: [all: :boolean, graph: :string, max_update_bytes: :integer]
      )

    case invalid do
      [] ->
        opts
        |> target_graphs()
        |> Enum.each(fn graph_name ->
          case GraphMigration.migrate_graph(graph_name, opts) do
            {:ok, result} ->
              Mix.shell().info(
                "Migrated #{result.migrated_blocks} blocks in #{graph_name} and wrote #{result.statements} statements"
              )

            {:error, message} ->
              Mix.raise(message)
          end
        end)

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp target_graphs(opts) do
    cond do
      Keyword.get(opts, :all, false) ->
        [Fuseki.graph(), Interviews.graph()] |> Enum.uniq()

      graph_name = Keyword.get(opts, :graph) ->
        [graph_name]

      true ->
        [Fuseki.graph(), Interviews.graph()] |> Enum.uniq()
    end
  end
end
