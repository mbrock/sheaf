defmodule Sheaf.Env do
  @moduledoc """
  Loads Sheaf environment files.

  Sheaf's `.env` files are shell fragments because the local service scripts
  source them directly. This module gives Elixir entrypoints the same semantics
  instead of maintaining a separate dotenv parser.
  """

  @doc """
  Sources `path` with bash and merges the resulting environment into this VM.
  """
  def load_file!(path) when is_binary(path) do
    script = """
    set -a
    . "$1"
    set +a
    env -0
    """

    case System.cmd("bash", ["-c", script, "sheaf-env", path], stderr_to_stdout: true) do
      {env, 0} ->
        env
        |> String.split(<<0>>, trim: true)
        |> Enum.each(&put_env_entry/1)

        :ok

      {output, status} ->
        raise Sheaf.Admin.Error,
              "could not load #{path}: bash exited with #{status}: #{String.trim(output)}"
    end
  end

  defp put_env_entry(entry) do
    case String.split(entry, "=", parts: 2) do
      [key, value] when key != "" -> System.put_env(key, value)
      _ -> :ok
    end
  end
end
