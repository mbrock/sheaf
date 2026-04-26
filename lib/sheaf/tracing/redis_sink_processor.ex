defmodule Sheaf.Tracing.RedisSinkProcessor do
  @moduledoc """
  An OpenTelemetry span processor that forwards every ended span to
  `Sheaf.Tracing.RedisSink` for asynchronous shipping to a Redis Stream.

  This is registered as one of the OpenTelemetry SDK's processors via
  `config :opentelemetry, :processors`. The SDK calls `start_link/1` once at
  boot to start whatever supporting process the module needs; we don't need a
  process here (the actual sink is started in our supervision tree alongside
  the rest of the app), so we return an idle dummy process.

  All the work happens in `on_end/2`, which is called synchronously by the
  process that ended the span. We do nothing more than `send/2` the span to
  the sink — that has to be O(1) because it runs inside every traced request.
  """

  @behaviour :otel_span_processor

  @spec start_link(term()) :: {:ok, pid(), map()}
  def start_link(config) do
    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid, config}
  end

  @impl :otel_span_processor
  def processor_init(_pid, config), do: config

  @impl :otel_span_processor
  def on_start(_ctx, span, _config), do: span

  @impl :otel_span_processor
  def on_end(span, _config) do
    Sheaf.Tracing.RedisSink.enqueue(span)
    true
  end

  @impl :otel_span_processor
  def force_flush(_config) do
    Sheaf.Tracing.RedisSink.flush()
  end
end
