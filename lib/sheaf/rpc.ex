defmodule Sheaf.RPC do
  @moduledoc "Run code on the live Sheaf node with IO routed to the caller."

  @doc """
  Evaluates an Elixir code string with its group leader set to `gl`.

  This is called by `bin/rpc` so debugging code runs inside the already-running
  Sheaf application instead of starting a second application instance.
  """
  def eval(gl, code) when is_pid(gl) and is_binary(code) do
    Process.group_leader(self(), gl)
    {result, _bindings} = Code.eval_string(code)
    result
  end
end
