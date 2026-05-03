defmodule Sheaf.Assistant.Chat.Session do
  @moduledoc """
  Supervision tree for one assistant chat conversation.
  """

  use Supervisor

  alias Sheaf.Assistant.{Chat, SpreadsheetSession}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    spreadsheet_opts =
      [id: id]
      |> put_if_present(:directory, Keyword.get(opts, :spreadsheet_directory))
      |> put_if_present(:workspace_graph, Keyword.get(opts, :spreadsheet_workspace_graph))
      |> put_if_present(:blob_root, Keyword.get(opts, :spreadsheet_blob_root))

    server_opts =
      opts
      |> Keyword.put(:spreadsheet_session, SpreadsheetSession.via(id))

    children = [
      {SpreadsheetSession, spreadsheet_opts},
      {Chat.Server, server_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)
end
