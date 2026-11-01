defmodule Elia.LLM.MessageTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.Message

  # LLM-32
  test "tool results and harness messages can always be JSON-encoded" do
    binary = <<"grep: x.term: binary file matches", 0x83, "é">>

    result = Message.tool_result("1", binary)
    assert result.content == "grep: x.term: binary file matches�é"
    assert Jason.encode!(result)

    assert "[Elia harness] grep: x.term: binary file matches�é" =
             binary |> Message.harness() |> Message.text_content()
  end
end
