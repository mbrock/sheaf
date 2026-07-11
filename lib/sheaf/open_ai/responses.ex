defmodule Sheaf.OpenAI.Responses do
  @moduledoc """
  Direct OpenAI Responses API transport for Sheaf's assistant.

  This deliberately owns the wire format. In particular, stateful requests
  send only messages after the latest response boundary instead of replaying
  the complete conversation alongside `previous_response_id`.
  """

  alias ReqLLM.{Context, Message, Response, Tool, ToolCall}
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}

  require OpenTelemetry.Tracer, as: Tracer

  @endpoint "https://api.openai.com/v1/responses"
  @receive_timeout 300_000

  def generate(model, %Context{} = context, opts \\ []) do
    request(model, context, Keyword.put(opts, :stream, false))
  end

  def stream(model, %Context{} = context, opts \\ []) do
    request(model, context, Keyword.put(opts, :stream, true))
  end

  @doc false
  def request_body(model, %Context{} = context, opts \\ []) do
    {input, previous_response_id} = request_input(context)
    input = mark_latest_user_breakpoint(input)

    %{
      "model" => normalize_model(model),
      "input" => input,
      "instructions" => system_instructions(context),
      "tools" => encode_tools(Keyword.get(opts, :tools, [])),
      "stream" => Keyword.get(opts, :stream, false),
      "store" => true,
      "parallel_tool_calls" => true,
      "prompt_cache_key" => Keyword.get(opts, :prompt_cache_key),
      "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
      "previous_response_id" => previous_response_id,
      "reasoning" => reasoning_options(opts),
      "max_output_tokens" => Keyword.get(opts, :max_tokens)
    }
    |> reject_empty()
  end

  defp request(model, context, opts) do
    body = request_body(model, context, opts)
    encoded_bytes = body |> Jason.encode!() |> byte_size()

    Tracer.with_span "sheaf.openai.responses", %{
      kind: :client,
      attributes: [
        {"gen_ai.system", "openai"},
        {"gen_ai.request.model", body["model"]},
        {"sheaf.openai.request_bytes", encoded_bytes},
        {"sheaf.openai.input_item_count", length(body["input"])},
        {"sheaf.openai.previous_response",
         body["previous_response_id"] != nil},
        {"sheaf.openai.prompt_cache_key", body["prompt_cache_key"] || ""}
      ]
    } do
      headers = [
        {"authorization", "Bearer #{System.fetch_env!("OPENAI_API_KEY")}"},
        {"content-type", "application/json"},
        {"accept",
         if(body["stream"], do: "text/event-stream", else: "application/json")}
      ]

      response =
        Req.post(@endpoint,
          headers: headers,
          json: body,
          into: if(body["stream"], do: :self, else: nil),
          receive_timeout:
            Keyword.get(opts, :receive_timeout, @receive_timeout)
        )

      decode_http_response(response, context, model, opts)
    end
  end

  defp decode_http_response(
         {:ok, %Req.Response{status: status} = response},
         context,
         model,
         opts
       )
       when status in 200..299 do
    if Keyword.get(opts, :stream, false) do
      response.body
      |> collect_sse(opts)
      |> build_response(context, model)
    else
      response.body
      |> normalize_json_body()
      |> build_response(context, model)
    end
  end

  defp decode_http_response(
         {:ok, %Req.Response{status: status, body: body}},
         _context,
         _model,
         _opts
       ) do
    {:error, {:openai_response_error, status, normalize_error_body(body)}}
  end

  defp decode_http_response({:error, reason}, _context, _model, _opts),
    do: {:error, {:openai_request_error, reason}}

  defp collect_sse(chunks, opts) do
    initial = %{
      buffer: "",
      text: "",
      thinking: "",
      calls: %{},
      response: nil,
      error: nil
    }

    chunks
    |> Enum.reduce(initial, fn chunk, state ->
      data = if match?({:data, _}, chunk), do: elem(chunk, 1), else: chunk
      consume_sse_data(state, if(is_binary(data), do: data, else: ""), opts)
    end)
    |> flush_sse(opts)
    |> case do
      %{error: nil, response: response} when is_map(response) ->
        response

      %{error: error} when not is_nil(error) ->
        %{"error" => error}

      _ ->
        %{
          "error" => %{
            "message" => "OpenAI stream ended without response.completed"
          }
        }
    end
  end

  defp consume_sse_data(state, data, opts) do
    buffer =
      (state.buffer <> data)
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")

    parts = String.split(buffer, "\n\n")
    {events, remainder} = Enum.split(parts, max(length(parts) - 1, 0))
    state = %{state | buffer: List.first(remainder) || ""}
    Enum.reduce(events, state, &consume_sse_event(&2, &1, opts))
  end

  defp flush_sse(%{buffer: buffer} = state, opts) do
    if String.trim(buffer) == "",
      do: state,
      else: consume_sse_event(state, buffer, opts)
  end

  defp consume_sse_event(state, raw, opts) do
    data =
      raw
      |> String.split("\n")
      |> Enum.flat_map(fn
        "data: " <> value -> [value]
        "data:" <> value -> [value]
        _ -> []
      end)
      |> Enum.join("\n")

    case Jason.decode(data) do
      {:ok, payload} -> consume_payload(state, payload, opts)
      _ -> state
    end
  end

  defp consume_payload(
         state,
         %{"type" => "response.output_text.delta", "delta" => delta},
         opts
       ) do
    invoke(opts[:on_result], delta)
    invoke(opts[:on_chunk], delta)
    %{state | text: state.text <> delta}
  end

  defp consume_payload(
         state,
         %{
           "type" => "response.reasoning_summary_text.delta",
           "delta" => delta
         },
         opts
       ) do
    invoke(opts[:on_thinking], delta)
    %{state | thinking: state.thinking <> delta}
  end

  defp consume_payload(
         state,
         %{"type" => "response.function_call_arguments.delta"} = payload,
         opts
       ) do
    key = payload["item_id"] || payload["output_index"]
    call = Map.get(state.calls, key, %{})

    call =
      Map.update(
        call,
        "arguments",
        payload["delta"] || "",
        &(&1 <> (payload["delta"] || ""))
      )

    invoke(opts[:on_tool_call], %{
      id: call["call_id"],
      name: call["name"],
      arguments: call["arguments"]
    })

    %{state | calls: Map.put(state.calls, key, call)}
  end

  defp consume_payload(
         state,
         %{
           "type" => "response.output_item.added",
           "item" => %{"type" => "function_call"} = item
         },
         _opts
       ) do
    key = item["id"] || item["output_index"]

    call = %{
      "call_id" => item["call_id"],
      "name" => item["name"],
      "arguments" => item["arguments"] || ""
    }

    %{state | calls: Map.put(state.calls, key, call)}
  end

  defp consume_payload(
         state,
         %{"type" => "response.completed", "response" => response},
         _opts
       ),
       do: %{state | response: response}

  defp consume_payload(
         state,
         %{"type" => "response.failed", "response" => response},
         _opts
       ),
       do: %{state | error: response["error"] || response}

  defp consume_payload(state, %{"type" => "error", "error" => error}, _opts),
    do: %{state | error: error}

  defp consume_payload(state, _payload, _opts), do: state

  defp build_response(%{"error" => error}, _context, _model)
       when not is_nil(error),
       do: {:error, {:openai_response_error, error}}

  defp build_response(response, context, model) when is_map(response) do
    output = response["output"] || []
    text = output_text(output)
    tool_calls = decode_tool_calls(output)
    reasoning_details = decode_reasoning(output)
    response_id = response["id"]

    message = %Message{
      role: :assistant,
      content: if(text == "", do: [], else: [ContentPart.text(text)]),
      name: nil,
      tool_call_id: nil,
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      metadata: %{response_id: response_id},
      reasoning_details: reasoning_details
    }

    usage = normalize_usage(response["usage"] || %{})
    record_usage(usage)

    {:ok,
     %Response{
       id: response_id || "",
       model: response["model"] || normalize_model(model),
       context: context,
       message: message,
       object: nil,
       stream?: false,
       stream: nil,
       usage: usage,
       finish_reason: if(tool_calls == [], do: :stop, else: :tool_calls),
       provider_meta: %{
         response_id: response_id,
         raw_status: response["status"]
       },
       error: nil
     }}
  end

  defp record_usage(usage) do
    Enum.each(
      [
        {"gen_ai.usage.input_tokens", usage.input_tokens},
        {"gen_ai.usage.output_tokens", usage.output_tokens},
        {"gen_ai.usage.cached_tokens", usage.cached_tokens},
        {"gen_ai.usage.cache_write_tokens", usage.cache_write_tokens},
        {"gen_ai.usage.reasoning_tokens", usage.reasoning_tokens}
      ],
      fn {key, value} -> Tracer.set_attribute(key, value) end
    )
  end

  defp normalize_usage(usage) do
    details = usage["input_tokens_details"] || %{}
    output_details = usage["output_tokens_details"] || %{}

    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      total_tokens:
        usage["total_tokens"] ||
          (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
      cached_tokens: details["cached_tokens"] || 0,
      cache_write_tokens: details["cache_write_tokens"] || 0,
      reasoning_tokens: output_details["reasoning_tokens"] || 0
    }
  end

  defp request_input(%Context{messages: messages}) do
    case latest_response_boundary(messages) do
      {response_id, index} ->
        {messages |> Enum.drop(index + 1) |> encode_messages(false),
         response_id}

      nil ->
        {encode_messages(messages, true), nil}
    end
  end

  defp latest_response_boundary(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Message{role: :assistant, metadata: metadata}, index}, acc ->
        case map_value(metadata, :response_id) do
          id when is_binary(id) and id != "" -> {id, index}
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp encode_messages(messages, include_reasoning?) do
    Enum.flat_map(messages, &encode_message(&1, include_reasoning?))
  end

  defp encode_message(%Message{role: :system}, _), do: []

  defp encode_message(%Message{role: :tool, tool_call_id: id} = message, _)
       when is_binary(id) do
    [
      %{
        "type" => "function_call_output",
        "call_id" => id,
        "output" => tool_output(message)
      }
    ]
  end

  defp encode_message(
         %Message{role: :assistant} = message,
         include_reasoning?
       ) do
    reasoning =
      if include_reasoning?,
        do: encode_reasoning(message.reasoning_details),
        else: []

    text = message_text(message)

    text_items =
      if text == "",
        do: [],
        else: [%{"role" => "assistant", "content" => text}]

    calls = Enum.map(message.tool_calls || [], &encode_tool_call/1)
    reasoning ++ text_items ++ calls
  end

  defp encode_message(%Message{role: role} = message, _) do
    text = message_text(message)

    if text == "",
      do: [],
      else: [
        %{
          "role" => Atom.to_string(role),
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ]
  end

  defp encode_reasoning(nil), do: []

  defp encode_reasoning(details) when is_list(details) do
    Enum.flat_map(details, fn
      %ReasoningDetails{provider: :openai} = detail ->
        [
          %{
            "type" => "reasoning",
            "id" => detail.provider_data["id"],
            "encrypted_content" => detail.signature,
            "summary" => reasoning_summary(detail.text)
          }
          |> reject_empty()
        ]

      _ ->
        []
    end)
  end

  defp reasoning_summary(text) when is_binary(text) and text != "",
    do: [%{"type" => "summary_text", "text" => text}]

  defp reasoning_summary(_), do: []

  defp encode_tool_call(%ToolCall{id: id, function: function}) do
    %{
      "type" => "function_call",
      "call_id" => id,
      "name" => map_value(function, :name),
      "arguments" => map_value(function, :arguments) || "{}"
    }
  end

  defp encode_tools(tools) do
    Enum.map(tools, fn %Tool{} = tool ->
      schema = Tool.to_json_schema(tool)
      function = schema["function"] || %{}

      %{
        "type" => "function",
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => function["parameters"] || %{"type" => "object"},
        "strict" => tool.strict
      }
    end)
  end

  defp mark_latest_user_breakpoint(input) do
    case input
         |> Enum.with_index()
         |> Enum.filter(fn {item, _} -> item["role"] == "user" end)
         |> List.last() do
      {item, index} ->
        content = item["content"]

        content =
          if is_binary(content),
            do: [%{"type" => "input_text", "text" => content}],
            else: content

        content =
          List.update_at(
            content,
            -1,
            &Map.put(&1, "prompt_cache_breakpoint", %{"mode" => "explicit"})
          )

        List.replace_at(input, index, Map.put(item, "content", content))

      nil ->
        input
    end
  end

  defp system_instructions(%Context{messages: messages}) do
    messages
    |> Enum.filter(&(&1.role == :system))
    |> Enum.map_join("\n\n", &message_text/1)
  end

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", &(&1.text || ""))
  end

  defp tool_output(message) do
    case map_value(message.metadata, :tool_result) do
      nil -> message_text(message)
      value when is_binary(value) -> value
      value -> Jason.encode!(value)
    end
  end

  defp output_text(output) do
    output
    |> Enum.flat_map(fn
      %{"type" => "message", "content" => content} -> content || []
      _ -> []
    end)
    |> Enum.filter(&(&1["type"] == "output_text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp decode_tool_calls(output) do
    Enum.flat_map(output, fn
      %{"type" => "function_call", "call_id" => id, "name" => name} = call ->
        [ToolCall.new(id, name, call["arguments"] || "{}")]

      _ ->
        []
    end)
  end

  defp decode_reasoning(output) do
    output
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "reasoning"} = item, index} ->
        text =
          item["summary"]
          |> List.wrap()
          |> Enum.map_join("\n\n", &(&1["text"] || ""))

        [
          %ReasoningDetails{
            text: empty_nil(text),
            signature: item["encrypted_content"],
            encrypted?: is_binary(item["encrypted_content"]),
            provider: :openai,
            format: "openai-responses-v1",
            index: index,
            provider_data: Map.take(item, ["id", "status"])
          }
        ]

      _ ->
        []
    end)
    |> case do
      [] -> nil
      details -> details
    end
  end

  defp reasoning_options(opts) do
    %{
      "effort" => Keyword.get(opts, :reasoning_effort),
      "summary" => get_in(opts, [:provider_options, :reasoning_summary])
    }
    |> reject_empty()
  end

  defp normalize_model("openai:" <> model), do: model
  defp normalize_model(model), do: to_string(model)
  defp normalize_json_body(body) when is_map(body), do: body
  defp normalize_json_body(body) when is_binary(body), do: Jason.decode!(body)

  defp normalize_error_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, value} -> value
      _ -> body
    end
  end

  defp normalize_error_body(body), do: body
  defp empty_nil(""), do: nil
  defp empty_nil(value), do: value

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_, _), do: nil
  defp invoke(fun, value) when is_function(fun, 1), do: fun.(value)
  defp invoke(_, _), do: :ok

  defp reject_empty(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
end
