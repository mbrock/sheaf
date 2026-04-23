defmodule Mix.Tasks.Sheaf.ImportXml do
  use Mix.Task

  @shortdoc "Imports thesis XML files from priv into the main Sheaf graph"

  alias Sheaf.ThesisXml

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args, switches: [append: :boolean, max_update_bytes: :integer])

    case invalid do
      [] ->
        import_opts =
          opts
          |> Keyword.put_new(:replace, not Keyword.get(opts, :append, false))
          |> Keyword.put(:paths, positional_paths(positional))
          |> Keyword.drop([:append])

        case ThesisXml.import(import_opts) do
          {:ok, result} ->
            Mix.shell().info(
              "Imported #{result.documents} XML sources into #{result.graph} as #{result.title}"
            )

          {:error, message} ->
            Mix.raise(message)

          other ->
            Mix.raise("XML import failed: #{inspect(other)}")
        end

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp positional_paths([]), do: ThesisXml.default_paths()
  defp positional_paths(paths), do: paths
end
