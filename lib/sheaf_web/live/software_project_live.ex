defmodule SheafWeb.SoftwareProjectLive do
  @moduledoc """
  Renders a software project and its synchronized Git repository.
  """

  use SheafWeb, :html

  alias SheafWeb.AppChrome

  def render(assigns) do
    ~H"""
    <main class="min-h-dvh bg-stone-50 text-stone-950 dark:bg-stone-950 dark:text-stone-50">
      <AppChrome.toolbar section={:index} />

      <div class="mx-auto w-full max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
        <header class="border-b border-stone-200 pb-6 dark:border-stone-800">
          <div class="flex flex-col gap-5 md:flex-row md:items-end md:justify-between">
            <div class="min-w-0">
              <p class="font-sans text-xs font-semibold uppercase tracking-[0.16em] text-cyan-700 dark:text-cyan-400">
                Software project
              </p>
              <h1 class="mt-1 font-sans text-3xl font-semibold tracking-tight sm:text-4xl">
                {@project.title}
              </h1>
              <p class="mt-2 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 font-mono text-xs text-stone-500 dark:text-stone-400">
                <span>{@project.repository.label}</span>
                <span aria-hidden="true">·</span>
                <span>{@project.repository.object_format}</span>
                <span :if={@project.synchronized_at} aria-hidden="true">·</span>
                <span :if={@project.synchronized_at}>
                  synchronized {format_datetime(@project.synchronized_at)}
                </span>
              </p>
            </div>

            <a
              :if={remote_web_url(@project.repository.remote_url)}
              href={remote_web_url(@project.repository.remote_url)}
              target="_blank"
              rel="noreferrer"
              class="inline-flex shrink-0 items-center gap-2 border border-stone-300 bg-white px-3 py-2 font-sans text-sm font-medium hover:border-stone-400 hover:bg-stone-100 dark:border-stone-700 dark:bg-stone-900 dark:hover:border-stone-600 dark:hover:bg-stone-800"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              Open remote
            </a>
          </div>
        </header>

        <section class="grid grid-cols-2 gap-2 py-5 sm:grid-cols-4">
          <.stat label="commits" value={@project.commit_count} />
          <.stat label="source files" value={@project.source_file_count} />
          <.stat label="references" value={@project.reference_count} />
          <.stat
            label="HEAD"
            value={(@project.head && @project.head.short_id) || "unborn"}
            mono
          />
        </section>

        <section class="grid gap-4 lg:grid-cols-[minmax(0,1.4fr)_minmax(18rem,0.6fr)]">
          <div class="min-w-0 border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
            <div class="border-b border-stone-200 px-4 py-3 dark:border-stone-800">
              <h2 class="font-sans text-sm font-semibold">Recent commits</h2>
            </div>
            <ol class="divide-y divide-stone-200 dark:divide-stone-800">
              <li
                :for={commit <- @project.recent_commits}
                class="grid min-w-0 gap-1 px-4 py-3 sm:grid-cols-[6.5rem_minmax(0,1fr)_auto] sm:items-baseline sm:gap-3"
              >
                <code class="font-mono text-xs text-cyan-700 dark:text-cyan-400">
                  {commit.short_id}
                </code>
                <div class="min-w-0">
                  <p class="truncate font-sans text-sm font-medium">
                    {commit_title(commit.message)}
                  </p>
                  <p
                    :if={commit.author}
                    class="mt-0.5 text-xs text-stone-500 dark:text-stone-400"
                  >
                    {commit.author}
                  </p>
                </div>
                <time
                  :if={commit.committed_at || commit.authored_at}
                  class="text-xs text-stone-500 dark:text-stone-400"
                >
                  {format_date(commit.committed_at || commit.authored_at)}
                </time>
              </li>
            </ol>
          </div>

          <aside class="min-w-0 space-y-4">
            <section class="border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
              <div class="border-b border-stone-200 px-4 py-3 dark:border-stone-800">
                <h2 class="font-sans text-sm font-semibold">Repository</h2>
              </div>
              <dl class="divide-y divide-stone-200 text-xs dark:divide-stone-800">
                <.repository_fact
                  label="identity"
                  value={@project.repository.identity}
                />
                <.repository_fact
                  label="checkout"
                  value={@project.repository.checkout_path}
                />
                <.repository_fact
                  label="remote"
                  value={@project.repository.remote_url}
                />
              </dl>
            </section>

            <section class="border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
              <div class="border-b border-stone-200 px-4 py-3 dark:border-stone-800">
                <h2 class="font-sans text-sm font-semibold">References</h2>
              </div>
              <ul class="divide-y divide-stone-200 dark:divide-stone-800">
                <li
                  :for={reference <- @project.references}
                  class="flex min-w-0 items-center gap-2 px-4 py-2 font-mono text-xs"
                >
                  <span class={[
                    "size-1.5 shrink-0 rounded-full",
                    reference.head? && "bg-cyan-500",
                    !reference.head? && "bg-stone-300 dark:bg-stone-700"
                  ]}>
                  </span>
                  <span class="min-w-0 flex-1 truncate">
                    {reference.display_name}
                  </span>
                  <span class="shrink-0 text-[10px] uppercase text-stone-400">
                    {reference.kind}
                  </span>
                </li>
              </ul>
            </section>
          </aside>
        </section>

        <section class="mt-4 border border-stone-200 bg-white dark:border-stone-800 dark:bg-stone-900">
          <div class="flex items-baseline justify-between gap-3 border-b border-stone-200 px-4 py-3 dark:border-stone-800">
            <h2 class="font-sans text-sm font-semibold">Current source tree</h2>
            <span class="font-sans text-xs tabular-nums text-stone-500 dark:text-stone-400">
              {@project.source_file_count} text-bearing files
            </span>
          </div>
          <div class="max-h-[42rem] overflow-auto">
            <table class="w-full border-collapse text-left">
              <thead class="sticky top-0 bg-stone-100/95 font-sans text-[10px] uppercase tracking-wide text-stone-500 backdrop-blur dark:bg-stone-950/95 dark:text-stone-400">
                <tr>
                  <th class="px-4 py-2 font-semibold">Path</th>
                  <th class="w-36 px-4 py-2 font-semibold">Language</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-stone-100 dark:divide-stone-800">
                <tr
                  :for={file <- @project.source_files}
                  class="hover:bg-stone-50 dark:hover:bg-stone-800/50"
                >
                  <td class="max-w-0 px-4 py-2 font-mono text-xs">
                    <span class="block truncate">{file.path}</span>
                  </td>
                  <td class="px-4 py-2 font-sans text-xs text-stone-500 dark:text-stone-400">
                    {file.language || "text"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :mono, :boolean, default: false

  defp stat(assigns) do
    ~H"""
    <div class="border border-stone-200 bg-white px-4 py-3 dark:border-stone-800 dark:bg-stone-900">
      <p class={[
        "text-xl font-semibold tabular-nums",
        @mono && "font-mono text-lg text-cyan-700 dark:text-cyan-400",
        !@mono && "font-sans"
      ]}>
        {@value}
      </p>
      <p class="mt-0.5 font-sans text-[10px] uppercase tracking-wide text-stone-500 dark:text-stone-400">
        {@label}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, default: nil

  defp repository_fact(assigns) do
    ~H"""
    <div
      :if={@value}
      class="grid grid-cols-[5rem_minmax(0,1fr)] gap-3 px-4 py-2.5"
    >
      <dt class="font-sans text-stone-500 dark:text-stone-400">{@label}</dt>
      <dd class="min-w-0 break-all font-mono text-stone-800 dark:text-stone-200">
        {@value}
      </dd>
    </div>
    """
  end

  defp commit_title(message) do
    message
    |> to_string()
    |> String.split("\n", parts: 2)
    |> List.first()
  end

  defp format_datetime(%DateTime{} = timestamp),
    do: Calendar.strftime(timestamp, "%b %-d, %Y %H:%M UTC")

  defp format_datetime(_timestamp), do: nil

  defp format_date(%DateTime{} = timestamp),
    do: Calendar.strftime(timestamp, "%Y-%m-%d")

  defp format_date(_timestamp), do: nil

  defp remote_web_url(nil), do: nil

  defp remote_web_url("git@github.com:" <> path),
    do: "https://github.com/" <> String.trim_trailing(path, ".git")

  defp remote_web_url("https://github.com/" <> _path = url),
    do: String.trim_trailing(url, ".git")

  defp remote_web_url("http://github.com/" <> path),
    do: "https://github.com/" <> String.trim_trailing(path, ".git")

  defp remote_web_url(_url), do: nil
end
