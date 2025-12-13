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

  def fetch_notes(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_history_limit)

    case history_graph(limit: limit) do
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
  attr :variant, :atom, default: :compact

  def note_history(assigns) do
    assigns =
      assigns
      |> assign(
        :groups,
        history_groups(assigns.notes, assigns.notes_graph, assigns.research_session_titles)
      )

    ~H"""
    <section class={history_section_class(@variant)}>
      <div :if={@variant != :expansive} class={history_header_class(@variant)}>
        <h2 class={history_heading_class(@variant)}>
          History
        </h2>
        <.link
          :if={@variant == :compact and @groups != []}
          navigate={~p"/history"}
          class="inline-flex items-center gap-1 rounded-sm px-1.5 py-1 font-sans text-xs text-stone-500 transition-colors hover:bg-stone-200/70 hover:text-stone-950 dark:text-stone-400 dark:hover:bg-stone-800/80 dark:hover:text-stone-100"
        >
          <span>Open</span>
          <.icon name="hero-arrow-up-right" class="size-3" />
        </.link>
      </div>

      <p
        :if={@notes_error}
        class="py-2 text-sm text-rose-700"
      >
        {@notes_error}
      </p>

      <div :if={@groups != []} class={history_group_list_class(@variant)}>
        <.history_group :for={group <- @groups} group={group} variant={@variant} />
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

  attr :group, :map, required: true
  attr :variant, :atom, default: :compact

  defp history_group(%{variant: :expansive} = assigns) do
    ~H"""
    <details id={history_group_id(@group)} class={history_group_class(@variant)}>
      <summary class={history_group_header_class(@variant)}>
        <.icon name={history_icon(@group)} class={history_icon_class(@group)} />
        <span class={history_group_title_class(@variant)}>
          {@group.title}
        </span>
        <time
          :if={@group.published_at}
          datetime={datetime_attr(@group.published_at)}
          class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
        >
          {compact_time(@group.published_at)}
        </time>
        <span class="block w-3 shrink-0 text-center font-mono text-xs leading-snug text-stone-400 transition-transform group-open:rotate-90 dark:text-stone-500">
          ▸
        </span>
      </summary>

      <ol class={history_entries_class(@variant)}>
        <li :for={entry <- @group.entries}>
          <.history_entry entry={entry} variant={@variant} />
        </li>
      </ol>
    </details>
    """
  end

  defp history_group(assigns) do
    ~H"""
    <section id={history_group_id(@group)} class={history_group_class(@variant)}>
      <div class={history_group_header_class(@variant)}>
        <.icon name={history_icon(@group)} class={history_icon_class(@group)} />
        <span class={history_group_title_class(@variant)}>
          {@group.title}
        </span>
        <span class="shrink-0 rounded-sm bg-stone-200/70 px-1.5 py-0.5 font-sans text-[11px] tabular-nums text-stone-600 dark:bg-stone-800 dark:text-stone-300">
          {length(@group.entries)}
        </span>
        <time
          :if={@group.published_at}
          datetime={datetime_attr(@group.published_at)}
          class="shrink-0 font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400"
        >
          {compact_time(@group.published_at)}
        </time>
      </div>

      <ol class={history_entries_class(@variant)}>
        <li :for={entry <- @group.entries}>
          <.history_entry entry={entry} variant={@variant} />
        </li>
      </ol>
    </section>
    """
  end

  attr :entry, :map, required: true
  attr :variant, :atom, default: :compact

  defp history_entry(%{entry: %{type: :note}} = assigns) do
    assigns =
      assigns
      |> assign(:icon, "hero-document-text")
      |> assign(:title, assigns.entry.title || "Research note")
      |> assign(:title_class, "font-medium text-stone-800 dark:text-stone-100")
      |> assign(:text, assigns.entry.text)

    markdown_history_entry(assigns)
  end

  defp history_entry(%{variant: :expansive} = assigns), do: timeline_entry(assigns)

  defp history_entry(%{entry: %{type: :message, role: :user}} = assigns) do
    ~H"""
    <details class={history_entry_class(@variant)}>
      <summary class={history_summary_class(@variant)}>
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

      <article class={history_article_class(@variant)}>
        <div class={history_text_class(@variant, :plain)}>
          {@entry.text}
        </div>
        <.entry_links entry={@entry} />
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

  attr :entry, :map, required: true
  attr :variant, :atom, default: :expansive

  defp timeline_entry(assigns) do
    ~H"""
    <article class="min-w-0 px-2 py-2 text-sm leading-5">
      <div class="mb-0.5 flex items-center gap-1.5 font-sans text-[11px] text-stone-500 dark:text-stone-400">
        <.icon name={timeline_icon(@entry)} class="size-3 shrink-0" />
        <span>{timeline_label(@entry)}</span>
        <time :if={@entry.published_at} datetime={datetime_attr(@entry.published_at)}>
          {compact_time(@entry.published_at)}
        </time>
      </div>
      <h3
        :if={@entry.type == :note and present?(@entry.title)}
        class="mb-1 font-sans text-sm font-medium text-stone-900 dark:text-stone-50"
      >
        {@entry.title}
      </h3>
      <div class={timeline_text_class(@entry)}>
        <%= if @entry.type == :message and @entry.role == :user do %>
          {@entry.text}
        <% else %>
          {raw(render_markdown(@entry.text))}
        <% end %>
      </div>
      <.entry_links entry={@entry} />
    </article>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :title_class, :string, required: true
  attr :text, :string, required: true
  attr :variant, :atom, default: :compact

  defp markdown_history_entry(assigns) do
    ~H"""
    <details class={history_entry_class(@variant)}>
      <summary class={history_summary_class(@variant)}>
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

      <article class={history_article_class(@variant)}>
        <div class={history_text_class(@variant, :markdown)}>
          {raw(render_markdown(@text))}
        </div>
        <.entry_links entry={@entry} />
      </article>
    </details>
    """
  end

  attr :entry, :map, required: true

  defp entry_links(assigns) do
    ~H"""
    <div :if={Map.get(@entry, :mentions, []) != []} class="mt-3 flex flex-wrap gap-1.5">
      <.link
        :for={mention <- @entry.mentions}
        navigate={mention.path}
        class="inline-flex min-w-0 items-center gap-1 rounded-sm bg-stone-200/70 px-1.5 py-1 font-sans text-[11px] text-stone-600 transition-colors hover:bg-stone-300/80 hover:text-stone-950 dark:bg-stone-800 dark:text-stone-300 dark:hover:bg-stone-700 dark:hover:text-stone-50"
      >
        <.icon name={mention.icon} class="size-3 shrink-0" />
        <span class="truncate">{mention.label}</span>
      </.link>
    </div>
    """
  end

  defp chat_kind(%{kind: kind}) when kind in [:research, "research"], do: :research
  defp chat_kind(_chat), do: :chat

  def history_groups(items, graph, session_titles \\ %{})

  def history_groups(items, %Graph{} = graph, session_titles) do
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

  def history_groups(_items, _graph, _session_titles), do: []

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
          published_at: published_at(description),
          mentions: entry_mentions(description, graph)
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
            in_reply_to: first_value(description, Sheaf.NS.AS.inReplyTo()),
            mentions: entry_mentions(description, graph)
          }
        end
    end
  end

  defp entry_sort_key(%{published_at: %DateTime{} = published_at}), do: published_at
  defp entry_sort_key(_entry), do: ~U[0000-01-01 00:00:00Z]

  defp message_role(%Description{} = description, graph) do
    if Description.first(description, Sheaf.NS.AS.inReplyTo()) == nil do
      :user
    else
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
    limit = opts |> Keyword.get(:limit, @default_history_limit) |> normalize_limit()

    with :ok <- Sheaf.Repo.load_once({nil, nil, nil, RDF.iri(Sheaf.Workspace.graph())}) do
      graph =
        Sheaf.Repo.ask(fn dataset ->
          workspace = RDF.Dataset.graph(dataset, Sheaf.Workspace.graph()) || Graph.new()
          limit_history_graph(workspace, limit)
        end)

      {:ok, graph}
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp normalize_limit(_limit), do: @default_history_limit

  defp limit_history_graph(%Graph{} = graph, limit) do
    sessions =
      graph
      |> RDF.Data.descriptions()
      |> Enum.filter(&Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.AssistantConversation}))
      |> Enum.sort_by(&session_sort_key(graph, &1), :desc)
      |> Enum.take(limit)
      |> Enum.map(& &1.subject)
      |> MapSet.new()

    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(fn description ->
      MapSet.member?(sessions, description.subject) ||
        description
        |> Description.first(Sheaf.NS.AS.context())
        |> then(&MapSet.member?(sessions, &1))
    end)
    |> Graph.new()
  end

  defp session_sort_key(graph, session) do
    graph
    |> RDF.Data.descriptions()
    |> Enum.filter(&(Description.first(&1, Sheaf.NS.AS.context()) == session.subject))
    |> Enum.map(fn item ->
      item
      |> Description.first(Sheaf.NS.AS.published())
      |> rdf_value()
      |> case do
        %DateTime{} = published_at -> DateTime.to_unix(published_at)
        nil -> 0
        published_at -> to_string(published_at)
      end
    end)
    |> Enum.max(fn -> 0 end)
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

  defp history_section_class(:expansive), do: "min-w-0"
  defp history_section_class(_variant), do: "mt-4 min-w-0"

  defp history_header_class(:expansive), do: "mb-5 flex items-end justify-between gap-3"
  defp history_header_class(_variant), do: "mb-2 flex items-end justify-between gap-3"

  defp history_heading_class(:expansive),
    do: "font-sans text-lg font-semibold text-stone-900 dark:text-stone-50"

  defp history_heading_class(_variant),
    do: "font-sans text-sm font-semibold uppercase text-stone-500 dark:text-stone-400"

  defp history_group_list_class(:expansive), do: "space-y-3"

  defp history_group_list_class(_variant), do: "space-y-3"

  defp history_group_class(:expansive),
    do: "group min-w-0 overflow-hidden rounded-sm bg-white shadow-sm dark:bg-stone-900"

  defp history_group_class(_variant), do: "space-y-0.5"

  defp history_group_header_class(:expansive),
    do:
      "flex cursor-pointer list-none items-center gap-2 bg-stone-100/80 px-2.5 py-2 transition-colors hover:bg-stone-200/70 dark:bg-stone-950/70 dark:hover:bg-stone-800/80 [&::-webkit-details-marker]:hidden"

  defp history_group_header_class(_variant), do: "flex items-center gap-2 py-1"

  defp history_group_title_class(:expansive),
    do: "min-w-0 flex-1 truncate font-sans text-sm font-medium text-stone-900 dark:text-stone-50"

  defp history_group_title_class(_variant),
    do: "min-w-0 flex-1 truncate font-sans text-sm text-stone-800 dark:text-stone-100"

  defp history_entries_class(:expansive),
    do: "divide-y divide-stone-200/90 bg-white dark:divide-stone-800 dark:bg-stone-900"

  defp history_entries_class(_variant), do: "space-y-0.5"

  defp history_entry_class(:expansive), do: "group"
  defp history_entry_class(_variant), do: "group rounded-sm"

  defp history_summary_class(:expansive),
    do:
      "flex cursor-pointer list-none items-center gap-2 px-3 py-2.5 transition-colors hover:bg-stone-100/80 dark:hover:bg-stone-900 [&::-webkit-details-marker]:hidden"

  defp history_summary_class(_variant),
    do:
      "flex cursor-pointer list-none items-center gap-2 px-2 py-1.5 transition-colors hover:bg-stone-200/60 dark:hover:bg-stone-800/70 [&::-webkit-details-marker]:hidden"

  defp history_article_class(:expansive), do: "px-10 pb-5 pt-1 text-sm leading-6"
  defp history_article_class(_variant), do: "px-9 pb-3 pt-1 text-sm leading-6"

  defp history_text_class(:expansive, :plain),
    do:
      "max-h-[32rem] overflow-y-auto whitespace-pre-line pr-2 break-words text-stone-800 dark:text-stone-100"

  defp history_text_class(:expansive, :markdown),
    do:
      "assistant-prose max-h-[32rem] overflow-y-auto pr-2 break-words text-stone-800 dark:text-stone-100"

  defp history_text_class(_variant, :plain),
    do:
      "max-h-72 overflow-y-auto whitespace-pre-line pr-2 break-words text-stone-800 dark:text-stone-100"

  defp history_text_class(_variant, :markdown),
    do:
      "assistant-prose max-h-72 overflow-y-auto pr-2 break-words text-stone-800 dark:text-stone-100"

  defp history_group_id(%{session_iri: session_iri}), do: "history-#{Id.id_from_iri(session_iri)}"

  defp timeline_icon(%{type: :note}), do: "hero-document-text"
  defp timeline_icon(%{role: :user}), do: "hero-user"
  defp timeline_icon(_entry), do: "hero-sparkles"

  defp timeline_label(%{type: :note}), do: "Note"
  defp timeline_label(%{role: :user}), do: "User"
  defp timeline_label(_entry), do: "Assistant"

  defp timeline_text_class(%{type: :message, role: :user}),
    do: "break-words text-stone-900 dark:text-stone-100"

  defp timeline_text_class(_entry),
    do: "assistant-prose break-words text-stone-800 dark:text-stone-100"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

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

  defp entry_mentions(%Description{} = description, %Graph{} = graph) do
    description
    |> Description.get(Sheaf.NS.DOC.mentions())
    |> List.wrap()
    |> Enum.flat_map(&mention_link(&1, graph))
    |> Enum.uniq_by(& &1.path)
  end

  defp mention_link(%RDF.IRI{} = iri, graph) do
    id = Id.id_from_iri(iri)
    description = RDF.Data.description(graph, iri)

    cond do
      Description.include?(description, {RDF.type(), Sheaf.NS.DOC.Document}) ->
        [%{path: ~p"/#{id}", label: resource_label(graph, iri) || id, icon: "hero-document"}]

      true ->
        [
          %{
            path: ~p"/b/#{id}",
            label: resource_label(graph, iri) || "##{id}",
            icon: "hero-numbered-list"
          }
        ]
    end
  end

  defp mention_link(_resource, _graph), do: []

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
