defmodule Sheaf.Assistant.ConversationDocument do
  @moduledoc """
  Read-only, text-oriented representation of a persisted assistant conversation.

  This is deliberately built from the persisted ReqLLM context rather than a
  live chat process, so reading a conversation never starts or changes it.
  """

  alias RDF.{Dataset, Description, Graph}
  alias RDF.NS.RDFS
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.ContextStore
  alias Sheaf.NS.DOC

  require OpenTelemetry.Tracer, as: Tracer

  def read(id) when is_binary(id) do
    Tracer.with_span "Sheaf.Assistant.ConversationDocument.read", %{
      kind: :internal,
      attributes: [{"sheaf.assistant.conversation_id", id}]
    } do
      iri = Sheaf.Id.iri(id)

      with {:ok, context} <- ContextStore.read(iri) do
        metadata = metadata(iri)

        document = %{
          id: id,
          iri: to_string(iri),
          title: metadata.title || title_from_context(context),
          mode: metadata.mode,
          messages: Enum.reject(context.messages, &(&1.role == :system))
        }

        Tracer.set_attribute(
          "sheaf.assistant.conversation_message_count",
          length(document.messages)
        )

        {:ok, document}
      end
    end
  end

  def to_markdown(document, canonical_url) when is_map(document) do
    header = [
      "# #{document.title || "Assistant conversation"}",
      "",
      "- Canonical URL: <#{canonical_url}>",
      "- Resource IRI: <#{document.iri}>",
      "- Type: assistant conversation"
    ]

    header =
      if document.mode,
        do: header ++ ["- Mode: #{document.mode}"],
        else: header

    transcript =
      document.messages
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {message, index} ->
        message_markdown(message, index)
      end)

    (header ++ ["", "## Transcript", ""] ++ transcript)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp message_markdown(%{role: :user} = message, index) do
    section("User", index, visible_user_text(message))
  end

  defp message_markdown(%{role: :assistant} = message, index) do
    text = message_text(message)
    calls = message.tool_calls || []

    section =
      if text == "" and calls != [],
        do: ["### #{index}. Assistant tool calls", ""],
        else: section("Assistant", index, text)

    section ++ Enum.flat_map(calls, &tool_call_markdown/1)
  end

  defp message_markdown(%{role: :tool} = message, index) do
    title = "Tool result: #{message.name || "unknown tool"}"
    section(title, index, message_text(message))
  end

  defp message_markdown(message, index) do
    section(
      message.role |> to_string() |> String.capitalize(),
      index,
      message_text(message)
    )
  end

  defp section(title, index, ""),
    do: ["### #{index}. #{title}", "", "(no text)", ""]

  defp section(title, index, text),
    do: ["### #{index}. #{title}", "", text, ""]

  defp tool_call_markdown(tool_call) do
    name = ReqLLM.ToolCall.name(tool_call)
    arguments = ReqLLM.ToolCall.args_map(tool_call) || %{}

    [
      "#### Tool call: `#{name}`",
      "",
      "```json",
      Jason.encode!(arguments, pretty: true),
      "```",
      ""
    ]
  rescue
    _exception -> ["#### Tool call", "", "`#{inspect(tool_call)}`", ""]
  end

  defp visible_user_text(%{metadata: metadata} = message)
       when is_map(metadata) do
    Map.get(metadata, :sheaf_user_text) ||
      Map.get(metadata, "sheaf_user_text") ||
      message_text(message)
  end

  defp visible_user_text(message), do: message_text(message)

  defp message_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(fn
      %ContentPart{type: :text} -> true
      %{type: :text} -> true
      _other -> false
    end)
    |> Enum.map_join("", fn part -> Map.get(part, :text) || "" end)
    |> String.trim()
  end

  defp message_text(_message), do: ""

  defp title_from_context(context) do
    context.messages
    |> Enum.find(&(&1.role == :user))
    |> case do
      nil -> "Assistant conversation"
      message -> message |> visible_user_text() |> first_line_title()
    end
  end

  defp first_line_title(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> "Assistant conversation"
      title -> title
    end
  end

  defp metadata(iri) do
    workspace = RDF.iri(Sheaf.Workspace.graph())

    with :ok <- Sheaf.Repo.load_once({iri, nil, nil, workspace}),
         %Graph{} = graph <-
           Sheaf.Repo.ask(fn dataset -> Dataset.graph(dataset, workspace) end),
         %Description{} = description <- Graph.description(graph, iri) do
      %{
        title: literal(description, RDFS.label()),
        mode: literal(description, DOC.conversationMode())
      }
    else
      _other -> %{title: nil, mode: nil}
    end
  end

  defp literal(description, predicate) do
    description
    |> Description.first(predicate)
    |> case do
      nil -> nil
      value -> RDF.Literal.value(value)
    end
  end
end
