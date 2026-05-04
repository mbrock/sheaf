defmodule Sheaf.Assistant.Chat do
  @moduledoc """
  Public facade and child spec for a long-lived assistant chat session.

  Each chat child is a small supervision tree. The chat server owns UI-visible
  conversation state and the ReqLLM assistant process; sibling processes own
  per-chat resources such as the in-memory spreadsheet DuckDB session.
  """

  alias Sheaf.Assistant.Chat

  @registry Sheaf.Assistant.ChatRegistry

  def start_link(opts) do
    Chat.Session.start_link(opts)
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :supervisor
    }
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  def exists?(id) when is_binary(id) do
    Registry.lookup(@registry, id) != []
  end

  def snapshot(server) do
    GenServer.call(server_ref(server), :snapshot)
  end

  def send_user_message(server, text, turn_context \\ %{}) do
    GenServer.call(server_ref(server), {:send_user_message, text, turn_context})
  end

  def persist_context(server) do
    GenServer.call(server_ref(server), :persist_context)
  end

  def put_model(server, model) do
    GenServer.call(server_ref(server), {:put_model, model})
  end

  def put_llm_options(server, opts) when is_list(opts) do
    GenServer.call(server_ref(server), {:put_llm_options, opts})
  end

  def subscribe(server, live_view, component, component_id) do
    GenServer.call(server_ref(server), {:subscribe, live_view, component, component_id})
  end

  def unsubscribe(server, live_view, component, component_id) do
    GenServer.cast(server_ref(server), {:unsubscribe, live_view, component, component_id})
  end

  defp server_ref(id) when is_binary(id), do: via(id)
  defp server_ref(other), do: other
end
