defmodule Sheaf.Anthropic.Messages do
  @moduledoc """
  Direct Anthropic Messages API transport for Sheaf's assistant.
  """

  alias ReqLLM.{Context, Message, Response, Tool, ToolCall}
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}

  require OpenTelemetry.Tracer, as: Tracer

  @endpoint "https://api.anthropic.com/v1/messages"
  @version "2023-06-01"
  @receive_timeout 300_000
  @default_max_tokens 128_000

  def generate(model, %Context{} = context, opts \\ []) do
    request(model, context, Keyword.put(opts, :stream, false))
  end

  def stream(model, %Context{} = context, opts \\ []) do
    request(model, context, Keyword.put(opts, :stream, true))
  end

  def generate_object(model, message, schema, opts \\ [])
      when is_binary(message) and is_list(schema) do
    tool =
      Tool.new!(
        name: "return_structured_result",
        description: "Return the requested structured result.",
        parameter_schema: schema,
        callback: fn _ -> {:error, :not_executable} end
      )

    context = Context.new([Context.user(message)])

    options =
      opts
      |> Keyword.put(:tools, [tool])
      |> Keyword.put(:tool_choice, %{"type" => "tool", "name" => tool.name})
      |> Keyword.update(
        :provider_options,
        [thinking: false],
        &Keyword.put(&1, :thinking, false)
      )

    with {:ok, response} <- generate(model, context, options),
         [call | _] <- Response.tool_calls(response),
         {:ok, object} <- Jason.decode(call.function.arguments) do
      {:ok, %{object: object, usage: response.usage}}
    else
      [] -> {:error, :missing_structured_tool_call}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def request_body(model, %Context{} = context, opts \\ []) do
    %{
      "model" => normalize_model(model),
      "max_tokens" => Keyword.get(opts, :max_tokens) || @default_max_tokens,
      "system" => encode_system(context, opts),
      "messages" => encode_messages(context.messages, opts),
      "tools" => encode_tools(Keyword.get(opts, :tools, []), opts),
      "tool_choice" => Keyword.get(opts, :tool_choice),
      "stream" => Keyword.get(opts, :stream, false),
      "thinking" => thinking_options(opts),
      "output_config" => output_config(opts)
    }
    |> reject_empty()
  end

  defp request(model, context, opts) do
    body = request_body(model, context, opts)

    Tracer.with_span "sheaf.anthropic.messages", %{
      kind: :client,
      attributes: [
        {"gen_ai.system", "anthropic"},
        {"gen_ai.request.model", body["model"]},
        {"sheaf.anthropic.request_bytes",
         body |> Jason.encode!() |> byte_size()},
        {"sheaf.anthropic.message_count", length(body["messages"])}
      ]
    } do
      headers = [
        {"x-api-key", System.fetch_env!("ANTHROPIC_API_KEY")},
        {"anthropic-version", @version},
        {"content-type", "application/json"},
        {"accept",
         if(body["stream"], do: "text/event-stream", else: "application/json")}
      ]

      request_opts = [
        headers: headers,
        json: body,
        receive_timeout: Keyword.get(opts, :receive_timeout, @receive_timeout)
      ]

      request_opts =
        if body["stream"],
          do: Keyword.put(request_opts, :into, :self),
          else: request_opts

      Req.post(@endpoint, request_opts)
      |> decode_http_response(context, model, opts)
    end
  end

  defp decode_http_response(
         {:ok, %Req.Response{status: status} = response},
         context,
         model,
         opts
       )
       when status in 200..299 do
    payload =
      if Keyword.get(opts, :stream, false) do
        collect_sse(response.body, opts)
      else
        normalize_json_body(response.body)
      end

    build_response(payload, context, model)
  end

  defp decode_http_response(
         {:ok, %Req.Response{status: status, body: body}},
         _context,
         _model,
         _opts
       ),
       do:
         {:error,
          {:anthropic_response_error, status, normalize_error_body(body)}}

  defp decode_http_response({:error, reason}, _context, _model, _opts),
    do: {:error, {:anthropic_request_error, reason}}

  defp collect_sse(chunks, opts) do
    initial = %{
      buffer: "",
      id: nil,
      model: nil,
      blocks: %{},
      usage: %{},
      stop_reason: nil,
      error: nil
    }

    chunks
    |> Enum.reduce(initial, fn chunk, state ->
      data = if match?({:data, _}, chunk), do: elem(chunk, 1), else: chunk
      consume_sse_data(state, if(is_binary(data), do: data, else: ""), opts)
    end)
    |> flush_sse(opts)
    |> stream_payload()
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
         %{"type" => "message_start", "message" => message},
         _opts
       ) do
    %{
      state
      | id: message["id"],
        model: message["model"],
        usage: Map.merge(state.usage, message["usage"] || %{})
    }
  end

  defp consume_payload(
         state,
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => block
         },
         _opts
       ) do
    block =
      block
      |> Map.put_new("text", "")
      |> Map.put_new("thinking", "")
      |> Map.put_new("signature", "")
      |> Map.put_new("input_json", "")

    %{state | blocks: Map.put(state.blocks, index, block)}
  end

  defp consume_payload(
         state,
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => delta
         },
         opts
       ) do
    block = Map.get(state.blocks, index, %{})

    block =
      case delta do
        %{"type" => "text_delta", "text" => text} ->
          invoke(opts[:on_result], text)
          invoke(opts[:on_chunk], text)
          Map.update(block, "text", text, &(&1 <> text))

        %{"type" => "thinking_delta", "thinking" => thinking} ->
          invoke(opts[:on_thinking], thinking)
          Map.update(block, "thinking", thinking, &(&1 <> thinking))

        %{"type" => "signature_delta", "signature" => signature} ->
          Map.update(block, "signature", signature, &(&1 <> signature))

        %{"type" => "input_json_delta", "partial_json" => json} ->
          block = Map.update(block, "input_json", json, &(&1 <> json))

          invoke(opts[:on_tool_call], %{
            id: block["id"],
            name: block["name"],
            arguments: block["input_json"]
          })

          block

        _ ->
          block
      end

    %{state | blocks: Map.put(state.blocks, index, block)}
  end

  defp consume_payload(state, %{"type" => "message_delta"} = payload, _opts) do
    %{
      state
      | stop_reason:
          get_in(payload, ["delta", "stop_reason"]) || state.stop_reason,
        usage: Map.merge(state.usage, payload["usage"] || %{})
    }
  end

  defp consume_payload(state, %{"type" => "error"} = payload, _opts),
    do: %{state | error: payload["error"] || payload}

  defp consume_payload(state, _payload, _opts), do: state

  defp stream_payload(%{error: error}) when not is_nil(error),
    do: %{"error" => error}

  defp stream_payload(state) do
    content =
      state.blocks
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&finalize_block(elem(&1, 1)))

    %{
      "id" => state.id,
      "model" => state.model,
      "content" => content,
      "usage" => state.usage,
      "stop_reason" => state.stop_reason
    }
  end

  defp finalize_block(%{"type" => "tool_use"} = block) do
    input =
      case Jason.decode(block["input_json"] || "") do
        {:ok, value} when is_map(value) -> value
        _ -> block["input"] || %{}
      end

    block |> Map.take(["type", "id", "name"]) |> Map.put("input", input)
  end

  defp finalize_block(%{"type" => "thinking"} = block),
    do: Map.take(block, ["type", "thinking", "signature"])

  defp finalize_block(%{"type" => "text"} = block),
    do: Map.take(block, ["type", "text"])

  defp finalize_block(block), do: block

  defp build_response(%{"error" => error}, _context, _model)
       when not is_nil(error),
       do: {:error, {:anthropic_response_error, error}}

  defp build_response(payload, context, model) when is_map(payload) do
    content = payload["content"] || []

    text =
      content
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", &(&1["text"] || ""))

    thinking = content |> Enum.filter(&(&1["type"] == "thinking"))
    tool_calls = decode_tool_calls(content)
    reasoning_details = decode_reasoning(thinking)

    message = %Message{
      role: :assistant,
      content:
        Enum.map(thinking, &ContentPart.thinking(&1["thinking"] || "")) ++
          if(text == "", do: [], else: [ContentPart.text(text)]),
      name: nil,
      tool_call_id: nil,
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      metadata: %{message_id: payload["id"]},
      reasoning_details: reasoning_details
    }

    usage = normalize_usage(payload["usage"] || %{})
    record_usage(usage)

    {:ok,
     %Response{
       id: payload["id"] || "",
       model: payload["model"] || normalize_model(model),
       context: context,
       message: message,
       object: nil,
       stream?: false,
       stream: nil,
       usage: usage,
       finish_reason: finish_reason(payload["stop_reason"], tool_calls),
       provider_meta: %{
         message_id: payload["id"],
         raw_stop_reason: payload["stop_reason"]
       },
       error: nil
     }}
  end

  defp normalize_usage(usage) do
    uncached = usage["input_tokens"] || 0
    cached = usage["cache_read_input_tokens"] || 0
    created = usage["cache_creation_input_tokens"] || 0
    input = uncached + cached + created
    output = usage["output_tokens"] || 0

    %{
      input_tokens: input,
      uncached_input_tokens: uncached,
      output_tokens: output,
      total_tokens: input + output,
      cached_tokens: cached,
      cache_creation_tokens: created
    }
  end

  defp record_usage(usage) do
    Enum.each(
      [
        {"gen_ai.usage.input_tokens", usage.input_tokens},
        {"gen_ai.usage.uncached_input_tokens", usage.uncached_input_tokens},
        {"gen_ai.usage.output_tokens", usage.output_tokens},
        {"gen_ai.usage.cached_tokens", usage.cached_tokens},
        {"gen_ai.usage.cache_creation_tokens", usage.cache_creation_tokens}
      ],
      fn {key, value} -> Tracer.set_attribute(key, value) end
    )
  end

  defp encode_system(%Context{messages: messages}, opts) do
    text =
      messages
      |> Enum.filter(&(&1.role == :system))
      |> Enum.map_join("\n\n", &message_text/1)

    if text == "" do
      []
    else
      block = %{"type" => "text", "text" => text}
      [maybe_cache(block, prompt_cache_enabled?(opts))]
    end
  end

  defp encode_messages(messages, opts) do
    messages
    |> Enum.reject(&(&1.role == :system))
    |> Enum.flat_map(&encode_message/1)
    |> merge_adjacent_roles()
    |> maybe_mark_latest_user_cache(message_cache_enabled?(opts))
  end

  defp encode_message(%Message{role: :tool, tool_call_id: id} = message) do
    [
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "content" => tool_output(message),
            "is_error" => truthy?(map_value(message.metadata, :is_error))
          }
        ]
      }
    ]
  end

  defp encode_message(%Message{role: :assistant} = message) do
    blocks =
      encode_reasoning(message.reasoning_details) ++
        if(message_text(message) == "",
          do: [],
          else: [%{"type" => "text", "text" => message_text(message)}]
        ) ++
        Enum.map(message.tool_calls || [], &encode_tool_call/1)

    if blocks == [],
      do: [],
      else: [%{"role" => "assistant", "content" => blocks}]
  end

  defp encode_message(%Message{role: :user} = message) do
    if message_text(message) == "",
      do: [],
      else: [
        %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => message_text(message)}]
        }
      ]
  end

  defp encode_message(_message), do: []

  defp encode_reasoning(nil), do: []

  defp encode_reasoning(details) do
    Enum.flat_map(details, fn
      %ReasoningDetails{provider: :anthropic, signature: signature} = detail
      when is_binary(signature) and signature != "" ->
        [
          %{
            "type" => "thinking",
            "thinking" => detail.text || "",
            "signature" => signature
          }
        ]

      _ ->
        []
    end)
  end

  defp encode_tool_call(%ToolCall{id: id, function: function}) do
    arguments = map_value(function, :arguments) || "{}"

    input =
      case Jason.decode(arguments) do
        {:ok, value} when is_map(value) -> value
        _ -> %{}
      end

    %{
      "type" => "tool_use",
      "id" => id,
      "name" => map_value(function, :name),
      "input" => input
    }
  end

  defp encode_tools(tools, opts) do
    tools
    |> Enum.map(fn %Tool{} = tool ->
      schema = Tool.to_schema(tool, :anthropic)

      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => schema["input_schema"] || %{"type" => "object"}
      }
    end)
    |> maybe_mark_last_cache(prompt_cache_enabled?(opts))
  end

  defp merge_adjacent_roles(messages) do
    Enum.reduce(messages, [], fn message, acc ->
      case {acc, message} do
        {[%{"role" => role, "content" => content} = previous | rest],
         %{"role" => role, "content" => message_content}} ->
          [%{previous | "content" => content ++ message_content} | rest]

        _ ->
          [message | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp maybe_mark_latest_user_cache(messages, false), do: messages

  defp maybe_mark_latest_user_cache(messages, true) do
    case messages
         |> Enum.with_index()
         |> Enum.filter(fn {m, _} -> m["role"] == "user" end)
         |> List.last() do
      {message, index} ->
        content =
          List.update_at(
            message["content"],
            -1,
            &Map.put(&1, "cache_control", %{"type" => "ephemeral"})
          )

        List.replace_at(messages, index, %{message | "content" => content})

      nil ->
        messages
    end
  end

  defp maybe_mark_last_cache(tools, false), do: tools
  defp maybe_mark_last_cache([], true), do: []

  defp maybe_mark_last_cache(tools, true),
    do:
      List.update_at(
        tools,
        -1,
        &Map.put(&1, "cache_control", %{"type" => "ephemeral"})
      )

  defp maybe_cache(value, true),
    do: Map.put(value, "cache_control", %{"type" => "ephemeral"})

  defp maybe_cache(value, false), do: value

  defp prompt_cache_enabled?(opts) do
    get_in(opts, [:provider_options, :anthropic_prompt_cache]) != false
  end

  defp message_cache_enabled?(opts) do
    prompt_cache_enabled?(opts) and
      get_in(opts, [:provider_options, :anthropic_cache_messages]) != false
  end

  defp decode_tool_calls(content) do
    Enum.flat_map(content, fn
      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        [ToolCall.new(id, name, Jason.encode!(input || %{}))]

      _ ->
        []
    end)
  end

  defp decode_reasoning(blocks) do
    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %ReasoningDetails{
        text: block["thinking"],
        signature: block["signature"],
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: index,
        provider_data: %{}
      }
    end)
    |> case do
      [] -> nil
      details -> details
    end
  end

  defp thinking_options(opts) do
    case get_in(opts, [:provider_options, :thinking]) do
      nil -> nil
      false -> nil
      %{} = thinking -> %{"type" => map_value(thinking, :type) || "adaptive"}
      _ -> %{"type" => "adaptive"}
    end
  end

  defp output_config(opts) do
    case Keyword.get(opts, :reasoning_effort) do
      nil -> nil
      effort -> %{"effort" => Atom.to_string(effort)}
    end
  end

  defp finish_reason("tool_use", _), do: :tool_calls
  defp finish_reason("max_tokens", _), do: :length
  defp finish_reason(_, calls) when calls != [], do: :tool_calls
  defp finish_reason(_, _), do: :stop

  defp message_text(%Message{content: content}),
    do:
      content
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", &(&1.text || ""))

  defp tool_output(message) do
    case map_value(message.metadata, :tool_result) do
      nil -> message_text(message)
      value when is_binary(value) -> value
      value -> Jason.encode!(value)
    end
  end

  defp normalize_model("anthropic:" <> model), do: model
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

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_, _), do: nil
  defp truthy?(value), do: value == true or value == "true"
  defp invoke(fun, value) when is_function(fun, 1), do: fun.(value)
  defp invoke(_, _), do: :ok

  defp reject_empty(map),
    do: Map.reject(map, fn {_key, value} -> value in [nil, "", [], %{}] end)
end
