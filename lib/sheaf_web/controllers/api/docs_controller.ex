defmodule SheafWeb.API.DocsController do
  @moduledoc """
  JSON API for live-node module and function documentation.
  """

  use SheafWeb, :controller

  def index(conn, params) do
    targets = targets(params)
    include_source = truthy?(Map.get(params, "source"))

    json(conn, Docs.describe(targets, include_source: include_source))
  end

  defp targets(%{"target" => targets}) when is_list(targets), do: targets
  defp targets(%{"target" => target}) when is_binary(target), do: [target]
  defp targets(_params), do: []

  defp truthy?(value) when value in ["1", "true", "yes", "on"], do: true
  defp truthy?(_value), do: false
end
