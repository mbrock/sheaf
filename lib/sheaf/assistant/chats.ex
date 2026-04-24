defmodule Sheaf.Assistant.Chats do
  @moduledoc """
  In-process index and factory for assistant chat sessions.
  """

  use GenServer

  alias Sheaf.Assistant.Chat
  alias Sheaf.Id

  @default_title "New chat"
  @default_kind :chat
  @supervisor Sheaf.Assistant.ChatSupervisor

  defstruct conversations: %{}, order: [], subscribers: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  def ensure_default(opts \\ []) do
    GenServer.call(__MODULE__, {:ensure_default, opts})
  end

  def create(opts \\ []) do
    GenServer.call(__MODULE__, {:create, opts})
  end

  def subscribe(live_view, component, component_id) do
    GenServer.call(__MODULE__, {:subscribe, live_view, component, component_id})
  end

  def touch(id, attrs \\ []) do
    GenServer.cast(__MODULE__, {:touch, id, attrs})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, list_from_state(state), state}
  end

  def handle_call({:ensure_default, opts}, _from, %{order: []} = state) do
    {reply, state} = create_conversation(state, opts)
    {:reply, reply, state}
  end

  def handle_call({:ensure_default, _opts}, _from, state) do
    [id | _] = state.order
    {:reply, Map.fetch!(state.conversations, id), state}
  end

  def handle_call({:create, opts}, _from, state) do
    {reply, state} = create_conversation(state, opts)
    {:reply, reply, state}
  end

  def handle_call({:subscribe, live_view, component, component_id}, _from, state) do
    state = put_subscriber(state, live_view, component, component_id)
    {:reply, list_from_state(state), state}
  end

  @impl true
  def handle_cast({:touch, id, attrs}, state) do
    state =
      case Map.fetch(state.conversations, id) do
        {:ok, conversation} ->
          conversation =
            conversation
            |> Map.merge(Map.new(attrs))
            |> Map.put(:updated_at, timestamp())

          %{state | conversations: Map.put(state.conversations, id, conversation)}
          |> move_to_front(id)
          |> broadcast_list()

        :error ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.reject(fn {_key, ref} -> ref == monitor_ref end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp create_conversation(state, opts) do
    id = Keyword.get_lazy(opts, :id, &mint_id/0)
    kind = opts |> Keyword.get(:kind, @default_kind) |> normalize_kind()
    title = Keyword.get_lazy(opts, :title, fn -> default_title(kind) end)
    now = timestamp()

    child_opts =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:kind, kind)
      |> Keyword.put_new(:title, title)

    case DynamicSupervisor.start_child(@supervisor, {Chat, child_opts}) do
      {:ok, _pid} ->
        conversation = %{id: id, title: title, kind: kind, created_at: now, updated_at: now}

        state =
          state
          |> put_conversation(conversation)
          |> broadcast_list()

        {conversation, state}

      {:error, {:already_started, _pid}} ->
        conversation = Map.fetch!(state.conversations, id)
        {conversation, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp put_conversation(state, conversation) do
    %{
      state
      | conversations: Map.put(state.conversations, conversation.id, conversation),
        order: [conversation.id | Enum.reject(state.order, &(&1 == conversation.id))]
    }
  end

  defp move_to_front(state, id) do
    %{state | order: [id | Enum.reject(state.order, &(&1 == id))]}
  end

  defp list_from_state(state) do
    Enum.map(state.order, &Map.fetch!(state.conversations, &1))
  end

  defp put_subscriber(state, live_view, component, component_id) do
    key = {live_view, component, component_id}

    if Map.has_key?(state.subscribers, key) do
      state
    else
      %{state | subscribers: Map.put(state.subscribers, key, Process.monitor(live_view))}
    end
  end

  defp broadcast_list(state) do
    chats = list_from_state(state)

    Enum.each(state.subscribers, fn {{live_view, component, component_id}, _ref} ->
      Phoenix.LiveView.send_update(live_view, component, id: component_id, assistant_chats: chats)
    end)

    state
  end

  defp mint_id do
    Sheaf.mint() |> Id.id_from_iri()
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp normalize_kind(:research), do: :research
  defp normalize_kind("research"), do: :research
  defp normalize_kind(_kind), do: :chat

  defp default_title(:research), do: "Research session"
  defp default_title(_kind), do: @default_title
end
