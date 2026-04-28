defmodule SheafWeb.AssistantHistoryComponents do
  @moduledoc """
  Shared rendering for persisted assistant research-note history.
  """

  use SheafWeb, :html

  alias RDF.{Description, Graph}
  alias Sheaf.BlockRefs
  alias Sheaf.Assistant.Chats
  alias Sheaf.Id

  @default_history_limit 30

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

  def fetch_notes do
    case history_graph(limit: @default_history_limit) do
      {:ok, graph} -> {history_items(graph), graph, nil}
      {:error, reason} -> {[], Graph.new(), inspect(reason)}
    end
  end

  def research_session_titles do
    Chats.list()
    |> Enum.filter(&(chat_kind(&1) == :research))
    |> Map.new(&{&1.id, &1.title})
  end

  attr :notes, :list, required: true
  attr :notes_graph, :any, required: true
  attr :research_session_titles, :map, default: %{}
  attr :notes_error, :string, default: nil

  def note_history(assigns) do
    ~H"""
    <section class="mt-4 min-w-0">
      <div class="mb-2 flex items-end justify-between gap-3">
        <h2 class="font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400">
          History
        </h2>
      </div>

      <p
        :if={@notes_error}
        class="py-2 text-sm text-rose-700"
      >
        {@notes_error}
      </p>

      <div :if={@notes != []} class="space-y-3">
        <section
          :for={group <- grouped_history(@notes, @notes_graph, @research_session_titles)}
          class="space-y-0.5"
        >
          <div class="flex items-center gap-2 py-1">
            <.icon name={history_icon(group)} class={history_icon_class(group)} />
            <span class="min-w-0 flex-1 truncate font-sans text-sm text-stone-800 dark:text-stone-100">
              {group.title}
            </span>
            <time
              :if={group.published_at}
              datetime={datetime_attr(group.published_at)}
              class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
            >
              {compact_time(group.published_at)}
            </time>
          </div>

          <ol class="space-y-0.5">
            <li :for={entry <- group.entries}>
              <.history_entry entry={entry} />
            </li>
          </ol>
        </section>
      </div>

      <p
        :if={@notes == [] and is_nil(@notes_error)}
        class="py-3 text-sm text-stone-500 dark:text-stone-400"
      >
        No research notes yet.
      </p>
    </section>
    """
  end

  attr :entry, :map, required: true

  defp history_entry(%{entry: %{type: :note}} = assigns) do
    assigns =
      assigns
      |> assign(:icon, "hero-document-text")
      |> assign(:title, assigns.entry.title || "Research note")
      |> assign(:title_class, "font-medium text-stone-800 dark:text-stone-100")
      |> assign(:text, assigns.entry.text)

    markdown_history_entry(assigns)
  end

  defp history_entry(%{entry: %{type: :message, role: :user}} = assigns) do
    ~H"""
    <details class="group rounded-sm">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-2 py-1.5 transition-colors hover:bg-stone-200/60 dark:hover:bg-stone-800/70 [&::-webkit-details-marker]:hidden">
        <span class="flex size-5 shrink-0 items-center justify-center text-stone-400 dark:text-stone-500">
          <.icon name="hero-user" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 truncate font-sans text-sm text-stone-800 dark:text-stone-100">
          {@entry.preview || "User message"}
        </span>
        <span class="block w-3 shrink-0 text-center font-mono text-xs leading-snug text-stone-400 transition-transform group-open:rotate-90 dark:text-stone-500">
          ▸
        </span>
      </summary>

      <article class="px-9 pb-3 pt-1 text-sm leading-6">
        <div class="max-h-72 overflow-y-auto whitespace-pre-line pr-2 break-words text-stone-800 dark:text-stone-100">
          {@entry.text}
        </div>
      </article>
    </details>
    """
  end

  defp history_entry(%{entry: %{type: :message}} = assigns) do
    assigns =
      assigns
      |> assign(:icon, "hero-sparkles")
      |> assign(:title, assigns.entry.preview || "Assistant reply")
      |> assign(:title_class, "text-stone-700 dark:text-stone-200")
      |> assign(:text, assigns.entry.text)

    markdown_history_entry(assigns)
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :title_class, :string, required: true
  attr :text, :string, required: true

  defp markdown_history_entry(assigns) do
    ~H"""
    <details class="group rounded-sm">
      <summary class="flex cursor-pointer list-none items-center gap-2 px-2 py-1.5 transition-colors hover:bg-stone-200/60 dark:hover:bg-stone-800/70 [&::-webkit-details-marker]:hidden">
        <span class="flex size-5 shrink-0 items-center justify-center text-stone-400 dark:text-stone-500">
          <.icon name={@icon} class="size-4" />
        </span>
        <span class={["min-w-0 flex-1 truncate font-sans text-sm", @title_class]}>
          {@title}
        </span>
        <span class="block w-3 shrink-0 text-center font-mono text-xs leading-snug text-stone-400 transition-transform group-open:rotate-90 dark:text-stone-500">
          ▸
        </span>
      </summary>

      <article class="px-9 pb-3 pt-1 text-sm leading-6">
        <div class="assistant-prose max-h-72 overflow-y-auto pr-2 break-words text-stone-800 dark:text-stone-100">
          {raw(render_markdown(@text))}
        </div>
      </article>
    </details>
    """
  end

  defp chat_kind(%{kind: kind}) when kind in [:research, "research"], do: :research
  defp chat_kind(_chat), do: :chat

  defp grouped_history(items, %Graph{} = graph, session_titles) do
    graph
    |> session_descriptions()
    |> Enum.map(fn session ->
      session_iri = to_string(session.subject)
      entries = entries_for_session(items, graph, session_iri)

      %{
        session_iri: session_iri,
        entries: entries,
        published_at: group_published_at(entries),
        mode: session_mode(graph, session_iri)
      }
    end)
    |> Enum.reject(&(&1.entries == []))
    |> Enum.map(&put_history_group_title(&1, graph, session_titles))
    |> Enum.sort_by(fn group -> group_sort_time(group.published_at) end, {:desc, DateTime})
  end

  defp entries_for_session(items, %Graph{} = graph, session_iri) do
    session = RDF.iri(session_iri)

    items
    |> Enum.filter(&Description.include?(&1, {Sheaf.NS.AS.context(), session}))
    |> Enum.map(&entry_from_description(&1, graph))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&entry_sort_key/1, {:asc, DateTime})
  end

  defp put_history_group_title(%{session_iri: session_iri} = group, graph, session_titles) do
    title =
      graph
      |> research_question_content(session_iri)
      |> case do
        title
        when is_binary(title) and title not in ["", "Research session", "Assistant conversation"] ->
          title

        _other ->
          session_iri
          |> session_id()
          |> then(&Map.get(session_titles, &1))
          |> case do
            title
            when is_binary(title) and
                   title not in ["", "Research session", "Assistant conversation"] ->
              title

            _other ->
              case note_group_title(session_resource_label(graph, session_iri)) do
                title when title in ["Research session", "Assistant conversation"] ->
                  note_group_title_from_entries(group.entries)

                title ->
                  title
              end
          end
      end

    Map.put(group, :title, title)
  end

  defp session_descriptions(%Graph{} = graph) do
    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.AssistantConversation}))
  end

  defp history_items(%Graph{} = graph) do
    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&(note?(&1) or message?(&1)))
  end

  defp entry_from_description(%Description{} = description, graph) do
    cond do
      note?(description) ->
        %{
          iri: to_string(description.subject),
          type: :note,
          title: note_title(description),
          text: note_text(description),
          preview: note_title(description) || text_preview(note_text(description)),
          published_at: published_at(description)
        }

      message?(description) ->
        text = message_text(description)

        if text == "" do
          nil
        else
          %{
            iri: to_string(description.subject),
            type: :message,
            role: message_role(description, graph),
            text: text,
            preview: text_preview(text),
            published_at: published_at(description),
            in_reply_to: first_value(description, Sheaf.NS.AS.inReplyTo())
          }
        end
    end
  end

  defp entry_sort_key(%{published_at: %DateTime{} = published_at}), do: published_at
  defp entry_sort_key(_entry), do: ~U[0000-01-01 00:00:00Z]

  defp message_role(%Description{} = description, graph) do
    description
    |> Description.first(Sheaf.NS.AS.attributedTo())
    |> case do
      nil ->
        :assistant

      actor ->
        actor_description = RDF.Data.description(graph, actor)

        cond do
          Description.include?(actor_description, {RDF.type(), Sheaf.NS.AS.Person}) ->
            :user

          Description.include?(actor_description, {RDF.type(), Sheaf.NS.PROV.SoftwareAgent}) ->
            :assistant

          true ->
            :assistant
        end
    end
  end

  defp note?(%Description{} = description),
    do: Description.include?(description, {RDF.type(), Sheaf.NS.AS.Note})

  defp message?(%Description{} = description),
    do: Description.include?(description, {RDF.type(), Sheaf.NS.DOC.Message})

  defp text_preview(text) do
    text
    |> to_string()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> truncate(72)
  end

  defp truncate(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 3) <> "..."
  end

  defp history_graph(opts) do
    result =
      opts
      |> Keyword.get(:limit, @default_history_limit)
      |> normalize_limit()
      |> history_query()
      |> then(&Sheaf.query("assistant history construct", &1))

    case result do
      {:ok, graph} ->
        {:ok, graph}

      {:error, reason} ->
        if fuseki_empty_result_error?(reason) do
          {:ok, Graph.new()}
        else
          {:error, reason}
        end
    end
  end

  defp history_query(limit) do
    """
    PREFIX as: <https://www.w3.org/ns/activitystreams#>
    PREFIX prov: <http://www.w3.org/ns/prov#>
    PREFIX sheaf: <https://less.rest/sheaf/>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

    CONSTRUCT {
      ?session a sheaf:AssistantConversation ;
        a as:OrderedCollection ;
        a ?sessionExtraType ;
        rdfs:label ?sessionLabel ;
        as:name ?sessionName ;
        sheaf:conversationMode ?sessionMode ;
        as:items ?item .

      ?item a ?itemType ;
        rdfs:label ?itemLabel ;
        as:content ?content ;
        as:published ?published ;
        as:attributedTo ?actor ;
        as:context ?session ;
        as:inReplyTo ?replyTarget ;
        sheaf:mentions ?mention .

      ?actor a ?actorType ;
        rdfs:label ?actorLabel ;
        sheaf:assistantModelName ?modelName .
    }
    WHERE {
      {
        SELECT ?session (MAX(?itemPublished) AS ?lastPublished) WHERE {
          GRAPH <#{Sheaf.Workspace.graph()}> {
            ?session a sheaf:AssistantConversation .
            OPTIONAL {
              ?item as:context ?session .
              OPTIONAL { ?item as:published ?itemPublished }
            }
          }
        }
        GROUP BY ?session
        ORDER BY DESC(?lastPublished)
        LIMIT #{limit}
      }

      GRAPH <#{Sheaf.Workspace.graph()}> {
        ?session a sheaf:AssistantConversation .
        OPTIONAL { ?session a ?sessionExtraType . }
        OPTIONAL { ?session rdfs:label ?sessionLabel . }
        OPTIONAL { ?session as:name ?sessionName . }
        OPTIONAL { ?session sheaf:conversationMode ?sessionMode . }

        ?item as:context ?session ;
          a ?itemType .
        FILTER(?itemType IN (sheaf:Message, as:Note, sheaf:ResearchNote))
        OPTIONAL { ?session as:items ?item . }
        OPTIONAL { ?item rdfs:label ?itemLabel . }
        OPTIONAL { ?item as:content ?content . }
        OPTIONAL { ?item as:published ?published . }
        OPTIONAL { ?item as:inReplyTo ?replyTarget . }
        OPTIONAL { ?item sheaf:mentions ?mention . }
        OPTIONAL {
          ?item as:attributedTo ?actor .
          OPTIONAL { ?actor a ?actorType . }
          OPTIONAL { ?actor rdfs:label ?actorLabel . }
          OPTIONAL { ?actor sheaf:assistantModelName ?modelName . }
        }
      }
    }
    """
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_limit), do: @default_history_limit

  defp fuseki_empty_result_error?(reason) do
    reason
    |> inspect()
    |> String.contains?("Peek iterator is already empty")
  end

  defp research_question_content(_graph, nil), do: nil

  defp research_question_content(%Graph{} = graph, session_iri) do
    session = RDF.iri(session_iri)

    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.Message}))
    |> Enum.filter(&Description.include?(&1, {Sheaf.NS.AS.context(), session}))
    |> Enum.reject(&(Description.first(&1, Sheaf.NS.AS.inReplyTo()) != nil))
    |> Enum.sort_by(fn question ->
      question
      |> Description.first(Sheaf.NS.AS.published())
      |> rdf_value()
      |> case do
        %DateTime{} = published_at -> DateTime.to_unix(published_at)
        nil -> 0
        published_at -> to_string(published_at)
      end
    end)
    |> List.first()
    |> case do
      %Description{} = question -> first_value(question, Sheaf.NS.AS.content())
      nil -> nil
    end
  end

  defp note_group_title(nil), do: "Assistant conversation"
  defp note_group_title(""), do: "Assistant conversation"
  defp note_group_title("Research session " <> _id), do: "Research session"
  defp note_group_title("Assistant conversation " <> _id), do: "Assistant conversation"
  defp note_group_title(title), do: title

  defp common_note_title([]), do: "Assistant conversation"
  defp common_note_title([title]), do: title

  defp common_note_title(titles) do
    prefix =
      titles
      |> Enum.reduce(&common_prefix/2)
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.trim_trailing("→")
      |> String.trim()

    if String.length(prefix) >= 12, do: prefix, else: hd(titles)
  end

  defp note_group_title_from_entries(entries) do
    entries
    |> Enum.map(fn
      %{type: :note, title: title} -> title
      %{type: :message, role: :user, preview: preview} -> preview
      _entry -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> common_note_title()
  end

  defp common_prefix(left, right) do
    left_chars = String.graphemes(left)
    right_chars = String.graphemes(right)

    left_chars
    |> Enum.zip(right_chars)
    |> Enum.take_while(fn {left, right} -> left == right end)
    |> Enum.map_join(fn {char, _} -> char end)
  end

  defp session_id(nil), do: nil
  defp session_id(session_iri), do: Id.id_from_iri(session_iri)

  defp session_resource_label(_graph, nil), do: nil
  defp session_resource_label(graph, session_iri), do: resource_label(graph, RDF.iri(session_iri))

  defp session_mode(_graph, nil), do: nil

  defp session_mode(graph, session_iri) do
    graph
    |> RDF.Data.description(RDF.iri(session_iri))
    |> first_value(Sheaf.NS.DOC.conversationMode())
  end

  defp history_icon(%{mode: "research"}), do: "hero-beaker"
  defp history_icon(_group), do: "hero-chat-bubble-left-ellipsis"

  defp history_icon_class(%{mode: "research"}),
    do: "size-3.5 shrink-0 text-emerald-600 dark:text-emerald-300"

  defp history_icon_class(_group), do: "size-3.5 shrink-0 text-stone-400 dark:text-stone-500"

  defp group_published_at(entries) do
    entries
    |> Enum.map(&Map.get(&1, :published_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp group_sort_time(%DateTime{} = published_at), do: published_at
  defp group_sort_time(_published_at), do: ~U[0000-01-01 00:00:00Z]

  defp note_title(%Description{} = note), do: first_value(note, RDF.NS.RDFS.label())
  defp note_text(%Description{} = note), do: first_value(note, Sheaf.NS.AS.content()) || ""

  defp message_text(%Description{} = message),
    do: first_value(message, Sheaf.NS.AS.content()) || ""

  defp published_at(%Description{} = description) do
    description
    |> Description.first(Sheaf.NS.AS.published())
    |> rdf_value()
  end

  defp datetime_attr(%DateTime{} = published_at), do: DateTime.to_iso8601(published_at)
  defp datetime_attr(published_at), do: to_string(published_at)

  defp compact_time(published_at) do
    case published_at do
      %DateTime{} = published_at -> Calendar.strftime(published_at, "%b %-d, %H:%M")
      published_at -> to_string(published_at)
    end
  end

  defp first_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> rdf_value()
  end

  defp resource_label(_graph, nil), do: nil

  defp resource_label(%Graph{} = graph, resource) do
    graph
    |> RDF.Data.description(resource)
    |> first_value(RDF.NS.RDFS.label())
  end

  defp rdf_value(nil), do: nil

  defp rdf_value(term) do
    case RDF.Term.value(term) do
      %DateTime{} = value -> value
      value -> to_string(value)
    end
  end

  defp render_markdown(text) do
    (text || "")
    |> BlockRefs.linkify_markdown()
    |> MDEx.to_html!(@mdex_opts)
  end
end
