defmodule Sheaf.TaskQueue do
  @moduledoc """
  Small durable task queue facade.
  """

  alias Sheaf.TaskQueue.Store

  @type conn :: Store.conn()

  @spec open(keyword()) :: {:ok, conn()} | {:error, term()}
  def open(opts \\ []), do: Store.open(opts)

  @spec close(conn()) :: :ok | {:error, term()}
  def close(conn), do: Store.close(conn)

  @spec create_batch(map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def create_batch(attrs, tasks, opts \\ []) do
    with_conn(opts, &Store.create_batch(&1, attrs, tasks))
  end

  @spec create_task(String.t(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_task(batch_iri, attrs, task, opts \\ []) do
    with_conn(opts, &Store.create_task(&1, batch_iri, attrs, task))
  end

  @spec list_batches(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_batches(opts \\ []) do
    with_conn(opts, &Store.list_batches(&1, opts))
  end

  @spec list_tasks(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tasks(opts \\ []) do
    with_conn(opts, &Store.list_tasks(&1, opts))
  end

  @spec claim_task(keyword()) :: {:ok, map() | nil} | {:error, term()}
  def claim_task(opts \\ []) do
    with_conn(opts, &Store.claim_task(&1, opts))
  end

  @spec complete_task(integer(), map(), keyword()) :: :ok | {:error, term()}
  def complete_task(task_id, result \\ %{}, opts \\ []) do
    with_conn(opts, &Store.complete_task(&1, task_id, result))
  end

  @spec fail_task(integer(), term(), keyword()) :: :ok | {:error, term()}
  def fail_task(task_id, reason, opts \\ []) do
    with_conn(opts, &Store.fail_task(&1, task_id, reason, opts))
  end

  defp with_conn(opts, fun) do
    case Keyword.fetch(opts, :conn) do
      {:ok, conn} ->
        fun.(conn)

      :error ->
        with {:ok, conn} <- Store.open(opts) do
          try do
            fun.(conn)
          after
            Store.close(conn)
          end
        end
    end
  end
end
