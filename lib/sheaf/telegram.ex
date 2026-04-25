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
    env = dotenv()
    token = Keyword.get(opts, :token) || env_value("TELEGRAM_BOT_TOKEN", env)
    chat_id = Keyword.get(opts, :chat_id) || env_value("TELEGRAM_CHAT_ID", env)

    if present?(token) and present?(chat_id) do
      {:ok, token, chat_id}
    else
      :disabled
    end
  end

  defp env_value(key, dotenv), do: System.get_env(key) || Map.get(dotenv, key)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp dotenv do
    path = Path.expand(".env")

    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce(%{}, &parse_env_line/2)
    else
      %{}
    end
  end

  defp parse_env_line(line, acc) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        acc

      true ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put(acc, key, unquote_env(value))
          _ -> acc
        end
    end
  end

  defp unquote_env(value) do
    value = String.trim(value)

    if String.length(value) >= 2 and String.first(value) == String.last(value) and
         String.first(value) in ["\"", "'"] do
      value |> String.slice(1..-2//1)
    else
      value
    end
  end
end
