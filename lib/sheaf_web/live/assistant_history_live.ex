defmodule SheafWeb.AssistantHistoryLive do
  @moduledoc """
  Expansive browser for persisted assistant conversations and research notes.
  """

  use SheafWeb, :live_view

  alias SheafWeb.AppChrome
  alias SheafWeb.AssistantChatComponent
  alias SheafWeb.AssistantHistoryComponents

  @impl true
  def mount(_params, _session, socket) do
    {notes, notes_graph, notes_error} = AssistantHistoryComponents.fetch_notes(limit: 100)
    research_session_titles = AssistantHistoryComponents.research_session_titles()

    groups =
      AssistantHistoryComponents.history_groups(notes, notes_graph, research_session_titles)

    {:ok,
     socket
     |> assign(:page_title, "Assistant")
     |> assign(:notes, notes)
     |> assign(:notes_graph, notes_graph)
     |> assign(:notes_error, notes_error)
     |> assign(:research_session_titles, research_session_titles)
     |> assign(:groups, groups)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="grid min-h-dvh grid-rows-[auto_1fr] bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:history} />

      <div class="min-h-0 overflow-y-auto px-2 py-2 sm:px-3">
        <div class="mx-auto grid w-full max-w-7xl gap-3 lg:grid-cols-[minmax(19rem,25rem)_minmax(0,1fr)]">
          <section class="min-w-0 rounded-sm border border-stone-200/80 bg-white px-3 py-3 shadow-sm dark:border-stone-800/80 dark:bg-stone-900/70">
            <.live_component
              module={AssistantChatComponent}
              id="assistant-page-agent"
              variant={:assistant_page}
            />
          </section>

          <section class="min-w-0">
            <AssistantHistoryComponents.note_history
              notes={@notes}
              notes_graph={@notes_graph}
              notes_error={@notes_error}
              research_session_titles={@research_session_titles}
              variant={:expansive}
            />
          </section>
        </div>
      </div>
    </main>
    """
  end
end
