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

  # LLM-37, LOCAL-10: the breakpoint is OpenRouter's, for a model that documents
  # it; the local server's encoding is untouched.
  test "the local encoding carries no cache breakpoint" do
    request = %{system: "Be brief.", messages: [Message.user("hi")]}

    local = LlamaCpp.build_body(request)
    assert [%{"role" => "system", "content" => "Be brief."} | _] = local["messages"]

    openrouter = OpenRouter.build_body(request, model: "anthropic/claude-opus-5.5")

    assert [%{"role" => "system", "content" => [%{"cache_control" => _}]} | _] =
             openrouter["messages"]
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

  # VISION-8: a user message that carries images has a list of parts for its
  # content — its text, then one `image_url` part per image as a `data:` URL.
  test "encodes an image as an image_url part, and nothing else changes" do
    image = %{type: :image, media_type: "image/jpeg", data: "aGk=", path: "uploads/shot.jpg"}

    history = [
      %Message{role: :user, content: [Message.text("look"), image]},
      %Message{role: :user, content: [image]},
      Message.user("plain")
    ]

    assert [
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "text", "text" => "look"},
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/jpeg;base64,aGk="}
                 }
               ]
             },
             %{
               "role" => "user",
               "content" => [%{"type" => "image_url", "image_url" => %{"url" => "data:" <> _}}]
             },
             %{"role" => "user", "content" => "plain"}
           ] = OpenRouter.encode_messages(history)
  end

  # VISION-8, VISION-14: the tool message keeps its own `tool` message, and the
  # picture a look put in its result becomes the user message that follows it —
  # one part per image, the result's text carried by the `tool` message.
  test "encodes a result's picture as the user message that follows it" do
    history = [
      %Message{
        role: :assistant,
        content: [%{type: :tool_call, id: "c1", name: "view_image", input: %{"path" => "s.png"}}]
      },
      %Message{
        role: :tool,
        content: [
          Message.tool_result("c1", "Looked at s.png."),
          %{type: :image, media_type: "image/png", data: "aGk=", path: "s.png"}
        ]
      }
    ]

    assert [
             %{"role" => "assistant", "tool_calls" => [%{"id" => "c1"}]},
             %{"role" => "tool", "tool_call_id" => "c1", "content" => "Looked at s.png."},
             %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/png;base64,aGk="}
                 }
               ]
             }
           ] = OpenRouter.encode_messages(history)
  end

  # LLM-36, LOCAL-10: one decoder too, so an error code that names no status is
  # read the same way for both — the service's sentence as a plain error.
  test "both read a code that is not a status the same way" do
    chunks = [%{"error" => %{"code" => "model_loading", "message" => "Model unavailable"}}]

    stub_openai_stream(LlamaCpp, self(), chunks)

    assert {:error, "llama.cpp server stream error: Model unavailable"} =
             LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    stub_openai_stream(OpenRouter, self(), chunks)

    assert {:error, "OpenRouter stream error: Model unavailable"} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end
end
