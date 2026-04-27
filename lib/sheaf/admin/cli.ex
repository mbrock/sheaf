defmodule Sheaf.Admin.CLI do
  @moduledoc """
  Command-line entrypoint for Sheaf operational jobs.
  """

  @usage """
  Usage:
    sheaf-admin backup [--output PATH] [--timeout MS] [--no-copy]
    sheaf-admin schema upload
    sheaf-admin ingest files PATH... [--recursive] [--extensions pdf,docx] [--dry-run] [--no-backup]
    sheaf-admin import datalab-json PATH [--title TITLE] [--pdf PDF] [--no-backup]
    sheaf-admin import spreadsheet PATH [--title TITLE] [--graph IRI] [--no-backup]
    sheaf-admin search sync [--db PATH] [--limit N] [--kind KIND]
    sheaf-admin embeddings sync [--db PATH] [--limit N] [--kind KIND] [--provider NAME] [--model NAME]
    sheaf-admin datalab {submit|poll|import|status} [--job IRI] [--limit N] [--await]
    sheaf-admin metadata enqueue [--all|--missing-only] [--limit N] [--doc IRI] [--telegram]
    sheaf-admin metadata work [--limit N] [--concurrency N] [--telegram]
    sheaf-admin metadata list [--tasks] [--limit N] [--status STATUS]
    sheaf-admin metadata resolve [--dry-run] [--file-data] [--all|--missing-only] [--limit N] [--doc IRI]
  """

  def main(args) do
    checkout_root = checkout_root()
    System.put_env("SHEAF_CHECKOUT_ROOT", checkout_root)
    load_dot_env_from_checkout(checkout_root)
    prepend_build_paths(checkout_root)

    case dispatch(args) do
      :help ->
        IO.write(@usage)

      {:run, fun} ->
        start_app!()
        fun.()

      {:error, message} ->
        IO.puts(:stderr, "sheaf-admin: #{message}\n")
        IO.write(:stderr, @usage)
        System.halt(1)
    end
  rescue
    error in Sheaf.Admin.Error ->
      IO.puts(:stderr, "sheaf-admin: #{Exception.message(error)}")
      System.halt(1)

    error ->
      IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
      System.halt(1)
  end

  defp dispatch([]), do: :help
  defp dispatch(["help" | _]), do: :help
  defp dispatch(["--help" | _]), do: :help
  defp dispatch(["-h" | _]), do: :help

  defp dispatch(["backup" | args]), do: run(fn -> Sheaf.Admin.backup(args) end)
  defp dispatch(["schema", "upload" | args]), do: run(fn -> Sheaf.Admin.upload_schema(args) end)
  defp dispatch(["ingest", "files" | args]), do: run(fn -> Sheaf.Admin.ingest_files(args) end)

  defp dispatch(["import", "datalab-json" | args]),
    do: run(fn -> Sheaf.Admin.import_datalab_json(args) end)

  defp dispatch(["import", "spreadsheet" | args]),
    do: run(fn -> Sheaf.Admin.import_spreadsheet(args) end)

  defp dispatch(["search", "sync" | args]), do: run(fn -> Sheaf.Admin.sync_search(args) end)

  defp dispatch(["embeddings", "sync" | args]),
    do: run(fn -> Sheaf.Admin.sync_embeddings(args) end)

  defp dispatch(["datalab" | args]), do: run(fn -> Sheaf.Admin.Datalab.run(args) end)

  defp dispatch(["metadata", "enqueue" | args]),
    do: run(fn -> Sheaf.Admin.enqueue_metadata(args) end)

  defp dispatch(["metadata", "work" | args]), do: run(fn -> Sheaf.Admin.work_metadata(args) end)

  defp dispatch(["metadata", "list" | args]),
    do: run(fn -> Sheaf.Admin.list_metadata_tasks(args) end)

  defp dispatch(["metadata", "resolve" | args]),
    do: run(fn -> Sheaf.Admin.resolve_metadata(args) end)

  defp dispatch([command | _]), do: {:error, "unknown command: #{command}"}

  defp run(fun), do: {:run, fun}

  defp start_app! do
    case Application.ensure_all_started(:sheaf) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise Sheaf.Admin.Error, "could not start Sheaf: #{inspect(reason)}"
    end
  end

  defp checkout_root do
    case :escript.script_name() do
      [] -> File.cwd!()
      path -> Path.dirname(List.to_string(path))
    end
    |> checkout_dirs()
    |> Enum.find_value(fn dir ->
      if File.regular?(Path.join(dir, "mix.exs")), do: dir
    end)
    |> case do
      nil -> File.cwd!()
      dir -> dir
    end
  end

  defp load_dot_env_from_checkout(checkout_root) do
    checkout_root
    |> checkout_dirs()
    |> Enum.find_value(fn dir ->
      path = Path.join(dir, ".env")
      if File.regular?(path), do: path
    end)
    |> case do
      nil -> :ok
      path -> Sheaf.Env.load_file!(path)
    end
  end

  defp prepend_build_paths(checkout_root) do
    mix_env = System.get_env("MIX_ENV", "dev")
    lib_dir = Path.join([checkout_root, "_build", mix_env, "lib"])

    lib_dir
    |> Path.join("*/ebin")
    |> Path.wildcard()
    |> Enum.sort(:desc)
    |> Enum.each(&Code.prepend_path/1)
  end

  defp checkout_dirs(dir) do
    dir
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while([], fn current, acc ->
      cond do
        length(acc) >= 6 -> {:halt, Enum.reverse(acc)}
        current in acc -> {:halt, Enum.reverse(acc)}
        true -> {:cont, [current | acc]}
      end
    end)
  end
end
