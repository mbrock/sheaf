defmodule SheafWeb.AssistantMarkdown do
  @moduledoc """
  Shared markdown rendering for assistant-visible text.
  """

  alias Sheaf.{BlockRefs, ResourceResolver}

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

  def render(text) do
    (text || "")
    |> BlockRefs.linkify_markdown(url_for: &resource_ref_path/1)
    |> MDEx.to_html!(@mdex_opts)
  end

  defp resource_ref_path(id) do
    case ResourceResolver.resolve(id) do
      {:ok, %{kind: :block}} -> "/b/#{id}"
      {:ok, %{kind: _kind}} -> "/#{id}"
      {:error, _reason} -> nil
    end
  end
end
