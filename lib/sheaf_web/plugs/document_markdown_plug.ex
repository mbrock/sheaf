defmodule SheafWeb.DocumentMarkdownPlug do
  @moduledoc """
  Serves complete document exports at one-segment `.md` paths.

  All other requests continue unchanged to the content-negotiation plugs and
  Phoenix router.
  """

  import Plug.Conn

  alias SheafWeb.ReadController

  def init(opts), do: opts

  def call(%{method: "GET", path_info: [filename]} = conn, _opts) do
    case Regex.run(~r/^([A-Za-z0-9_-]+)\.md$/, filename) do
      [_filename, id] ->
        conn
        |> ReadController.export(%{"id" => id})
        |> halt()

      _other ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
