defmodule Sheaf.Tracing.RedisSink do
  @moduledoc """
  GenServer that buffers OpenTelemetry spans in its mailbox and ships them to a
  Redis Stream as JSON-encoded entries, pipelining batches for throughput.

  Spans are produced by `Sheaf.Tracing.RedisSinkProcessor` (an
  `otel_span_processor`) which forwards each ended span as a `{:span, span}`
  message. The sink drains its mailbox in batches and issues a single Redis
  pipeline of `XADD` commands per batch, which keeps localhost throughput well
  above whatever the BEAM produces under realistic load.

  The Redis stream is trimmed to roughly `:maxlen` entries via the approximate
  `XADD ... MAXLEN ~` form so that long-running nodes don't accumulate spans
  forever.
  """

  use GenServer
  require Logger
  require Record

  alias Sheaf.Tracing.SpanEncoder

  @default_redis_url "redis://localhost:6379"
  @default_stream "otel:spans"
  @default_maxlen 1_000_000
  @default_max_batch 200

  Record.defrecord(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @typep span_record :: tuple()

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a span for asynchronous shipping. Called from an OTel processor."
  @spec enqueue(span_record()) :: :ok
  def enqueue(span) when is_tuple(span) and elem(span, 0) == :span do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        send(pid, {:span, span})
        :ok
    end
  end

  @doc "Block until any buffered spans have been sent to Redis."
  def flush(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :flush, timeout)
  catch
    :exit, _ -> :ok
  end

  ## GenServer

  @impl true
  def init(opts) do
    redis_url = Keyword.get(opts, :redis_url, @default_redis_url)
    stream = Keyword.get(opts, :stream, @default_stream)
    maxlen = Keyword.get(opts, :maxlen, @default_maxlen)
    max_batch = Keyword.get(opts, :max_batch, @default_max_batch)

    {:ok, redix} =
      Redix.start_link(redis_url, name: nil, exit_on_disconnection: false)

    {:ok,
     %{
       redix: redix,
       stream: stream,
       maxlen: maxlen,
       max_batch: max_batch,
       dropped: 0
     }}
  end

  @impl true
  def handle_info({:span, span}, state) do
    spans = drain([span], state.max_batch - 1)
    state = ship(spans, state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, state) do
    spans = drain([], state.max_batch)
    state = if spans == [], do: state, else: ship(spans, state)
    {:reply, :ok, state}
  end

  ## Internals

  # Pull as many already-queued span messages out of the mailbox as we can
  # without waiting. Bounded by `remaining` to keep batches reasonable; the
  # next `handle_info` cycle will pick up anything left over.
  defp drain(acc, 0), do: Enum.reverse(acc)

  defp drain(acc, remaining) do
    receive do
      {:span, span} -> drain([span | acc], remaining - 1)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ship([], state), do: state

  defp ship(spans, %{redix: redix, stream: stream, maxlen: maxlen} = state) do
    commands =
      Enum.map(spans, fn span ->
        json = Jason.encode_to_iodata!(SpanEncoder.to_map(span))

        [
          "XADD",
          stream,
          "MAXLEN",
          "~",
          Integer.to_string(maxlen),
          "*",
          "data",
          json
        ]
      end)

    case Redix.pipeline(redix, commands, timeout: 5_000) do
      {:ok, _ids} ->
        state

      {:error, reason} ->
        # Drop the batch on the floor rather than backing up the mailbox while
        # Redis is unreachable. We log once per batch with the count to keep
        # the noise floor low.
        Logger.warning(
          "RedisSink dropped #{length(spans)} spans: #{inspect(reason)} (total dropped: #{state.dropped + length(spans)})"
        )

        %{state | dropped: state.dropped + length(spans)}
    end
  end
end
