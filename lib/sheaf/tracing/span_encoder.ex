defmodule Sheaf.Tracing.SpanEncoder do
  @moduledoc """
  Convert an OpenTelemetry `#span{}` Erlang record to a plain map suitable for
  JSON serialization onto the Redis Stream.

  The wire format is intentionally close to OTLP for legibility but uses
  snake_case field names directly accessible from any consumer language. IDs
  are rendered as lowercase hex strings (32 chars for trace_id, 16 for span_id)
  matching the W3C Trace Context format. Times are integer Unix nanoseconds
  derived from OTel's native monotonic-plus-offset timestamp.
  """

  require Record

  Record.defrecord(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecord(
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @doc "Convert a span record to a JSON-friendly map."
  def to_map(span_record) do
    fields = span(span_record)

    %{
      "trace_id" => hex_id(fields[:trace_id], 32),
      "span_id" => hex_id(fields[:span_id], 16),
      "parent_span_id" => hex_id(fields[:parent_span_id], 16),
      "name" => to_string(fields[:name]),
      "kind" => fields[:kind],
      "start_unix_nano" => to_unix_nano(fields[:start_time]),
      "end_unix_nano" => to_unix_nano(fields[:end_time]),
      "duration_us" => duration_us(fields[:start_time], fields[:end_time]),
      "status" => encode_status(fields[:status]),
      "attributes" => encode_attributes(fields[:attributes]),
      "events" => encode_events(fields[:events]),
      "scope" => encode_scope(fields[:instrumentation_scope])
    }
    |> drop_nils()
  end

  defp hex_id(nil, _), do: nil
  defp hex_id(0, _), do: nil
  defp hex_id(:undefined, _), do: nil

  defp hex_id(int, width) when is_integer(int) do
    int
    |> Integer.to_string(16)
    |> String.pad_leading(width, "0")
    |> String.downcase()
  end

  defp hex_id(_, _), do: nil

  defp to_unix_nano(nil), do: nil
  defp to_unix_nano(:undefined), do: nil

  defp to_unix_nano(timestamp) do
    :opentelemetry.timestamp_to_nano(timestamp)
  end

  defp duration_us(nil, _), do: nil
  defp duration_us(_, nil), do: nil
  defp duration_us(:undefined, _), do: nil
  defp duration_us(_, :undefined), do: nil

  defp duration_us(start, finish) do
    div(
      :opentelemetry.timestamp_to_nano(finish) -
        :opentelemetry.timestamp_to_nano(start),
      1000
    )
  end

  defp encode_status(nil), do: nil
  defp encode_status(:undefined), do: nil

  defp encode_status({:status, code, message}) do
    %{"code" => to_string(code), "message" => to_string(message)}
  end

  defp encode_status(_), do: nil

  defp encode_attributes(nil), do: %{}
  defp encode_attributes(:undefined), do: %{}

  defp encode_attributes(attrs) when is_tuple(attrs) do
    attrs
    |> :otel_attributes.map()
    |> Map.new(fn {k, v} -> {to_string(k), encode_value(v)} end)
  end

  defp encode_attributes(other) when is_map(other) do
    Map.new(other, fn {k, v} -> {to_string(k), encode_value(v)} end)
  end

  defp encode_attributes(_), do: %{}

  defp encode_value(v)
       when is_atom(v) and not is_boolean(v) and v not in [nil],
       do: to_string(v)

  defp encode_value(v) when is_list(v), do: Enum.map(v, &encode_value/1)

  defp encode_value(v) when is_tuple(v),
    do: v |> Tuple.to_list() |> Enum.map(&encode_value/1)

  defp encode_value(v), do: v

  defp encode_events(nil), do: []
  defp encode_events(:undefined), do: []

  defp encode_events(events_record) when is_tuple(events_record) do
    events_record
    |> :otel_events.list()
    |> Enum.map(fn evt ->
      fields = event(evt)

      %{
        "name" => to_string(fields[:name]),
        "time_unix_nano" =>
          fields[:system_time_native] && fields[:system_time_native],
        "attributes" => encode_attributes(fields[:attributes])
      }
    end)
  end

  defp encode_events(_), do: []

  defp encode_scope(nil), do: nil
  defp encode_scope(:undefined), do: nil

  defp encode_scope({:instrumentation_scope, name, version, schema_url}) do
    %{
      "name" => to_string(name),
      "version" => version && to_string(version),
      "schema_url" => schema_url && to_string(schema_url)
    }
    |> drop_nils()
  end

  defp encode_scope(_), do: nil

  defp drop_nils(map) do
    map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
  end
end
