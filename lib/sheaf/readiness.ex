defmodule Sheaf.Readiness do
  @moduledoc """
  Tracks whether the application supervisor has finished starting.

  This process is intentionally placed last in the supervision tree. If it has
  started, the preceding application children started successfully too.
  """

  use GenServer

  @key {__MODULE__, :ready?}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def ready? do
    :persistent_term.get(@key, false)
  end

  @impl true
  def init(:ok) do
    :persistent_term.put(@key, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.put(@key, false)
    :ok
  end
end
