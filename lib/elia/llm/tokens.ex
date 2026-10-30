defmodule Elia.LLM.Tokens do
  @moduledoc """
  Local token estimation for the context indicator.

  Estimates are deliberately provider-neutral and cheap: roughly one token per
  four characters (rounded up), the common heuristic for English prose and
  JSON payloads. They are only an approximation of the provider's tokenizer;
  when the provider reports real usage after a turn, that figure is shown
  alongside and calibrates the total (see `Elia.LLM.Context`).
  """

  alias Elia.LLM.Message

  @spec estimate(binary() | nil) :: non_neg_integer()
  def estimate(text) when is_binary(text), do: div(String.length(text) + 3, 4)
  def estimate(nil), do: 0

  @doc "Estimated tokens for a message's blocks."
  @spec estimate_content([map()]) :: non_neg_integer()
  def estimate_content(content) when is_list(content) do
    Enum.reduce(content, 0, &(&2 + estimate_block(&1)))
  end

  def estimate_content(_content), do: 0

  @spec estimate_message(Message.t()) :: non_neg_integer()
  def estimate_message(%Message{content: content}), do: estimate_content(content)

  @doc "Estimated tokens for a single content block (text, reasoning, call, result)."
  @spec estimate_block(map()) :: non_neg_integer()
  def estimate_block(%{type: :text, text: text}), do: estimate(text)

  # CTX-9: the signature is sent back with the block.
  def estimate_block(%{type: :reasoning, text: text} = block),
    do: estimate(text) + signature_tokens(block)

  def estimate_block(%{type: :tool_call, input: input}), do: estimate(encode(input))

  def estimate_block(%{type: :tool_result, content: content}),
    do: estimate(result_text(content))

  # The provider's raw block, sized as the JSON it is sent back as.
  def estimate_block(%{type: :opaque, raw: {_provider, raw}}), do: estimate(encode(raw))

  def estimate_block(_block), do: 0

  # Base64: 3 bytes per 4 characters, at about 4 bytes per token.
  defp signature_tokens(%{raw: {_provider, %{"signature" => signature}}})
       when is_binary(signature),
       do: div(String.length(signature) * 3 + 15, 16)

  defp signature_tokens(_block), do: 0

  @doc "A tool result's content as plain text (handles binary and list payloads)."
  @spec result_text(term()) :: binary()
  def result_text(content) when is_binary(content), do: content

  def result_text(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{"type" => "text", "text" => text} -> text
      %{type: :text, text: text} -> text
      other -> inspect(other)
    end)
  end

  def result_text(other), do: inspect(other)

  defp encode(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> json
      _ -> inspect(input)
    end
  end

  defp encode(other), do: inspect(other)
end
