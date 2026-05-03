defmodule Sheaf.LLM do
  @moduledoc """
  Shared LLM boundary for Sheaf features.

  This module owns the ReqLLM defaults and request plumbing. Callers
  remain responsible for domain-specific prompts, schemas, and normalization.
  """

  alias ReqLLM.{Context, Response}
  alias ReqLLM.Message.ContentPart

  @claude_assistant_model "anthropic:claude-opus-4-7"
  @gpt_assistant_model "openai:gpt-5.5"
  @default_model @claude_assistant_model
  @default_max_tokens 65_536
  @default_thinking %{type: "adaptive", display: "omitted"}
  @default_receive_timeout 300_000

  @type object_result :: %{
          required(:object) => map(),
          required(:model) => String.t(),
          required(:usage) => map() | nil
        }

  @doc """
  The default ReqLLM model spec used by Sheaf.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  The assistant provider choices Sheaf exposes in the chat UI.
  """
  @spec assistant_model_options() :: [
          %{provider: String.t(), label: String.t(), model: String.t()}
        ]
  def assistant_model_options do
    [
      %{provider: "claude", label: "Claude", model: @claude_assistant_model},
      %{provider: "gpt", label: "GPT", model: @gpt_assistant_model}
    ]
  end

  @doc """
  The default assistant provider key.
  """
  @spec default_assistant_provider() :: String.t()
  def default_assistant_provider, do: "claude"

  @doc """
  Resolves a chat UI provider key to the ReqLLM model spec used for assistant turns.
  """
  @spec assistant_model_for_provider(term()) :: String.t()
  def assistant_model_for_provider("gpt"), do: @gpt_assistant_model
  def assistant_model_for_provider(:gpt), do: @gpt_assistant_model
  def assistant_model_for_provider(_provider), do: @claude_assistant_model

  @doc """
  Returns the chat UI provider key for an assistant model spec.
  """
  @spec assistant_provider_for_model(term()) :: String.t()
  def assistant_provider_for_model(@gpt_assistant_model), do: "gpt"
  def assistant_provider_for_model(_model), do: "claude"

  @doc """
  Default LLM options for an assistant provider and conversation mode.
  """
  @spec assistant_llm_options(term(), term()) :: keyword()
  def assistant_llm_options(provider_or_model, mode) do
    provider_or_model
    |> assistant_provider_key()
    |> do_assistant_llm_options(normalize_assistant_mode(mode))
  end

  @doc """
  The default max-token setting used by Sheaf.
  """
  @spec default_max_tokens() :: pos_integer()
  def default_max_tokens, do: @default_max_tokens

  @doc """
  The default thinking configuration used for Claude Opus 4.7.
  """
  @spec default_thinking() :: map()
  def default_thinking, do: @default_thinking

  @doc """
  Builds a user message from content parts.
  """
  def user_message(parts) when is_list(parts), do: Context.user(parts)

  @doc """
  Builds a text content part.
  """
  def text_part(text) when is_binary(text), do: ContentPart.text(text)

  @doc """
  Builds a file content part.
  """
  def file_part(data, filename, media_type)
      when is_binary(data) and is_binary(filename) and is_binary(media_type) do
    ContentPart.file(data, filename, media_type)
  end

  @doc """
  Generates a structured object with ReqLLM.

  Options:

    * `:model` - ReqLLM model spec, defaulting to Claude Opus 4.7.
    * `:max_tokens` - response length limit, defaulting to 65,536.
    * `:thinking` - thinking configuration. Claude Opus 4.7 defaults to
      `%{type: "adaptive", display: "omitted"}`; pass `nil` or `false`
      to omit it. This is sent in `:provider_options`, which is the shape
      ReqLLM's Anthropic provider accepts.
    * `:reasoning_effort` - provider-neutral reasoning effort for providers
      where ReqLLM handles the translation. No default is applied.
    * `:receive_timeout` - Req receive timeout in milliseconds, defaulting to 300s.
    * `:provider_options` - additional provider options.
    * `:llm_options` - extra ReqLLM options merged into the final request.
    * `:generate_object` - test seam, defaulting to `ReqLLM.generate_object/4`.
  """
  @spec generate_object(term(), keyword(), keyword()) :: {:ok, object_result()} | {:error, term()}
  def generate_object(message, schema, opts \\ []) when is_list(schema) do
    model = Keyword.get(opts, :model, @default_model)
    generate_object = Keyword.get(opts, :generate_object, &ReqLLM.generate_object/4)

    case generate_object.(model, message, schema, request_options(opts)) do
      {:ok, response} ->
        with {:ok, object} <- response_object(response) do
          {:ok, %{object: object, model: model, usage: response_usage(response)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generates text with ReqLLM using Sheaf's shared request defaults.
  """
  @spec generate_text(String.t(), Context.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def generate_text(model, %Context{} = context, opts \\ []) do
    ReqLLM.generate_text(
      model,
      context,
      Keyword.put(opts, :model, model) |> text_request_options()
    )
  end

  @doc false
  def request_options(opts) do
    model = Keyword.get(opts, :model, @default_model)
    provider_options = provider_options(opts)
    raw_llm_options = opts |> Keyword.get(:llm_options, []) |> Keyword.delete(:temperature)
    llm_options = Keyword.delete(raw_llm_options, :provider_options)

    llm_provider_options =
      raw_llm_options
      |> Keyword.get(:provider_options, [])
      |> Keyword.delete(:temperature)

    [
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      provider_options:
        model
        |> model_provider_options(opts)
        |> Keyword.merge(provider_options)
        |> Keyword.merge(llm_provider_options)
    ]
    |> put_optional(:reasoning_effort, Keyword.get(opts, :reasoning_effort))
    |> omit_disabled(:max_tokens)
    |> Keyword.merge(llm_options)
    |> Keyword.update!(:provider_options, &Keyword.delete(&1, :temperature))
    |> Keyword.delete(:temperature)
  end

  @doc false
  def provider_options(opts) do
    opts
    |> Keyword.get(:provider_options, [])
    |> Keyword.delete(:temperature)
  end

  @doc false
  def text_request_options(opts) do
    opts
    |> request_options()
    |> put_default_context_cache_options(Keyword.get(opts, :model, @default_model))
    |> Keyword.merge(text_passthrough_options(opts))
    |> Keyword.update!(:provider_options, &Keyword.delete(&1, :temperature))
    |> Keyword.delete(:temperature)
  end

  @doc false
  def response_object(%ReqLLM.Response{} = response) do
    case Response.object(response) do
      object when is_map(object) -> {:ok, object}
      _ -> {:error, :missing_object}
    end
  end

  def response_object(%{object: object}) when is_map(object), do: {:ok, object}
  def response_object(object) when is_map(object), do: {:ok, object}
  def response_object(_), do: {:error, :missing_object}

  @doc false
  def response_usage(%ReqLLM.Response{} = response), do: Response.usage(response)
  def response_usage(%{usage: usage}) when is_map(usage), do: usage
  def response_usage(_), do: nil

  defp assistant_provider_key("gpt"), do: "gpt"
  defp assistant_provider_key(:gpt), do: "gpt"

  defp assistant_provider_key(provider_or_model),
    do: assistant_provider_for_model(provider_or_model)

  defp normalize_assistant_mode(:research), do: :research
  defp normalize_assistant_mode("research"), do: :research
  defp normalize_assistant_mode(_mode), do: :quick

  defp do_assistant_llm_options("gpt", :research), do: [reasoning_effort: :high]
  defp do_assistant_llm_options("gpt", _mode), do: [reasoning_effort: :medium]
  defp do_assistant_llm_options(_provider, _mode), do: []

  defp anthropic_adaptive_model?("anthropic:claude-opus-4-7"), do: true
  defp anthropic_adaptive_model?("claude-opus-4-7"), do: true
  defp anthropic_adaptive_model?(_model), do: false

  defp anthropic_model?(model) when is_binary(model) do
    String.starts_with?(model, "anthropic:") or String.starts_with?(model, "claude-")
  end

  defp anthropic_model?({:anthropic, _opts}), do: true
  defp anthropic_model?(%{provider: :anthropic}), do: true
  defp anthropic_model?(_model), do: false

  defp model_provider_options(model, caller_opts) do
    cond do
      Keyword.has_key?(caller_opts, :thinking) ->
        provider_thinking_options(Keyword.get(caller_opts, :thinking))

      anthropic_adaptive_model?(model) ->
        [thinking: @default_thinking]

      true ->
        []
    end
  end

  defp provider_thinking_options(thinking) when thinking in [nil, false], do: []
  defp provider_thinking_options(thinking), do: [thinking: thinking]

  defp put_default_context_cache_options(opts, model) do
    if anthropic_model?(model) do
      Keyword.update!(opts, :provider_options, fn provider_options ->
        provider_options
        |> List.wrap()
        |> Keyword.put_new(:anthropic_prompt_cache, true)
        |> Keyword.put_new(:anthropic_cache_messages, true)
      end)
    else
      opts
    end
  end

  defp put_optional(opts, _key, value) when value in [nil, false], do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp omit_disabled(opts, key) do
    if Keyword.get(opts, key) in [nil, false] do
      Keyword.delete(opts, key)
    else
      opts
    end
  end

  defp text_passthrough_options(opts) do
    opts
    |> Keyword.take([:tools])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
