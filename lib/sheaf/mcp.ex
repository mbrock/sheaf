defmodule Sheaf.MCP do
  @moduledoc """
  Model Context Protocol adapter for Sheaf's research-library tools.

  The adapter is stateless: every request reads the current corpus and note
  graph. Transport and authentication live in `SheafWeb.MCPController` and
  `SheafWeb.MCPAuthPlug`.
  """

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.CorpusTools

  require OpenTelemetry.Tracer, as: Tracer

  @latest_protocol_version "2025-11-25"
  @supported_protocol_versions [
    @latest_protocol_version,
    "2025-06-18",
    "2025-03-26"
  ]
  @tool_names ~w(list_documents get_document read search_text list_notes write_note)

  @doc "Protocol revisions accepted by the Streamable HTTP endpoint."
  def supported_protocol_versions, do: @supported_protocol_versions

  @doc "The protocol revision preferred during version negotiation."
  def latest_protocol_version, do: @latest_protocol_version

  @doc "Builds the bounded tool set exposed to external MCP clients."
  def tools(opts \\ []) do
    opts
    |> Keyword.put_new(:tool_set, :assistant)
    |> CorpusTools.tools()
    |> Enum.filter(&(&1.name in @tool_names))
  end

  @doc "Handles one MCP JSON-RPC message."
  def handle(message, opts \\ [])

  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, opts)
      when is_binary(method) do
    Tracer.with_span "Sheaf.MCP.request", %{
      kind: :server,
      attributes: [
        {"rpc.system", "jsonrpc"},
        {"rpc.method", method},
        {"rpc.jsonrpc.request_id", inspect(Map.get(message, "id"))}
      ]
    } do
      dispatch(message, opts)
    end
  end

  def handle(message, _opts) do
    {:response,
     error_response(request_id(message), -32600, "Invalid Request")}
  end

  defp dispatch(%{"method" => "initialize", "id" => id} = message, _opts) do
    requested = get_in(message, ["params", "protocolVersion"])

    protocol_version =
      if requested in @supported_protocol_versions,
        do: requested,
        else: @latest_protocol_version

    result = %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => "sheaf",
        "title" => "Sheaf Research Library",
        "version" => server_version()
      },
      "instructions" =>
        "Search and read the Sheaf research library. Cite Sheaf block ids such as #ABC123 in your work. Persist durable findings with write_note and pass related block ids explicitly."
    }

    {:response, success_response(id, result)}
  end

  defp dispatch(%{"method" => "ping", "id" => id}, _opts) do
    {:response, success_response(id, %{})}
  end

  defp dispatch(%{"method" => "tools/list", "id" => id}, opts) do
    listed_tools = opts |> configured_tools() |> Enum.map(&tool_definition/1)
    {:response, success_response(id, %{"tools" => listed_tools})}
  end

  defp dispatch(
         %{
           "method" => "tools/call",
           "id" => id,
           "params" => %{"name" => name} = params
         },
         opts
       )
       when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    if is_map(arguments) do
      call_tool(id, name, arguments, configured_tools(opts))
    else
      {:response,
       error_response(id, -32602, "Tool arguments must be an object")}
    end
  end

  defp dispatch(%{"method" => "tools/call", "id" => id}, _opts) do
    {:response, error_response(id, -32602, "Tool name is required")}
  end

  defp dispatch(%{"id" => id, "method" => method}, _opts) do
    {:response, error_response(id, -32601, "Method not found: #{method}")}
  end

  defp dispatch(%{"method" => _method}, _opts), do: :accepted

  defp call_tool(id, name, arguments, tools) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        {:response, error_response(id, -32602, "Unknown tool: #{name}")}

      tool ->
        Tracer.with_span "Sheaf.MCP.tool_call", %{
          kind: :internal,
          attributes: [
            {"gen_ai.tool.name", name},
            {"gen_ai.tool.arguments", Jason.encode!(arguments)}
          ]
        } do
          result =
            case Tool.execute(tool, arguments) do
              {:ok, value} -> tool_result(value)
              {:error, reason} -> tool_error(reason)
            end

          {:response, success_response(id, result)}
        end
    end
  end

  defp configured_tools(opts) do
    Keyword.get_lazy(opts, :tools, fn -> tools(opts) end)
  end

  defp tool_definition(%Tool{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => ReqLLM.Schema.to_json(tool.parameter_schema),
      "annotations" => tool_annotations(tool.name)
    }
  end

  defp tool_annotations("write_note") do
    %{
      "title" => "Create research note",
      "readOnlyHint" => false,
      "destructiveHint" => false,
      "idempotentHint" => false,
      "openWorldHint" => false
    }
  end

  defp tool_annotations(name) do
    %{
      "title" => name |> String.replace("_", " ") |> String.capitalize(),
      "readOnlyHint" => true,
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false
    }
  end

  defp tool_result(%ToolResult{content: content}) when is_list(content) do
    %{
      "content" => Enum.flat_map(content, &content_part/1),
      "isError" => false
    }
  end

  defp tool_result(value) when is_binary(value) do
    %{"content" => [text_content(value)], "isError" => false}
  end

  defp tool_result(value) do
    %{
      "content" => [
        text_content(inspect(value, pretty: true, limit: :infinity))
      ],
      "isError" => false
    }
  end

  defp tool_error(reason) do
    %{
      "content" => [text_content(error_text(reason))],
      "isError" => true
    }
  end

  defp content_part(%ContentPart{type: :text, text: text})
       when is_binary(text),
       do: [text_content(text)]

  defp content_part(_part), do: []

  defp text_content(text), do: %{"type" => "text", "text" => text}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(%_{} = exception), do: Exception.message(exception)
  defp error_text(reason), do: inspect(reason, pretty: true, limit: :infinity)

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    }
  end

  defp request_id(message) when is_map(message), do: Map.get(message, "id")
  defp request_id(_message), do: nil

  defp server_version do
    case Application.spec(:sheaf, :vsn) do
      nil -> "0.1.0"
      version -> to_string(version)
    end
  end
end
