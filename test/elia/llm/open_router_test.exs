defmodule Elia.LLM.OpenRouterTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM.{Message, OpenRouter}

  setup do
    reset_settings()
    configure(OpenRouter, api_key: "or-key", model: "vendor/default")
    :ok
  end

  defp delta(delta, extra \\ %{}) do
    Map.merge(%{"model" => "vendor/m", "choices" => [%{"index" => 0, "delta" => delta}]}, extra)
  end

  defp finish(reason), do: %{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}

  # LLM-17
  test "without a key, returns an error and makes no request" do
    configure(OpenRouter)
    Req.Test.stub(OpenRouter, fn _conn -> flunk("no request expected") end)

    assert {:error, "No OpenRouter API key: add one in Settings or set OPENROUTER_API_KEY"} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LLM-18, LLM-20, LLM-21
  test "streams text, reasoning and tool calls into a neutral message" do
    stub_openrouter_stream(self(), [
      delta(%{"role" => "assistant", "reasoning" => "Let me "}),
      delta(%{
        "reasoning" => "think.",
        "reasoning_details" => [%{"type" => "reasoning.text", "index" => 0, "text" => "Let me "}]
      }),
      delta(%{
        "reasoning_details" => [
          %{"type" => "reasoning.text", "index" => 0, "text" => "think.", "signature" => "sig"}
        ]
      }),
      delta(%{"content" => "Look"}),
      delta(%{"content" => "ing."}),
      delta(%{
        "tool_calls" => [
          %{
            "index" => 0,
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "shell", "arguments" => ""}
          }
        ]
      }),
      delta(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"command\":"}}]}),
      delta(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"ls\"}"}}]}),
      finish("tool_calls"),
      %{"choices" => [], "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 5}}
    ])

    events = :ets.new(:events, [:public, :duplicate_bag])

    request = %{
      system: "Be brief.",
      messages: [Message.user("list files")],
      tools: [%{name: "shell", description: "Run", input_schema: %{"type" => "object"}}]
    }

    assert {:ok, response} = OpenRouter.stream(request, &:ets.insert(events, {:e, &1}))

    assert_receive {:request, "/api/v1/chat/completions", headers, body}
    assert {"authorization", "Bearer or-key"} in headers
    assert {"x-title", "Elia"} in headers

    assert %{
             "model" => "vendor/default",
             "stream" => true,
             "messages" => [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "list files"}
             ],
             "tools" => [
               %{
                 "type" => "function",
                 "function" => %{"name" => "shell", "parameters" => %{"type" => "object"}}
               }
             ]
           } = body

    refute Map.has_key?(body, "max_tokens")
    refute Map.has_key?(body, "reasoning")

    assert response.stop_reason == :tool_use
    assert response.model == "vendor/m"
    assert response.usage == %{"prompt_tokens" => 12, "completion_tokens" => 5}

    assert [
             %{
               type: :reasoning,
               text: "Let me think.",
               raw:
                 {OpenRouter,
                  %{
                    "reasoning_details" => [
                      %{"text" => "Let me think.", "signature" => "sig", "index" => 0}
                    ]
                  }}
             },
             %{type: :text, text: "Looking."},
             %{type: :tool_call, id: "call_1", name: "shell", input: %{"command" => "ls"}}
           ] = response.message.content

    emitted = for {:e, event} <- :ets.tab2list(events), do: event
    assert {:text_delta, "Look"} in emitted
    assert {:reasoning_delta, "think."} in emitted
    assert {:tool_call_started, %{id: "call_1", name: "shell"}} in emitted
  end

  # LLM-18
  test "sends max_tokens and reasoning effort only when set" do
    configure(OpenRouter, api_key: "k", max_tokens: 1000, effort: "high")
    stub_openrouter_stream(self(), [delta(%{"content" => "ok"}), finish("stop")])

    assert {:ok, %{stop_reason: :end_turn}} =
             OpenRouter.stream(%{messages: [Message.user("hi")], model: "x/y"}, fn _ -> :ok end)

    assert_receive {:request, _, _, body}
    assert %{"model" => "x/y", "max_tokens" => 1000, "reasoning" => %{"effort" => "high"}} = body
  end

  # LLM-19, LLM-21, LLM-6
  test "encodes history: tool calls, separate tool results, own reasoning only" do
    details = [%{"type" => "reasoning.encrypted", "data" => "abc"}]

    history = [
      Message.user("go"),
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: "", raw: {OpenRouter, %{"reasoning_details" => details}}},
          %{type: :reasoning, text: "other", raw: {Elia.LLM.Anthropic, %{"type" => "thinking"}}},
          %{type: :opaque, raw: {Elia.LLM.Anthropic, %{"type" => "fallback"}}},
          %{type: :tool_call, id: "c1", name: "shell", input: %{"command" => "ls"}},
          %{type: :tool_call, id: "c2", name: "read_file", input: %{"path" => "a"}}
        ]
      },
      %Message{
        role: :tool,
        content: [Message.tool_result("c1", "a\nb"), Message.tool_result("c2", "nope", true)]
      },
      Message.harness("tests failed"),
      %Message{role: :assistant, content: [Message.text("Done.")]}
    ]

    assert [
             %{"role" => "user", "content" => "go"},
             %{
               "role" => "assistant",
               "content" => nil,
               "reasoning_details" => ^details,
               "tool_calls" => [
                 %{
                   "id" => "c1",
                   "type" => "function",
                   "function" => %{"name" => "shell", "arguments" => ~s({"command":"ls"})}
                 },
                 %{"id" => "c2"}
               ]
             },
             %{"role" => "tool", "tool_call_id" => "c1", "content" => "a\nb"},
             %{"role" => "tool", "tool_call_id" => "c2", "content" => "Error: nope"},
             %{"role" => "user", "content" => "[Elia harness] tests failed"},
             %{"role" => "assistant", "content" => "Done."} = last
           ] = OpenRouter.encode_messages(history)

    refute Map.has_key?(last, "tool_calls")
  end

  # LLM-19
  test "text after tool results becomes a following user message" do
    message = %Message{
      role: :tool,
      content: [Message.tool_result("c1", "out"), Message.text("also this")]
    }

    assert [%{"role" => "tool"}, %{"role" => "user", "content" => "also this"}] =
             OpenRouter.encode_messages([message])
  end

  # LLM-22
  test "maps finish reasons" do
    for {reason, expected} <- [
          {"stop", :end_turn},
          {"tool_calls", :tool_use},
          {"length", :max_tokens},
          {"content_filter", :refusal},
          {"something_new", :other}
        ] do
      stub_openrouter_stream(self(), [delta(%{"content" => "x"}), finish(reason)])

      assert {:ok, %{stop_reason: ^expected}} =
               OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
    end
  end

  # LLM-22
  test "an error chunk or error finish reason fails the call" do
    stub_openrouter_stream(self(), [
      delta(%{"content" => "par"}),
      %{"error" => %{"code" => 502, "message" => "Provider disconnected"}}
    ])

    assert {:error, "OpenRouter stream error: Provider disconnected"} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    stub_openrouter_stream(self(), [finish("error")])

    assert {:error, "OpenRouter stream error"} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LLM-23
  test "retries transient statuses and reports API errors" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenRouter, fn conn ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"message" => "slow down"}})

        _ ->
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, "data: #{Jason.encode!(finish("stop"))}\n\n")
      end
    end)

    assert {:ok, %{stop_reason: :end_turn}} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert Agent.get(attempts, & &1) == 2

    Req.Test.stub(OpenRouter, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "model not found"}})
    end)

    assert {:error, "OpenRouter API error 400: model not found"} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LLM-24
  test "unparseable tool arguments become empty input with the raw text kept" do
    stub_openrouter_stream(self(), [
      delta(%{
        "tool_calls" => [
          %{"index" => 0, "id" => "c", "function" => %{"name" => "shell", "arguments" => "{bad"}}
        ]
      }),
      finish("tool_calls")
    ])

    assert {:ok, %{message: %{content: [call]}}} =
             OpenRouter.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert %{type: :tool_call, input: %{}, invalid_input: "{bad"} = call
  end

  defp stub_credits(credits_response, key_response \\ nil) do
    Req.Test.stub(OpenRouter, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer or-key"]

      case {conn.request_path, credits_response, key_response} do
        {"/api/v1/credits", {status, body}, _} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

        {"/api/v1/key", _, {status, body}} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  # LLM-25, LLM-26
  test "balance reads the account credits" do
    stub_credits({200, %{"data" => %{"total_credits" => 10, "total_usage" => 2.5}}})

    assert {:ok, %{scope: :account, total: 10.0, used: 2.5, remaining: 7.5}} =
             OpenRouter.balance("or-key")

    assert {:ok, %{scope: :account, remaining: 7.5}} = Elia.LLM.balance("openrouter")
  end

  # LLM-26
  test "balance falls back to the key's usage and limit without a management key" do
    stub_credits(
      {403, %{"error" => %{"message" => "management key required"}}},
      {200, %{"data" => %{"usage" => 1.25, "limit" => 5, "limit_remaining" => 3.75}}}
    )

    assert {:ok, %{scope: :key, used: 1.25, total: 5.0, remaining: 3.75}} =
             OpenRouter.balance("or-key")

    stub_credits(
      {401, %{}},
      {200, %{"data" => %{"usage" => 1, "limit" => nil, "limit_remaining" => nil}}}
    )

    assert {:ok, %{scope: :key, used: 1.0, total: nil, remaining: nil}} =
             OpenRouter.balance("or-key")
  end

  # LLM-26
  test "balance reports other failures" do
    stub_credits({500, %{"error" => %{"message" => "boom"}}})
    assert {:error, "OpenRouter API error 500: boom"} = OpenRouter.balance("or-key")

    stub_credits({403, %{}}, {401, %{"error" => %{"message" => "Invalid key"}}})
    assert {:error, "OpenRouter API error 401: Invalid key"} = OpenRouter.balance("or-key")
  end

  # LLM-25
  test "Elia.LLM.balance/1 handles missing keys and unsupported providers" do
    configure(OpenRouter)
    assert {:error, "No API key"} = Elia.LLM.balance("openrouter")
    assert Elia.LLM.balance("anthropic") == :unsupported
    assert Elia.LLM.balance("nope") == :unsupported
    assert Elia.LLM.balance_supported?("openrouter")
    refute Elia.LLM.balance_supported?("anthropic")
  end

  # LLM-27
  test "every provider has a billing URL" do
    assert Enum.all?(Elia.LLM.providers(), &String.starts_with?(&1.billing_url, "https://"))
  end
end
