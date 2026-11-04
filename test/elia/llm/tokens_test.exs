defmodule Elia.LLM.TokensTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.{Message, Tokens}

  # CTX-3: estimate is ~1 token per 4 characters.
  test "estimate is roughly one token per four characters" do
    assert Tokens.estimate("") == 0
    assert Tokens.estimate("abcd") == 1
    assert Tokens.estimate("abcdefgh") == 2
    assert Tokens.estimate("abc") == 1
    assert Tokens.estimate(nil) == 0

    long = String.duplicate("the quick brown fox jumps over the lazy dog ", 100)
    assert Tokens.estimate(long) == div(String.length(long) + 3, 4)
  end

  test "estimate_content sums text, reasoning, tool calls and results" do
    content = [
      %{type: :text, text: String.duplicate("a", 8)},
      %{type: :reasoning, text: String.duplicate("b", 8)},
      %{
        type: :tool_call,
        id: "c1",
        name: "shell",
        input: %{"command" => String.duplicate("c", 8)}
      },
      %{
        type: :tool_result,
        tool_call_id: "c1",
        content: String.duplicate("d", 8),
        is_error: false
      }
    ]

    assert Tokens.estimate_content(content) == 12
    # 2 (text) + 2 (reasoning) + 6 (call JSON) + 2 (result)
    message = %Message{role: :assistant, content: content}
    assert Tokens.estimate_message(message) == Tokens.estimate_content(content)
  end

  # CTX-3: opaque provider blocks are sized as the JSON sent back.
  test "opaque blocks are estimated from their raw JSON" do
    raw = %{"type" => "redacted_thinking", "data" => String.duplicate("x", 40)}
    block = %{type: :opaque, raw: {Elia.LLM.Anthropic, raw}}
    assert Tokens.estimate_block(block) == Tokens.estimate(Jason.encode!(raw))
  end

  # CTX-9: a signed reasoning block counts the larger of its text and signature.
  test "reasoning blocks are the larger of their text and signature" do
    raw = %{"type" => "thinking", "signature" => String.duplicate("s", 160)}
    signed = fn text -> %{type: :reasoning, text: text, raw: {Elia.LLM.Anthropic, raw}} end

    # 160 characters is 120 bytes, at 4 bytes per token.
    assert Tokens.estimate_block(signed.("")) == 30
    assert Tokens.estimate_block(signed.("abcd")) == 30
    assert Tokens.estimate_block(signed.(String.duplicate("a", 400))) == 100

    # The size rounds up.
    short = %{type: :reasoning, text: "", raw: {Elia.LLM.Anthropic, %{"signature" => "abc"}}}
    assert Tokens.estimate_block(short) == 1

    assert Tokens.estimate_block(%{type: :reasoning, text: "abcd"}) == 1
  end

  test "result_text handles binary and structured content" do
    assert Tokens.result_text("plain") == "plain"

    assert Tokens.result_text([%{"type" => "text", "text" => "a"}, %{type: :text, text: "b"}]) ==
             "a\nb"
  end

  # LIMIT-12: a token count written short, with a small one staying as it was
  # typed.
  test "format writes a count short" do
    assert Tokens.format(0) == "0"
    assert Tokens.format(900) == "900"
    assert Tokens.format(1100) == "1100"
    assert Tokens.format(9999) == "9999"
    assert Tokens.format(10_000) == "10K"
    assert Tokens.format(500_000) == "500K"
    assert Tokens.format(1_000_000) == "1M"
    assert Tokens.format(1_500_000) == "1.5M"
  end
end
