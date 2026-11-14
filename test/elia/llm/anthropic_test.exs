defmodule Elia.LLM.AnthropicTest do
  use ExUnit.Case, async: false

  alias Elia.LLM.{Anthropic, Error, Message}

  setup do
    previous = Application.get_env(:elia, Anthropic)

    Application.put_env(:elia, Anthropic,
      api_key: "test-key",
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:elia, Anthropic, previous) end)
  end

  defp sse(events) do
    Enum.map_join(events, fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  defp stub_stream(test_pid, events) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.req_headers, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events))
    end)
  end

  # LLM-2, LLM-3, LLM-4, LLM-5: the request a provider is handed (its messages,
  # system, tools and model), the streaming events it emits, the stop reason it
  # answers with and the neutral message it builds.
  test "streams text, thinking and tool calls into a neutral message" do
    thinking = %{"type" => "thinking", "thinking" => "", "signature" => ""}

    stub_stream(self(), [
      %{
        "type" => "message_start",
        "message" => %{"model" => "claude-opus-5-5", "usage" => %{"input_tokens" => 10}}
      },
      %{"type" => "content_block_start", "index" => 0, "content_block" => thinking},
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Checking files."}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "signature_delta", "signature" => "sig"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "Let me "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 1,
        "delta" => %{"type" => "text_delta", "text" => "look."}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "shell",
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"command\": "}
      },
      %{
        "type" => "content_block_delta",
        "index" => 2,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "\"ls\"}"}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "tool_use"},
        "usage" => %{"output_tokens" => 20}
      },
      %{"type" => "message_stop"}
    ])

    test_pid = self()
    request = %{system: "sys", messages: [Message.user("hi")], tools: Elia.Skills.Shell.tools()}

    assert {:ok, response} = Anthropic.stream(request, &send(test_pid, {:event, &1}))

    assert response.stop_reason == :tool_use
    assert response.usage == %{"input_tokens" => 10, "output_tokens" => 20}

    assert [
             %{type: :reasoning, text: "Checking files."},
             %{type: :text, text: "Let me look."},
             %{type: :tool_call, id: "toolu_1", name: "shell", input: %{"command" => "ls"}}
           ] = response.message.content

    assert_received {:event, {:text_delta, "Let me "}}
    assert_received {:event, {:tool_call_started, %{id: "toolu_1", name: "shell"}}}

    assert_received {:request, headers, body}
    assert {"anthropic-version", "2026-10-21"} in headers
    assert {"x-api-key", "test-key"} in headers

    # LLM-28
    assert {"anthropic-beta",
            "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18," <>
              "thinking-binding-controls-2026-08-01"} in headers

    assert body["model"] == "claude-opus-5-5"
    assert body["stream"] == true
    assert body["fallbacks"] == "default"

    assert body["thinking"] == %{
             "type" => "adaptive",
             "display" => "updates",
             "block_binding" => %{"prefix_mismatch_behavior" => "drop_block"}
           }

    assert [%{"name" => "shell", "input_schema" => %{"required" => ["command"]}}] = body["tools"]

    # Our own blocks are echoed back exactly as received.
    history = [
      Message.user("hi"),
      response.message,
      %Message{role: :tool, content: [Message.tool_result("toolu_1", "a\nb")]}
    ]

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [echoed_thinking, _text, tool_use]},
             %{
               "role" => "user",
               "content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_1"}]
             }
           ] = Anthropic.encode_messages(history)

    assert echoed_thinking == %{
             "type" => "thinking",
             "thinking" => "Checking files.",
             "signature" => "sig"
           }

    assert tool_use == %{
             "type" => "tool_use",
             "id" => "toolu_1",
             "name" => "shell",
             "input" => %{"command" => "ls"}
           }
  end

  # LLM-29
  test "the shipped config asks for summarized thinking" do
    shipped = Config.Reader.read!("config/config.exs", env: :test)[:elia][Anthropic]
    assert shipped[:thinking_display] == "summarized"

    body =
      Anthropic.build_body(%{messages: [Message.user("hi")]}, thinking_display: "summarized")

    assert body["thinking"]["display"] == "summarized"
  end

  # LLM-38
  test "the shipped config asks for medium reasoning effort" do
    shipped = Config.Reader.read!("config/config.exs", env: :test)[:elia][Anthropic]
    assert shipped[:effort] == "medium"

    body = Anthropic.build_body(%{messages: [Message.user("hi")]}, effort: "medium")
    assert body["output_config"] == %{"effort" => "medium"}
  end

  # LLM-39: a request may name its own effort (a chat's setting, SESS-40), and it
  # wins over the configured one.
  test "a request's own effort overrides the configured one" do
    body =
      Anthropic.build_body(%{messages: [Message.user("hi")], effort: "low"}, effort: "high")

    assert body["output_config"] == %{"effort" => "low"}
  end

  # LLM-9: a tool result and the user message after it are merged into one user
  # turn, and what the provider can't use is dropped rather than sent.
  test "drops reasoning from other providers and merges consecutive user turns" do
    history = [
      Message.user("one"),
      %Message{
        role: :assistant,
        content: [%{type: :reasoning, text: "x", raw: {OtherProvider, %{}}}, Message.text("ok")]
      },
      %Message{role: :tool, content: [Message.tool_result("t1", "out")]},
      Message.user("two")
    ]

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "ok"}]},
             %{
               "role" => "user",
               "content" => [%{"type" => "tool_result"}, %{"type" => "text", "text" => "two"}]
             }
           ] = Anthropic.encode_messages(history)
  end

  test "maps refusals and API errors" do
    stub_stream(self(), [
      %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "refusal"}}
    ])

    assert {:ok, %{stop_reason: :refusal, message: %{content: []}}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(Plug.Conn.put_status(conn, 400), %{"error" => %{"message" => "bad request"}})
    end)

    assert {:error, "Anthropic API error 400: bad request"} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LLM-11: tool input that isn't valid JSON becomes empty input, with the raw
  # text kept in `invalid_input` (LOOP-6).
  test "unparsable tool input becomes empty input, keeping the raw text" do
    stub_stream(self(), [
      %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "shell"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{bad"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}}
    ])

    assert {:ok, %{message: message}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert [%{type: :tool_call, input: %{}, invalid_input: "{bad"}] = message.content
  end

  # LLM-12: a `fallback` block emits a notice, and the declined model's thinking
  # and tool calls before the last of them are dropped.
  test "a fallback block emits a notice and drops the declined part" do
    stub_stream(self(), [
      %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => "Declined."}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "content_block_start",
        "index" => 1,
        "content_block" => %{"type" => "fallback"}
      },
      %{"type" => "content_block_stop", "index" => 1},
      %{
        "type" => "content_block_start",
        "index" => 2,
        "content_block" => %{"type" => "text", "text" => "Fine."}
      },
      %{"type" => "content_block_stop", "index" => 2},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
    ])

    test_pid = self()

    assert {:ok, %{message: message}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, &send(test_pid, {:event, &1}))

    assert_received {:event, {:notice, "Request was rerouted to a fallback model"}}

    refute Enum.any?(message.content, &(&1.type == :reasoning))
    assert Enum.any?(message.content, &(&1.type == :text and &1.text == "Fine."))
  end

  # LLM-14: the API's stop reasons, mapped to the neutral ones.
  test "maps the API's stop reasons" do
    reasons = [
      {"end_turn", :end_turn},
      {"stop_sequence", :end_turn},
      {"tool_use", :tool_use},
      {"max_tokens", :max_tokens},
      {"model_context_window_exceeded", :max_tokens},
      {"refusal", :refusal},
      {"something_else", :other}
    ]

    for {api, neutral} <- reasons do
      stub_stream(self(), [
        %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => api}}
      ])

      assert {:ok, %{stop_reason: ^neutral}} =
               Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
    end
  end

  # LLM-30
  test "retries on a fresh connection when the pooled one was closed" do
    counter = :counters.new(1, [])
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        Req.Test.transport_error(conn, :closed)
      else
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, :second_request)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          sse([
            %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
            %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
          ])
        )
      end
    end)

    assert {:ok, %{stop_reason: :end_turn}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert_received :second_request
    assert :counters.get(counter, 1) == 2
  end

  # LLM-30, LLM-36: a closed connection is a transport failure, so the turn's
  # own retry may pick it up where the provider's leaves it.
  test "gives up after two retries of a closed connection" do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error,
            %Error{transient: true, message: "Anthropic API request failed: socket closed"}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert :counters.get(counter, 1) == 3
  end

  # LLM-30
  test "other transport errors aren't retried" do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %Error{transient: true, message: "Anthropic API request failed: " <> _}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert :counters.get(counter, 1) == 1
  end

  # LLM-35
  test "retries a stalled stream that received nothing, then gives up after two retries" do
    counter = :counters.new(1, [])
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        Req.Test.transport_error(conn, :timeout)
      else
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, :second_request)

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          sse([
            %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
            %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
          ])
        )
      end
    end)

    assert {:ok, %{stop_reason: :end_turn}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert_received :second_request
    assert :counters.get(counter, 1) == 2

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Error{transient: true, message: "Anthropic API request failed: timeout"}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert :counters.get(counter, 1) == 5
  end

  # LLM-36: which failures a turn's retry may fix, and which it must not.
  test "marks the failures a retry may fix" do
    stub_stream(self(), [
      %{"type" => "error", "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}}
    ])

    assert {:error, %Error{transient: true, message: "Anthropic stream error: Overloaded"}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    stub_stream(self(), [
      %{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "messages: bad"}
      }
    ])

    assert {:error, "Anthropic stream error: messages: bad"} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    # A status the provider itself retries, outlasting its two retries, is
    # marked the same way.
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.put_status(529)
      |> Req.Test.json(%{"error" => %{"message" => "overloaded"}})
    end)

    assert {:error, %Error{transient: true, message: "Anthropic API error 529: overloaded"}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert :counters.get(counter, 1) == 3

    # A 4xx is the request's fault, so it is a plain message (LLM-10).
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"error" => %{"message" => "no such model"}})
    end)

    assert {:error, "Anthropic API error 422: no such model"} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LLM-31
  test "Anthropic GET requests retry on a closed connection" do
    counter = :counters.new(1, [])

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)

      if :counters.get(counter, 1) == 1 do
        Req.Test.transport_error(conn, :closed)
      else
        Req.Test.json(conn, %{"data" => []})
      end
    end)

    assert :ok = Anthropic.check_key("test-key")
    assert :counters.get(counter, 1) == 2

    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(counter, 1, 1)
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error, "Anthropic API request failed: socket closed"} =
             Anthropic.check_key("test-key")

    assert :counters.get(counter, 1) == 5
  end

  # LLM-7, CONF-5
  test "without a key, returns an error and makes no request; a stored key is used" do
    Application.put_env(:elia, Anthropic, req_options: [plug: {Req.Test, __MODULE__}])
    Elia.Settings.delete({:api_key, "anthropic"})
    Req.Test.stub(__MODULE__, fn _conn -> flunk("no request expected") end)

    assert {:error, "No Anthropic API key: add one in Settings or set ANTHROPIC_API_KEY"} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    :ok = Elia.Settings.put({:api_key, "anthropic"}, "stored-key")
    on_exit(fn -> Elia.Settings.delete({:api_key, "anthropic"}) end)

    stub_stream(self(), [
      %{"type" => "message_start", "message" => %{"model" => "claude-opus-5-5"}},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
    ])

    assert {:ok, %{stop_reason: :end_turn}} =
             Anthropic.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert_receive {:request, headers, _body}
    assert {"x-api-key", "stored-key"} in headers
  end
end
