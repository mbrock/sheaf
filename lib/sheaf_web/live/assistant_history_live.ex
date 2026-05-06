defmodule SheafWeb.AssistantHistoryLive do
  @moduledoc """
  Index of persisted assistant conversations and research notes.
  """

  use SheafWeb, :live_view

  require OpenTelemetry.Tracer, as: Tracer

  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  alias SheafWeb.AssistantHistoryComponents

  @impl true
  def mount(_params, _session, socket) do
    Tracer.with_span "SheafWeb.AssistantHistoryLive.mount", %{
      kind: :internal,
      attributes: [{"sheaf.live.connected", connected?(socket)}]
    } do
      {notes, notes_graph, notes_error} =
        AssistantHistoryComponents.fetch_notes(limit: 100)

      research_session_titles =
        AssistantHistoryComponents.research_session_titles()

      groups =
        AssistantHistoryComponents.history_groups(
          notes,
          notes_graph,
          research_session_titles
        )

      rows = Enum.map(groups, &history_row/1)

      Tracer.set_attributes([
        {"sheaf.note_count", length(notes)},
        {"sheaf.history_group_count", length(groups)}
      ])

      {:ok,
       socket
       |> assign(:page_title, "Assistant history")
       |> assign(:notes_error, notes_error)
       |> assign(:rows, rows)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:history} />

      <div class="mx-auto w-full max-w-5xl px-2 py-2 sm:px-4 sm:py-4">
        <section class="mb-3">
          <.live_component
            module={AssistantChatComponent}
            id="assistant-history-composer"
            variant={:assistant_page}
            composer_only?={true}
          />
        </section>

        <div class="mb-2 flex items-end justify-between gap-3 px-1">
          <div class="min-w-0">
            <h1 class="font-sans text-sm font-semibold uppercase tracking-wider text-stone-500 dark:text-stone-400">
              Assistant history
            </h1>
            <p class="mt-0.5 truncate font-sans text-xs text-stone-500 dark:text-stone-400">
              Recent conversations and research notes
            </p>
          </div>
          <span class="font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400">
            {length(@rows)}
          </span>
        </div>

        <p :if={@notes_error} class="px-1 py-2 text-sm text-rose-700">
          {@notes_error}
        </p>

        <ol
          :if={@rows != []}
          class="divide-y divide-stone-200/80 border-y border-stone-200/80 bg-white dark:divide-stone-800 dark:border-stone-800 dark:bg-stone-900/70"
        >
          <li :for={row <- @rows}>
            <article class="min-w-0 px-2 py-2.5 transition-colors hover:bg-stone-100/80 sm:px-3 dark:hover:bg-stone-800/70">
              <.link
                navigate={~p"/#{row.id}"}
                class="block min-w-0 transition-colors hover:text-stone-950 dark:hover:text-stone-50"
              >
                <span class="flex min-w-0 items-center gap-2 font-sans text-[11px] text-stone-500 dark:text-stone-400">
                  <span
                    class="flex size-5 shrink-0 items-center justify-center"
                    title={row.mode_label}
                  >
                    <.icon name={row.icon} class={row.icon_class} />
                  </span>

                  <span :if={row.provider_label} class="shrink-0">
                    {row.provider_label}
                  </span>

                  <time
                    :if={row.published_at}
                    datetime={DateTime.to_iso8601(row.published_at)}
                    class="shrink-0 tabular-nums"
                  >
                    {time_label(row.published_at)}
                  </time>

                  <span class="min-w-0 flex-1"></span>

                  <span
                    :if={row.assistant_count > 0}
                    class="shrink-0 tabular-nums"
                  >
                    {row.assistant_count}
                  </span>
                </span>

                <span class="mt-1 block min-w-0">
                  <span class="line-clamp-5 text-[13px] font-normal leading-5 text-stone-800 sm:line-clamp-4 dark:text-stone-100">
                    {row.initial_message}
                  </span>
                </span>
              </.link>

              <div :if={row.notes != []} class="mt-2 flex flex-wrap gap-1.5 pl-7">
                <.link
                  :for={note <- row.notes}
                  navigate={~p"/#{note.id}"}
                  class="inline-flex max-w-full items-center gap-1 rounded-sm border border-stone-200 bg-stone-50 px-1.5 py-1 font-sans text-[11px] leading-4 text-stone-600 transition-colors hover:border-stone-300 hover:bg-white hover:text-stone-950 dark:border-stone-700 dark:bg-stone-950/50 dark:text-stone-300 dark:hover:border-stone-600 dark:hover:bg-stone-900 dark:hover:text-stone-50"
                  title={note.title}
                >
                  <.icon
                    name="hero-document-text"
                    class="size-3 shrink-0 text-stone-400 dark:text-stone-500"
                  />
                  <span class="truncate">{note.title}</span>
                </.link>
              </div>
            </article>
          </li>
        </ol>

        <p
          :if={@rows == [] and is_nil(@notes_error)}
          class="px-1 py-3 text-sm text-stone-500 dark:text-stone-400"
        >
          No assistant history yet.
        </p>
      </div>
    </main>
    """
  end

  defp history_row(group) do
    entries = group.entries
    id = group.session_iri |> to_string() |> Sheaf.Id.id_from_iri()

    %{
      id: id,
      initial_message:
        initial_user_message(entries) || group.title ||
          "Untitled conversation",
      published_at: group.published_at,
      assistant_count:
        Enum.count(
          entries,
          &(Map.get(&1, :type) == :message and
              Map.get(&1, :role) == :assistant)
        ),
      provider_label: provider_label(entries),
      notes: note_links(entries),
      mode_label: mode_label(group.mode),
      icon: row_icon(group.mode),
      icon_class: row_icon_class(group.mode)
    }
  end

  defp note_links(entries) do
    entries
    |> Enum.filter(&(Map.get(&1, :type) == :note))
    |> Enum.map(fn note ->
      id = note.iri |> to_string() |> Sheaf.Id.id_from_iri()

      %{
        id: id,
        title:
          blank_to_nil(Map.get(note, :title)) ||
            blank_to_nil(Map.get(note, :preview)) ||
            "Research note #{id}"
      }
    end)
  end

  defp initial_user_message(entries) do
    entries
    |> Enum.find_value(fn
      %{type: :message, role: :user, text: text} when is_binary(text) ->
        text

      %{type: :message, role: :user, preview: preview}
      when is_binary(preview) ->
        preview

      _entry ->
        nil
    end)
    |> blank_to_nil()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value) when is_binary(value) and value == "", do: nil
  defp blank_to_nil(value), do: value

  defp mode_label("research"), do: "research"
  defp mode_label(_mode), do: "chat"

  defp provider_label(entries) do
    Enum.find_value(entries, fn
      %{type: :message, role: :assistant, model_name: model_name}
      when is_binary(model_name) ->
        model_provider_label(model_name)

      _entry ->
        nil
    end)
  end

  defp model_provider_label(model_name) do
    normalized = String.downcase(model_name)

    cond do
      String.contains?(normalized, "gpt") or
          String.contains?(normalized, "openai") ->
        "GPT"

      String.contains?(normalized, "claude") or
          String.contains?(normalized, "anthropic") ->
        "Claude"

      true ->
        nil
    end
  end

  defp row_icon("research"), do: "hero-beaker"
  defp row_icon(_mode), do: "hero-chat-bubble-left-ellipsis"

  defp row_icon_class("research"),
    do: "size-4 text-emerald-600 dark:text-emerald-300"

  defp row_icon_class(_mode), do: "size-4 text-stone-400 dark:text-stone-500"

  defp time_label(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end
end
