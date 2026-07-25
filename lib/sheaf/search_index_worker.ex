defmodule Sheaf.SearchIndexWorker do
  @moduledoc """
  Coalesces derived search-index refreshes and runs them outside user requests.

  The RDF corpus remains authoritative. Import and metadata operations only
  mark the derived indexes dirty; this worker refreshes lexical search first,
  then embeddings, while publishing a small progress snapshot for LiveViews.
  """

  use GenServer

  require OpenTelemetry.Tracer, as: Tracer

  @topic "search-index:status"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @spec enqueue(String.t()) :: :ok
  def enqueue(reason \\ "Corpus changed") do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:enqueue, reason})
    end

    :ok
  end

  @spec status() :: map()
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      idle_status()
    end
  end

  def topic, do: @topic

  @impl true
  def init(opts) do
    {:ok,
     %{
       task: nil,
       pending?: false,
       reasons: [],
       status: idle_status(),
       search_sync:
         Keyword.get(opts, :search_sync, &Sheaf.Search.Index.sync/0),
       embedding_sync:
         Keyword.get(opts, :embedding_sync, &Sheaf.Embedding.Index.sync/1),
       task_supervisor:
         Keyword.get(opts, :task_supervisor, Sheaf.Assistant.TaskSupervisor)
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast({:enqueue, reason}, %{task: nil} = state) do
    state =
      state
      |> Map.update!(:reasons, &(&1 ++ [reason]))
      |> start_refresh()

    {:noreply, state}
  end

  def handle_cast({:enqueue, reason}, state) do
    {:noreply,
     state
     |> Map.put(:pending?, true)
     |> Map.update!(:reasons, &(&1 ++ [reason]))
     |> publish(%{
       state.status
       | queued?: true,
         message: state.status.message <> " · another refresh is queued"
     })}
  end

  @impl true
  def handle_info({:search_index_progress, progress}, state) do
    status =
      case progress do
        %{phase: :embedding, completed: completed, total: total} ->
          %{
            state.status
            | phase: :embedding,
              completed_count: completed,
              total_count: total,
              message: embedding_message(completed, total)
          }

        %{phase: phase, message: message} ->
          %{state.status | phase: phase, message: message}
      end

    {:noreply, publish(state, status)}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, summary} ->
          publish(state, completed_status(summary))

        {:error, reason} ->
          publish(state, failed_status(reason))
      end

    {:noreply, finish_or_restart(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{task: %{ref: ref}} = state
      ) do
    state = publish(state, failed_status(reason))
    {:noreply, finish_or_restart(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_refresh(state) do
    worker = self()
    reasons = Enum.uniq(state.reasons)
    search_sync = state.search_sync
    embedding_sync = state.embedding_sync

    status = %{
      running?: true,
      queued?: false,
      phase: :search,
      completed_count: 0,
      total_count: nil,
      message: "Updating text search",
      error: nil,
      reasons: reasons
    }

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Tracer.with_span "Sheaf.SearchIndexWorker.refresh", %{
          kind: :internal,
          attributes: [
            {"sheaf.search_index.reason_count", length(reasons)},
            {"sheaf.search_index.reasons", Enum.join(reasons, "\n")}
          ]
        } do
          with {:ok, search} <- search_sync.() do
            send(
              worker,
              {:search_index_progress,
               %{phase: :planning, message: "Checking search embeddings"}}
            )

            notify = fn
              {:planned, total, missing, _skipped} ->
                send(
                  worker,
                  {:search_index_progress,
                   %{
                     phase: :embedding,
                     completed: 0,
                     total: missing,
                     target: total
                   }}
                )

              {:progress, completed, total, _errors} ->
                send(
                  worker,
                  {:search_index_progress,
                   %{phase: :embedding, completed: completed, total: total}}
                )

              {:vectors, count} ->
                send(
                  worker,
                  {:search_index_progress,
                   %{
                     phase: :vectors,
                     message: "Publishing #{count} search vectors"
                   }}
                )

              _event ->
                :ok
            end

            case embedding_sync.(notify: notify) do
              {:ok, embedding} ->
                {:ok, %{search: search, embedding: embedding}}

              {:error, reason} ->
                {:error, reason}
            end
          end
        end
      end)

    state
    |> Map.put(:task, task)
    |> Map.put(:pending?, false)
    |> Map.put(:reasons, [])
    |> publish(status)
  end

  defp finish_or_restart(%{pending?: true} = state) do
    state
    |> Map.put(:task, nil)
    |> start_refresh()
  end

  defp finish_or_restart(state) do
    %{state | task: nil, pending?: false, reasons: []}
  end

  defp publish(state, status) do
    if Process.whereis(Sheaf.PubSub) do
      Phoenix.PubSub.broadcast(
        Sheaf.PubSub,
        @topic,
        {:search_index_status, status}
      )
    end

    %{state | status: status}
  end

  defp completed_status(%{embedding: %{error_count: errors} = embedding})
       when errors > 0 do
    %{
      running?: false,
      queued?: false,
      phase: :error,
      completed_count: embedding.embedded_count,
      total_count: max(embedding.target_count - embedding.skipped_count, 0),
      message: "Search update incomplete",
      error: "#{errors} embeddings failed",
      reasons: []
    }
  end

  defp completed_status(%{embedding: embedding}) do
    %{
      running?: false,
      queued?: false,
      phase: :complete,
      completed_count: embedding.embedded_count,
      total_count: max(embedding.target_count - embedding.skipped_count, 0),
      message: "Search is up to date",
      error: nil,
      reasons: []
    }
  end

  defp failed_status(reason) do
    %{
      running?: false,
      queued?: false,
      phase: :error,
      completed_count: 0,
      total_count: nil,
      message: "Search update failed",
      error: inspect(reason),
      reasons: []
    }
  end

  defp idle_status do
    %{
      running?: false,
      queued?: false,
      phase: :idle,
      completed_count: 0,
      total_count: nil,
      message: "Search is up to date",
      error: nil,
      reasons: []
    }
  end

  defp embedding_message(_completed, 0),
    do: "Search embeddings are already up to date"

  defp embedding_message(_completed, _total),
    do: "Creating search embeddings"
end
