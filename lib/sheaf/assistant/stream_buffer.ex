defmodule Sheaf.Assistant.StreamBuffer do
  @moduledoc """
  Buffers streamed assistant text into UI-sized Markdown-friendly chunks.

  LLM providers usually deliver arbitrary token fragments. For the chat UI we
  prefer to publish chunks that look like syntactic units, while avoiding the
  most jarring Markdown half-states such as unclosed links or fenced code.
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: String.t()}

  @abbreviations MapSet.new(~w[
    adj adm adv al approx assn bros capt cf col corp dept dr ed e.g est etc fig
    figs gen gov i.e inc jr lt ltd maj misc mr mrs ms no nos prof rep rev sen
    sr st vs
  ])

  @max_buffer_bytes 900

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec push(t() | nil, String.t()) :: {[String.t()], t()}
  def push(buffer, text) when is_binary(text) do
    buffer = buffer || new()
    drain(%{buffer | buffer: buffer.buffer <> text})
  end

  @spec flush(t() | nil) :: {String.t(), t()}
  def flush(nil), do: {"", new()}
  def flush(%__MODULE__{buffer: text}), do: {text, new()}

  defp drain(%__MODULE__{buffer: ""} = buffer), do: {[], buffer}

  defp drain(%__MODULE__{buffer: text} = buffer) do
    case safe_cutoff(text) do
      nil ->
        {[], buffer}

      cutoff ->
        <<chunk::binary-size(cutoff), rest::binary>> = text
        {[chunk], %{buffer | buffer: rest}}
    end
  end

  defp safe_cutoff(text) do
    candidates(text)
    |> Enum.filter(&safe_prefix?(binary_part(text, 0, &1)))
    |> List.last()
  end

  defp candidates(text) do
    []
    |> add_markdown_block_candidates(text)
    |> add_sentence_candidates(text)
    |> add_overflow_candidate(text)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_markdown_block_candidates(candidates, text) do
    Regex.scan(~r/\n{2,}/u, text, return: :index)
    |> Enum.reduce(candidates, fn [{start, length}], acc -> [start + length | acc] end)
    |> then(fn acc ->
      Regex.scan(
        ~r/(?:^|\n)(?:\s{0,3}(?:\#{1,6}\s|[-*+]\s+|\d+[.)]\s+|>\s?|```|~~~|[-*_]{3,}\s*$|\|).*\n)/u,
        text,
        return: :index
      )
      |> Enum.reduce(acc, fn [{start, length}], acc -> [start + length | acc] end)
    end)
  end

  defp add_sentence_candidates(candidates, text) do
    Regex.scan(~r/[.!?][)"'\]\}»”’*_]*(?:\s+|$)/u, text, return: :index)
    |> Enum.reduce(candidates, fn [{start, length}], acc ->
      cutoff = start + length

      if abbreviation_boundary?(binary_part(text, 0, cutoff)) do
        acc
      else
        [cutoff | acc]
      end
    end)
  end

  defp add_overflow_candidate(candidates, text) do
    if byte_size(text) > @max_buffer_bytes do
      case overflow_cutoff(text) do
        nil -> candidates
        cutoff -> [cutoff | candidates]
      end
    else
      candidates
    end
  end

  defp overflow_cutoff(text) do
    text
    |> binary_part(0, min(byte_size(text), @max_buffer_bytes))
    |> String.split(~r/\s/u, include_captures: true, trim: false)
    |> Enum.reduce_while({0, nil}, fn part, {offset, last_space} ->
      next_offset = offset + byte_size(part)
      last_space = if String.match?(part, ~r/^\s+$/u), do: next_offset, else: last_space

      if next_offset >= div(@max_buffer_bytes, 2) and last_space do
        {:halt, last_space}
      else
        {:cont, {next_offset, last_space}}
      end
    end)
    |> case do
      {_offset, cutoff} -> cutoff
      cutoff when is_integer(cutoff) -> cutoff
      _other -> nil
    end
  end

  defp abbreviation_boundary?(prefix) do
    prefix
    |> String.trim_trailing()
    |> String.replace(~r/[)"'\]\}»”’*_]+$/u, "")
    |> String.split(~r/\s/u)
    |> List.last()
    |> case do
      nil ->
        false

      word ->
        normalized =
          word
          |> String.trim(".")
          |> String.trim()
          |> String.downcase()

        MapSet.member?(@abbreviations, normalized)
    end
  end

  defp safe_prefix?(prefix) do
    not unclosed_code_fence?(prefix) and balanced_inline_code?(prefix) and
      balanced_square_brackets?(prefix) and balanced_emphasis?(prefix)
  end

  defp unclosed_code_fence?(text) do
    text
    |> String.split("\n")
    |> Enum.count(&String.match?(&1, ~r/^\s{0,3}(```|~~~)/))
    |> rem(2) == 1
  end

  defp balanced_inline_code?(text) do
    text
    |> String.replace(~r/```.*?```/us, "")
    |> then(&Regex.scan(~r/`+/, &1))
    |> Enum.map(fn [ticks] -> byte_size(ticks) end)
    |> Enum.count(&(&1 == 1))
    |> rem(2) == 0
  end

  defp balanced_square_brackets?(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while(0, fn
      "[", count -> {:cont, count + 1}
      "]", count when count > 0 -> {:cont, count - 1}
      "]", _count -> {:halt, :unbalanced}
      _grapheme, count -> {:cont, count}
    end)
    |> Kernel.==(0)
  end

  defp balanced_emphasis?(text) do
    even_occurrences?(text, "**") and even_occurrences?(text, "__")
  end

  defp even_occurrences?(text, marker) do
    marker
    |> Regex.escape()
    |> Regex.compile!()
    |> Regex.scan(text)
    |> length()
    |> rem(2) == 0
  end
end
