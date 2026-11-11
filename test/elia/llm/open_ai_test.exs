defmodule Elia.LLM.OpenAITest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM.{LlamaCpp, Message, OpenRouter}

  setup do
    reset_settings()
    configure(OpenRouter, model: "vendor/default", api_key: "or-key")
    configure(LlamaCpp, model: "local/model")
    :ok
  end

  defp delta(delta), do: %{"choices" => [%{"index" => 0, "delta" => delta}]}
  defp finish(reason), do: %{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}

  # LOCAL-10: one encoder, so OpenRouter's request and the local server's differ
  # only where they must — the model, and the key each carries.
  test "OpenRouter and the local server build one body the same way" do
    request = %{
      system: "Be brief.",
      messages: [Message.user("hi")],
      tools: [%{name: "shell", description: "Run", input_schema: %{"type" => "object"}}]
    }

    openrouter = OpenRouter.build_body(request, Application.get_env(:elia, OpenRouter))
    local = LlamaCpp.build_body(request)

    assert openrouter == Map.put(local, "model", "vendor/default")
    assert local["model"] == "local/model"
  end

  # LOCAL-10, LOCAL-9: one decoder too — the same stream makes the same message.
  test "the same stream decodes to the same message for both" do
    chunks = [delta(%{"content" => "Hi."}), finish("stop")]

    stub_openai_stream(LlamaCpp, self(), chunks)

    assert {:ok, %{message: message, stop_reason: :end_turn}} =
             LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert message.content == [%{type: :text, text: "Hi."}]

    stub_openai_stream(OpenRouter, self(), chunks)

    assert {:ok, %{message: ^message, stop_reason: :end_turn}} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LOCAL-9, LLM-21: what only OpenRouter does with the encoder — its own
  # reasoning details go back to it, and the local server gets none.
  test "only OpenRouter sends reasoning details back" do
    history = [
      %Message{
        role: :assistant,
        content: [
          %{
            type: :reasoning,
            text: "Let me think.",
            raw:
              {OpenRouter, %{"reasoning_details" => [%{"index" => 0, "text" => "Let me think."}]}}
          },
          Message.text("Listing.")
        ]
      }
    ]

    assert [%{"reasoning_details" => [%{"index" => 0}]}] = OpenRouter.encode_messages(history)
    assert [%{"role" => "assistant", "content" => "Listing."}] = LlamaCpp.encode_messages(history)
  end
end
