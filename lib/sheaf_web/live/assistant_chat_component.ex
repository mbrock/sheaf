defmodule SheafWeb.AssistantChatComponent do
  @moduledoc """
  Corpus-aware assistant chat component.

  Tools are stateless wrappers over SPARQL and single-document graph fetches.
  No cached snapshot: each call hits Fuseki, which is fast enough.
  """

  use SheafWeb, :live_component

  alias ReqLLM.{Context, Response, Tool}
  alias Sheaf.{Assistant, Corpus, Document, Documents, Id}

  @default_model "anthropic:claude-opus-4-7"
  @default_max_tokens 65_536
  @max_tool_rounds 500
  @search_result_limit 10

  @mdex_opts [
    extension: [
      strikethrough: true,
      autolink: true,
      table: true,
      tasklist: true
    ],
    render: [unsafe_: false, hardbreaks: true],
    parse: [smart: true]
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:assistant, nil)
     |> assign(:messages, [])
     |> assign(:pending_ref, nil)
     |> assign(:active_tool, nil)
     |> assign(:status_line, nil)
     |> assign(:error, nil)
     |> assign(:form, chat_form())}
  end

  @impl true
  def update(%{assistant_event: event}, socket) do
    {:ok, handle_assistant_event(socket, event)}
  end

  def update(%{assistant_result: {ref, result}}, socket) do
    socket =
      if socket.assigns.pending_ref == ref do
        handle_assistant_result(socket, result)
      else
        socket
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:model, fn -> @default_model end)
      |> assign_new(:llm_options, fn -> [max_tokens: @default_max_tokens] end)
      |> assign_new(:titles, fn -> load_titles() end)
      |> maybe_start_assistant()

    {:ok, socket}
  end

  @impl true
  def handle_event("send", %{"chat" => %{"message" => message}}, socket) do
    message = String.trim(message)

    cond do
      message == "" ->
        {:noreply, assign(socket, :form, chat_form())}

      socket.assigns.pending_ref ->
        {:noreply, socket}

      true ->
        {:noreply, start_turn(socket, message)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="flex min-h-[24rem] flex-col border-t border-stone-200/80 pt-4 dark:border-stone-800/80">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400">
          Assistant
        </h2>
        <span
          :if={@pending_ref}
          class="truncate font-sans text-xs italic text-stone-500 dark:text-stone-400"
        >
          {@status_line || "Thinking"}
        </span>
      </div>

      <div class="mt-3 min-h-0 flex-1 space-y-3 overflow-y-auto pr-1 text-sm">
        <p :if={@messages == []} class="leading-6 text-stone-500 dark:text-stone-400">
          No messages yet.
        </p>

        <div
          :for={message <- @messages}
          class={[
            "rounded-sm px-3 py-2 leading-6",
            message.role == :user &&
              "bg-stone-200/70 text-stone-950 dark:bg-stone-800 dark:text-stone-50",
            message.role == :assistant &&
              "bg-white text-stone-900 dark:bg-stone-900 dark:text-stone-100",
            message.role == :status &&
              "border border-stone-200/80 bg-stone-100/60 font-sans text-xs italic text-stone-600 dark:border-stone-800 dark:bg-stone-900/50 dark:text-stone-400",
            message.role == :error && "bg-red-50 text-red-900 dark:bg-red-950/40 dark:text-red-100"
          ]}
        >
          <.message_body text={message.text} role={message.role} />
        </div>
      </div>

      <.form for={@form} phx-submit="send" phx-target={@myself} class="mt-3 space-y-2">
        <textarea
          name="chat[message]"
          rows="3"
          class="block w-full resize-none rounded-sm border border-stone-300 bg-white px-3 py-2 text-sm leading-5 text-stone-950 outline-none transition-colors placeholder:text-stone-400 focus:border-stone-500 dark:border-stone-700 dark:bg-stone-900 dark:text-stone-50 dark:placeholder:text-stone-500 dark:focus:border-stone-500"
          placeholder="Ask about the thesis or the papers"
          disabled={@pending_ref != nil}
        ></textarea>
        <div class="flex justify-end">
          <button
            type="submit"
            class="grid size-8 place-items-center rounded-sm bg-stone-950 text-stone-50 transition-colors hover:bg-stone-700 disabled:cursor-not-allowed disabled:bg-stone-300 disabled:text-stone-500 dark:bg-stone-50 dark:text-stone-950 dark:hover:bg-stone-300 dark:disabled:bg-stone-800 dark:disabled:text-stone-500"
            title="Send"
            aria-label="Send"
            disabled={@pending_ref != nil}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </.form>
    </section>
    """
  end

  attr :text, :string, required: true
  attr :role, :atom, required: true

  defp message_body(%{role: :assistant} = assigns) do
    ~H"""
    <div class="assistant-prose break-words">
      {raw(render_markdown(@text))}
    </div>
    """
  end

  defp message_body(assigns) do
    ~H"""
    <div class="break-words whitespace-pre-line">{@text}</div>
    """
  end

  defp render_markdown(text) do
    MDEx.to_html!(text, @mdex_opts)
  end

  defp maybe_start_assistant(%{assigns: %{assistant: nil}} = socket) do
    context = Context.new([Context.system(system_prompt())])
    tools = corpus_tools({self(), socket.assigns.id})

    case Assistant.start_link(
           model: socket.assigns.model,
           context: context,
           tools: tools,
           max_tool_rounds: @max_tool_rounds,
           llm_options: socket.assigns.llm_options
         ) do
      {:ok, assistant} ->
        assign(socket, :assistant, assistant)

      {:error, reason} ->
        socket
        |> assign(:error, reason)
        |> append_message(:error, "Could not start assistant: #{inspect(reason)}")
    end
  end

  defp maybe_start_assistant(socket), do: socket

  defp start_turn(socket, text) do
    ref = make_ref()
    live_view = self()
    component = __MODULE__
    component_id = socket.assigns.id
    assistant = socket.assigns.assistant
    input = user_input(text, socket.assigns)

    case Task.Supervisor.start_child(Sheaf.Assistant.TaskSupervisor, fn ->
           result = safe_run(assistant, input)

           Phoenix.LiveView.send_update(live_view, component,
             id: component_id,
             assistant_result: {ref, result}
           )
         end) do
      {:ok, _pid} ->
        socket
        |> assign(:pending_ref, ref)
        |> assign(:status_line, "Thinking")
        |> assign(:form, chat_form())
        |> append_message(:user, text)

      {:error, reason} ->
        append_message(socket, :error, "Could not start assistant turn: #{inspect(reason)}")
    end
  end

  defp safe_run(assistant, input) do
    Assistant.run(assistant, input)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp handle_assistant_result(socket, {:ok, %Response{} = response}) do
    text = Response.text(response) |> blank_to_default()

    socket
    |> assign(:pending_ref, nil)
    |> assign(:active_tool, nil)
    |> assign(:status_line, nil)
    |> assign(:form, chat_form())
    |> append_message(:assistant, text)
  end

  defp handle_assistant_result(socket, {:error, reason}) do
    socket
    |> assign(:pending_ref, nil)
    |> assign(:active_tool, nil)
    |> assign(:status_line, nil)
    |> assign(:form, chat_form())
    |> append_message(:error, "Assistant error: #{inspect(reason)}")
  end

  defp handle_assistant_event(socket, {:tool_started, name, args}) do
    line = humanize_tool(name, args, socket.assigns.titles)

    socket
    |> assign(:active_tool, name)
    |> assign(:status_line, line)
    |> append_message(:status, line)
  end

  defp handle_assistant_event(socket, {:tool_finished, name, {:error, reason}}) do
    socket
    |> assign(:active_tool, nil)
    |> assign(:status_line, "Thinking")
    |> append_message(:error, "Tool #{name} failed: #{inspect(reason)}")
  end

  defp handle_assistant_event(socket, {:tool_finished, _name, _result}) do
    socket
    |> assign(:active_tool, nil)
    |> assign(:status_line, "Thinking")
  end

  defp chat_form, do: to_form(%{"message" => ""}, as: :chat)

  defp append_message(socket, role, text) do
    update(socket, :messages, &(&1 ++ [%{role: role, text: text}]))
  end

  defp user_input(text, assigns) do
    context_lines =
      []
      |> maybe_add_open_document(assigns)
      |> maybe_add_selected(assigns)

    case context_lines do
      [] ->
        Context.user(text)

      lines ->
        Context.user("""
        [context for this turn]
        #{Enum.join(lines, "\n")}

        #{text}
        """)
    end
  end

  defp maybe_add_open_document(lines, %{graph: graph, root: root})
       when not is_nil(graph) and not is_nil(root) do
    title = Document.title(graph, root)
    kind = Document.kind(graph, root)
    id = Document.id(root)
    lines ++ ["Currently open: \"#{title}\" (id #{id}, kind #{kind})"]
  end

  defp maybe_add_open_document(lines, _assigns), do: lines

  defp maybe_add_selected(lines, %{selected_id: selected_id})
       when is_binary(selected_id) and selected_id != "" do
    lines ++ ["Currently selected block: ##{selected_id}"]
  end

  defp maybe_add_selected(lines, _assigns), do: lines

  defp blank_to_default(nil), do: "(no text response)"
  defp blank_to_default(""), do: "(no text response)"
  defp blank_to_default(text), do: text

  defp load_titles do
    case Documents.list() do
      {:ok, docs} -> Map.new(docs, &{&1.id, &1.title})
      _ -> %{}
    end
  end

  defp humanize_tool("list_documents", _args, _titles), do: "Looking at the library"

  defp humanize_tool("get_document", args, titles) do
    "Reading outline of " <> quote_title(args[:id] || args["id"], titles)
  end

  defp humanize_tool("get_block", args, titles) do
    doc_id = args[:document_id] || args["document_id"]
    block_id = args[:block_id] || args["block_id"]
    "Opening ##{block_id} in " <> quote_title(doc_id, titles)
  end

  defp humanize_tool("search_text", args, titles) do
    q = inspect(args[:query] || args["query"] || "")
    scope = args[:document_id] || args["document_id"]

    case scope do
      id when is_binary(id) and id != "" ->
        "Searching " <> q <> " in " <> quote_title(id, titles)

      _ ->
        "Searching the corpus for " <> q
    end
  end

  defp humanize_tool(name, _args, _titles), do: name

  defp quote_title(nil, _titles), do: "an unknown document"
  defp quote_title("", _titles), do: "an unknown document"

  defp quote_title(id, titles) do
    case Map.get(titles, id) do
      nil -> "##{id}"
      title -> ~s("#{ellipsize(title, 48)}")
    end
  end

  defp ellipsize(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp system_prompt do
    """
    You are a research assistant embedded in Sheaf, a reading and writing
    environment for Ieva's master's thesis in anthropology at Tallinn University.
    Her deadline is soon, so be concrete and help her move forward.

    Thesis topic: "Practices of Divestment, Acquisition and Circulation of Things
    in a Swapshop in Riga, Latvia" — an ethnography of brīvbode, a Latvian
    swapshop. The theoretical grounding is practice theory (Shove, Warde, Evans,
    Graeber), consumption work, and quiet sustainability, with supporting
    literature on circulation, second-hand markets, freecycling, and practice
    approaches to sustainable consumption.

    The corpus is:
      * the thesis itself, still being drafted
      * a working pile of papers she is considering reading or citing — not all
        will end up used; part of helping her is figuring out which are worth
        her time

    Every document, section, and paragraph has a stable 6-character id like
    HCFU75. These are block ids. Your responses are rendered as markdown.
    When you reference a block, write it as a markdown link with the hash
    form as visible text and /b/ID as the href, e.g. [#HCFU75](/b/HCFU75).
    Keep the reference inline in your prose — don't put it on its own line.

    Block kinds:
      * section   — headed container; has a title but no direct text
      * paragraph — her own thesis prose
      * extracted — a block from a paper PDF; carries a source page number

    Tool guidance:
      * Use list_documents when you need to know what's in the corpus.
      * Use get_document before drilling into a document; it returns the
        outline so you can pick the right section.
      * Use get_block for a single section or paragraph. Sections return their
        child handles (drill further); paragraphs and extracted blocks return
        text. Every block comes back with its ancestry so you can orient
        yourself and climb upward if you want to.
      * Use search_text to find where a concept or phrase appears. It searches
        the whole corpus by default; pass document_id to scope to one document.

    How to help:
      * Skim papers and report the argument, method, and relevance to the
        thesis so she can decide whether to read in full.
      * When she's stuck on a thesis paragraph, search for supporting or
        contrasting passages in the papers and propose concrete quotes with
        block ids.
      * Clarify concepts from practice theory grounded in the actual corpus
        when possible.
      * Keep answers short by default; go deeper only when she asks.
      * When you cite, use the markdown link form: "(Evans 2020,
        [#4C3K1P](/b/4C3K1P))" for papers, "([#4C3K1P](/b/4C3K1P))" for her
        own prose.

    The user message may include a [context for this turn] block naming the
    document she's currently reading and any block she has selected. Treat
    this as a hint, not a scope restriction — you can navigate elsewhere.
    """
  end

  defp corpus_tools(tool_sink) do
    [
      Tool.new!(
        name: "list_documents",
        description:
          "List every document in the Sheaf corpus (thesis + papers). " <>
            "Returns id, kind, title, authors, year, page count, DOI, venue.",
        callback: instrument(tool_sink, "list_documents", &list_documents_tool/1)
      ),
      Tool.new!(
        name: "get_document",
        description:
          "Return a document's metadata and full section outline. " <>
            "Call this before drilling into a document so you know the structure.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Document id (6-char block id)"]
        ],
        callback: instrument(tool_sink, "get_document", &get_document_tool/1)
      ),
      Tool.new!(
        name: "get_block",
        description:
          "Return one block's content. Sections come with their child handles " <>
            "so you can drill further; paragraphs and extracted blocks come with " <>
            "their full text. Every block includes its ancestry from the document root.",
        parameter_schema: [
          document_id: [type: :string, required: true, doc: "Containing document id"],
          block_id: [type: :string, required: true, doc: "Block id to fetch"]
        ],
        callback: instrument(tool_sink, "get_block", &get_block_tool/1)
      ),
      Tool.new!(
        name: "search_text",
        description:
          "Case-insensitive substring search over paragraph and extracted-block " <>
            "text. Searches the whole corpus by default; pass document_id to scope. " <>
            "Returns hits with their document id, block id, kind, and full text.",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search string"],
          document_id: [type: :string, doc: "Optional: scope to one document"],
          limit: [type: :integer, default: @search_result_limit, doc: "Maximum hits"]
        ],
        callback: instrument(tool_sink, "search_text", &search_text_tool/1)
      )
    ]
  end

  defp instrument({live_view, component_id}, name, callback) do
    fn args ->
      send_tool_event(live_view, component_id, {:tool_started, name, args})
      result = callback.(args)
      send_tool_event(live_view, component_id, {:tool_finished, name, result})
      result
    end
  end

  defp send_tool_event(live_view, component_id, event) do
    Phoenix.LiveView.send_update(live_view, __MODULE__, id: component_id, assistant_event: event)
  end

  defp list_documents_tool(_args) do
    case Documents.list() do
      {:ok, documents} ->
        {:ok, %{documents: Enum.map(documents, &document_summary/1)}}

      {:error, reason} ->
        {:error, "could not list documents: #{inspect(reason)}"}
    end
  end

  defp get_document_tool(%{id: id}) do
    with {:ok, graph} <- Corpus.graph(id) do
      root = Id.iri(id)

      {:ok,
       %{
         id: id,
         title: Document.title(graph, root),
         kind: Document.kind(graph, root),
         outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
       }}
    end
  end

  defp get_block_tool(%{document_id: doc_id, block_id: block_id}) do
    with {:ok, graph} <- Corpus.graph(doc_id) do
      root = Id.iri(doc_id)
      iri = Id.iri(block_id)

      cond do
        iri == root ->
          {:ok,
           %{
             document_id: doc_id,
             id: Id.id_from_iri(root),
             type: :document,
             title: Document.title(graph, root),
             kind: Document.kind(graph, root),
             ancestry: [%{id: Id.id_from_iri(root), type: :document, title: Document.title(graph, root)}],
             outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
           }}

        type = Document.block_type(graph, iri) ->
          payload = render_block(graph, doc_id, iri, type)

          ancestry = Corpus.ancestry(graph, root, iri)
          {:ok, Map.put(payload, :ancestry, ancestry)}

        true ->
          {:error, "block #{block_id} not found in document #{doc_id}"}
      end
    end
  end

  defp search_text_tool(%{query: query} = args) do
    opts =
      [limit: Map.get(args, :limit, @search_result_limit)]
      |> maybe_add_scope(args)

    case Corpus.search_text(query, opts) do
      {:ok, results} -> {:ok, %{query: query, results: results}}
      {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
    end
  end

  defp maybe_add_scope(opts, args) do
    case Map.get(args, :document_id) do
      nil -> opts
      "" -> opts
      id -> Keyword.put(opts, :document_id, id)
    end
  end

  defp document_summary(doc) do
    %{
      id: doc.id,
      kind: doc.kind,
      title: doc.title,
      authors: Map.get(doc.metadata, :authors, []),
      year: Map.get(doc.metadata, :year),
      page_count: Map.get(doc.metadata, :page_count),
      doi: Map.get(doc.metadata, :doi),
      venue: Map.get(doc.metadata, :venue)
    }
  end

  defp outline_entry(%{id: id, title: title, number: number, children: children}) do
    %{
      id: id,
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp render_block(graph, document_id, iri, type) do
    base = %{
      document_id: document_id,
      id: Id.id_from_iri(iri),
      type: type,
      title: block_title(graph, iri, type),
      source: block_source(graph, iri)
    }

    case type do
      :section ->
        Map.put(
          base,
          :children,
          Enum.map(Document.children(graph, iri), &child_handle(graph, &1))
        )

      :paragraph ->
        Map.put(base, :text, Document.paragraph_text(graph, iri))

      :extracted ->
        Map.put(base, :text, plain_text(Document.source_html(graph, iri)))
    end
  end

  defp child_handle(graph, iri) do
    type = Document.block_type(graph, iri)

    %{
      id: Id.id_from_iri(iri),
      type: type,
      title: block_title(graph, iri, type)
    }
  end

  defp block_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_title(_graph, _iri, _type), do: nil

  defp block_source(graph, iri) do
    %{
      key: Document.source_key(graph, iri),
      page: Document.source_page(graph, iri),
      type: Document.source_block_type(graph, iri)
    }
  end

  defp plain_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
