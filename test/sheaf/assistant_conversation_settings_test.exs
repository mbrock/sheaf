defmodule Sheaf.Assistant.ConversationSettingsTest do
  use ExUnit.Case, async: false
  use RDF

  alias Sheaf.Assistant.{Activity, ConversationSettings}
  alias Sheaf.Id

  @tag :tmp_dir
  test "persists and restores conversation routing settings", %{
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    assert :ok =
             ConversationSettings.write("CHAT01", %{
               model: "openai:gpt-5.6-sol",
               kind: :research,
               llm_options: [
                 reasoning_effort: :high,
                 provider_options: [reasoning_summary: :auto]
               ]
             })

    assert {:ok,
            %{
              model: "openai:gpt-5.6-sol",
              kind: :research,
              llm_options: options
            }} = ConversationSettings.read("CHAT01")

    assert options[:reasoning_effort] == :high
    assert options[:provider_options][:reasoning_summary] == :auto

    assert :ok =
             ConversationSettings.write("CHAT01", %{
               model: "openai:gpt-5.6-terra",
               kind: :research,
               llm_options: [reasoning_effort: :max]
             })

    assert {:ok, %{model: "openai:gpt-5.6-terra", llm_options: options}} =
             ConversationSettings.read("CHAT01")

    assert options[:reasoning_effort] == :max

    workspace =
      RDF.Dataset.graph(Sheaf.Repo.dataset(), Sheaf.Workspace.graph())

    description = RDF.Graph.description(workspace, Id.iri("CHAT01"))

    assert description
           |> RDF.Description.get(Sheaf.NS.DOC.conversationMode())
           |> Enum.map(&RDF.Literal.value/1) == ["research"]
  end

  @tag :tmp_dir
  test "restores legacy settings from the latest assistant activity", %{
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    session = Id.iri("CHAT02")

    assert {:ok, _message} =
             Activity.write_assistant_message(
               %{
                 session_iri: session,
                 conversation_mode: "research",
                 model_name: "openai:gpt-5.6-sol",
                 text: "Earlier answer."
               },
               published_at: ~U[2026-07-11 08:00:00Z]
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {session, Sheaf.NS.DOC.conversationMode(), "quick"},
                   {session, Sheaf.NS.DOC.conversationMode(), "chat"}
                 ],
                 name: Sheaf.Workspace.graph()
               )
             )

    assert {:ok, settings} = ConversationSettings.read("CHAT02")
    assert settings.model == "openai:gpt-5.6-sol"
    assert settings.kind == :research
    assert settings.llm_options[:reasoning_effort] == :high

    merged =
      ConversationSettings.merge_options("CHAT02",
        model: "anthropic:claude-opus-4-7",
        kind: :chat,
        stream?: true
      )

    assert merged[:model] == "openai:gpt-5.6-sol"
    assert merged[:kind] == :research
    assert merged[:stream?]
  end
end
