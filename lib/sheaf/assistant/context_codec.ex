defmodule Sheaf.Assistant.ContextCodec do
  @moduledoc """
  JSON codec for persisted ReqLLM contexts.

  This intentionally stores ReqLLM's operational message shape rather than
  projecting assistant turns into a Sheaf domain ontology. Tool result metadata
  may contain Sheaf structs, so we tag known structs explicitly.
  """

  alias ReqLLM.{Context, Message, Tool, ToolCall}
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails

  @tool_result_modules [
    Sheaf.Assistant.ToolResults.ListDocuments,
    Sheaf.Assistant.ToolResults.DocumentSummary,
    Sheaf.Assistant.ToolResults.Document,
    Sheaf.Assistant.ToolResults.OutlineEntry,
    Sheaf.Assistant.ToolResults.Block,
    Sheaf.Assistant.ToolResults.Blocks,
    Sheaf.Assistant.ToolResults.Child,
    Sheaf.Assistant.ToolResults.ContextEntry,
    Sheaf.Assistant.ToolResults.Source,
    Sheaf.Assistant.ToolResults.Coding,
    Sheaf.Assistant.ToolResults.SearchResults,
    Sheaf.Assistant.ToolResults.ListSpreadsheets,
    Sheaf.Assistant.ToolResults.Spreadsheet,
    Sheaf.Assistant.ToolResults.SpreadsheetSheet,
    Sheaf.Assistant.ToolResults.SpreadsheetQuery,
    Sheaf.Assistant.ToolResults.SpreadsheetQueryResultPage,
    Sheaf.Assistant.ToolResults.SpreadsheetSearch,
    Sheaf.Assistant.ToolResults.SearchHit,
    Sheaf.Assistant.ToolResults.Note,
    Sheaf.Assistant.ToolResults.ParagraphTags
  ]

  @known_structs Map.new(@tool_result_modules, fn module -> {Atom.to_string(module), module} end)

  @doc """
  Converts a ReqLLM context to a JSON-compatible map.
  """
  def encode_context(%Context{} = context) do
    %{
      "messages" => Enum.map(context.messages, &encode_message/1),
      "tools" => encode_tool_schemas(context.tools || [])
    }
  end

  @doc """
  Converts executable ReqLLM tool definitions into JSON-compatible schemas.

  Tool callbacks are intentionally not persisted. The stored schema list is an
  operational description of what the context was run with, while executable
  tool semantics are reconstructed from the current application code.
  """
  def encode_tool_schemas(tools) when is_list(tools) do
    tools
    |> Enum.map(&encode_tool_schema/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Converts arbitrary supported values into JSON-compatible terms.
  """
  def encode_json_value(value), do: encode_value(value)

  @doc """
  Rebuilds a ReqLLM context from a decoded JSON map.
  """
  def decode_context(%{"messages" => messages}) when is_list(messages) do
    {:ok, Context.new(Enum.map(messages, &decode_message/1))}
  end

  def decode_context(_payload), do: {:error, :invalid_context_payload}

  @doc """
  Converts a ReqLLM message to a JSON-compatible map.
  """
  def encode_message(%Message{} = message) do
    %{
      "role" => Atom.to_string(message.role),
      "content" => Enum.map(message.content || [], &encode_content_part/1),
      "name" => message.name,
      "tool_call_id" => message.tool_call_id,
      "tool_calls" => encode_tool_calls(message.tool_calls),
      "metadata" => encode_value(message.metadata || %{}),
      "reasoning_details" => encode_reasoning_details(message.reasoning_details)
    }
  end

  @doc """
  Rebuilds a ReqLLM message from a decoded JSON map.
  """
  def decode_message(%{} = payload) do
    %Message{
      role: decode_role(Map.get(payload, "role")),
      content: payload |> Map.get("content", []) |> Enum.map(&decode_content_part/1),
      name: Map.get(payload, "name"),
      tool_call_id: Map.get(payload, "tool_call_id"),
      tool_calls: decode_tool_calls(Map.get(payload, "tool_calls")),
      metadata: payload |> Map.get("metadata", %{}) |> decode_value(),
      reasoning_details: decode_reasoning_details(Map.get(payload, "reasoning_details"))
    }
  end

  defp encode_content_part(%ContentPart{} = part) do
    %{
      "type" => Atom.to_string(part.type),
      "text" => part.text,
      "url" => part.url,
      "data" => encode_value(part.data),
      "media_type" => part.media_type,
      "filename" => part.filename,
      "metadata" => encode_value(part.metadata || %{})
    }
  end

  defp decode_content_part(%{} = payload) do
    %ContentPart{
      type: payload |> Map.get("type") |> decode_content_type(),
      text: Map.get(payload, "text"),
      url: Map.get(payload, "url"),
      data: payload |> Map.get("data") |> decode_value(),
      media_type: Map.get(payload, "media_type"),
      filename: Map.get(payload, "filename"),
      metadata: payload |> Map.get("metadata", %{}) |> decode_value()
    }
  end

  defp encode_tool_calls(nil), do: nil
  defp encode_tool_calls(tool_calls), do: Enum.map(tool_calls, &encode_tool_call/1)

  defp encode_tool_call(%ToolCall{} = tool_call) do
    %{
      "id" => tool_call.id,
      "type" => tool_call.type,
      "function" => encode_value(tool_call.function)
    }
  end

  defp encode_tool_call(%{} = tool_call), do: encode_value(tool_call)

  defp decode_tool_calls(nil), do: nil

  defp decode_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{"function" => %{"name" => name, "arguments" => arguments}, "id" => id} ->
        ToolCall.new(id, name, arguments || "{}")

      %{"name" => name, "arguments" => arguments, "id" => id} ->
        ToolCall.new(id, name, Jason.encode!(arguments || %{}))

      other ->
        other
    end)
  end

  defp encode_reasoning_details(nil), do: nil

  defp encode_reasoning_details(reasoning_details) when is_list(reasoning_details) do
    Enum.map(reasoning_details, &encode_value/1)
  end

  defp decode_reasoning_details(nil), do: nil

  defp decode_reasoning_details(reasoning_details) when is_list(reasoning_details) do
    Enum.map(reasoning_details, fn
      %{"__struct__" => "Elixir.ReqLLM.Message.ReasoningDetails"} = payload ->
        payload |> decode_struct_payload() |> then(&struct(ReasoningDetails, &1))

      %{} = payload ->
        %ReasoningDetails{
          text: Map.get(payload, "text"),
          signature: Map.get(payload, "signature"),
          encrypted?: Map.get(payload, "encrypted?", false),
          provider: payload |> Map.get("provider") |> safe_existing_atom(),
          format: Map.get(payload, "format"),
          index: Map.get(payload, "index", 0),
          provider_data: Map.get(payload, "provider_data", %{})
        }

      other ->
        other
    end)
  end

  defp encode_value(%module{} = struct) when module in @tool_result_modules do
    %{
      "__struct__" => Atom.to_string(module),
      "fields" =>
        struct
        |> Map.from_struct()
        |> encode_value()
    }
  end

  defp encode_value(%ReasoningDetails{} = details) do
    %{
      "__struct__" => Atom.to_string(ReasoningDetails),
      "fields" =>
        details
        |> Map.from_struct()
        |> encode_value()
    }
  end

  defp encode_value(%ContentPart{} = part), do: encode_content_part(part)
  defp encode_value(%ToolCall{} = tool_call), do: encode_tool_call(tool_call)

  defp encode_value(%{} = map) do
    Map.new(map, fn {key, value} -> {encode_key(key), encode_value(value)} end)
  end

  defp encode_value([]), do: []

  defp encode_value(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Map.new(list, fn {key, value} -> {encode_key(key), encode_value(value)} end)
    else
      Enum.map(list, &encode_value/1)
    end
  end

  defp encode_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> encode_value()
  end

  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value

  defp encode_tool_schema(%Tool{} = tool) do
    tool
    |> Tool.to_json_schema()
    |> encode_value()
  rescue
    _error ->
      %{
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.parameter_schema,
        strict: tool.strict,
        provider_options: tool.provider_options
      }
      |> encode_value()
  end

  defp encode_tool_schema(%{} = schema), do: encode_value(schema)
  defp encode_tool_schema(_other), do: nil

  defp decode_value(%{"__struct__" => module_name} = payload) do
    fields = decode_struct_payload(payload)

    case Map.fetch(@known_structs, module_name) do
      {:ok, module} -> struct(module, atomize_known_keys(module, fields))
      :error -> fields
    end
  end

  defp decode_value(%{} = map),
    do: Map.new(map, fn {key, value} -> {key, decode_value(value)} end)

  defp decode_value(list) when is_list(list), do: Enum.map(list, &decode_value/1)
  defp decode_value(value), do: value

  defp decode_struct_payload(%{"fields" => fields}) when is_map(fields), do: decode_value(fields)
  defp decode_struct_payload(_payload), do: %{}

  defp atomize_known_keys(module, fields) when is_map(fields) do
    known_keys =
      module.__struct__()
      |> Map.from_struct()
      |> Map.keys()
      |> MapSet.new()

    Map.new(fields, fn {key, value} ->
      atom_key = safe_existing_atom(key)

      if MapSet.member?(known_keys, atom_key) do
        {atom_key, coerce_known_struct_value(module, atom_key, value)}
      else
        {key, value}
      end
    end)
  end

  defp coerce_known_struct_value(module, key, %{} = value) do
    case Map.fetch(module.__struct__(), key) do
      {:ok, []} when map_size(value) == 0 -> []
      _other -> value
    end
  end

  defp coerce_known_struct_value(_module, _key, value), do: value

  defp encode_key(key) when is_atom(key), do: Atom.to_string(key)
  defp encode_key(key), do: to_string(key)

  defp decode_role(role) when role in ~w(user assistant system tool),
    do: String.to_existing_atom(role)

  defp decode_role(role) when is_atom(role), do: role
  defp decode_role(_role), do: :user

  defp decode_content_type(type)
       when type in ~w(text image_url video_url image file thinking),
       do: String.to_existing_atom(type)

  defp decode_content_type(type) when is_atom(type), do: type
  defp decode_content_type(_type), do: :text

  defp safe_existing_atom(value) when is_atom(value), do: value

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp safe_existing_atom(value), do: value
end
