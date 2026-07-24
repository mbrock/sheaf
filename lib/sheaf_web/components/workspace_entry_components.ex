defmodule SheafWeb.WorkspaceEntryComponents do
  @moduledoc """
  Cards for non-document resources that belong to the workspace.
  """

  use SheafWeb, :html

  attr :project, :map, required: true

  def software_project_card(assigns) do
    ~H"""
    <article class="group relative aspect-[2/3] min-w-0 overflow-hidden border border-cyan-900/50 bg-slate-950 transition-colors duration-150 hover:border-cyan-500/70 dark:border-cyan-800/60 dark:hover:border-cyan-400/70">
      <.link
        navigate={@project.path}
        class="absolute inset-0 focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-cyan-300"
      >
        <div class="relative flex size-full flex-col overflow-hidden bg-[radial-gradient(circle_at_75%_20%,rgba(8,145,178,0.22),transparent_42%),linear-gradient(145deg,#020617,#0f172a)] p-3">
          <div class="flex items-center justify-between text-cyan-300/80">
            <.icon name="hero-code-bracket-square" class="size-7" />
            <span class="font-micro text-[10px] uppercase tracking-[0.18em]">
              Software project
            </span>
          </div>

          <div class="mt-auto">
            <div class="mb-3 font-mono text-[10px]/4 text-cyan-200/70">
              <p :if={@project.head}>
                HEAD <span class="text-cyan-100">{@project.head.short_id}</span>
              </p>
              <p :if={@project.head_references != []} class="truncate">
                {Enum.map_join(@project.head_references, ", ", & &1.display_name)}
              </p>
            </div>
            <h3 class="font-sans text-lg/5 font-semibold text-white">
              {@project.title}
            </h3>
            <p class="mt-1 truncate font-mono text-[10px]/4 text-slate-400">
              {@project.repository.label}
            </p>
            <div class="mt-3 grid grid-cols-2 gap-2 border-t border-white/10 pt-2 font-sans text-[10px]/4 text-slate-300">
              <span>{@project.commit_count} commits</span>
              <span class="text-right">{@project.source_file_count} files</span>
            </div>
          </div>
        </div>
      </.link>
    </article>
    """
  end
end
