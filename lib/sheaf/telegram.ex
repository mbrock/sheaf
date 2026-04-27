defmodule Sheaf.Telegram do
  @moduledoc """
  Tiny Telegram Bot API notifier for long-running local tasks.

  Missing Telegram configuration is treated as a no-op so queue commands can run
  normally on machines that do not have a bot configured.
  """

  @spec notify(String.t(), keyword()) :: :ok | {:error, term()}
  def notify(text, opts \\ []) when is_binary(text) do
    case credentials(opts) do
      {:ok, token, chat_id} ->
        send_message(token, chat_id, text, opts)

      :disabled ->
        :ok
    end
  end

  defp send_message(token, chat_id, text, opts) do
    base_url = Keyword.get(opts, :base_url, "https://api.telegram.org")

    Req.post(
      "#{base_url}/bot#{token}/sendMessage",
      form: [
        chat_id: chat_id,
        text: text,
        disable_web_page_preview: "true"
      ],
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    )
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credentials(opts) do
    token = Keyword.get(opts, :token) || System.get_env("TELEGRAM_BOT_TOKEN")
    chat_id = Keyword.get(opts, :chat_id) || System.get_env("TELEGRAM_CHAT_ID")

    if present?(token) and present?(chat_id) do
      {:ok, token, chat_id}
    else
      :disabled
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
