defmodule Mix.Tasks.Sheaf.ImportInterviews do
  use Mix.Task

  @shortdoc "Imports the IEVA interview transcript export into Fuseki"

  alias Sheaf.Interviews

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        switches: [db_path: :string, graph: :string, append: :boolean, max_update_bytes: :integer]
      )

    case invalid do
      [] ->
        import_opts =
          opts
          |> Keyword.put_new(:replace, not Keyword.get(opts, :append, false))
          |> Keyword.merge(positional_db_path(positional))
          |> Keyword.drop([:append])

        case Interviews.import(import_opts) do
          {:ok, result} ->
            Mix.shell().info(
              "Imported #{result.interviews} interviews, #{result.segments} segments, and #{result.utterances} utterances into #{result.graph}"
            )

          {:error, message} ->
            Mix.raise(message)

          other ->
            Mix.raise("Interview import failed: #{inspect(other)}")
        end

      _ ->
        Mix.raise(
          "Unrecognized arguments: #{Enum.map_join(invalid, " ", &Enum.join(Tuple.to_list(&1), "="))}"
        )
    end
  end

  defp positional_db_path([]), do: []
  defp positional_db_path([db_path | _rest]), do: [db_path: db_path]
end
