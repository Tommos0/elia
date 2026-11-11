defmodule Elia.LLM.LlamaCppTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM
  alias Elia.LLM.{Error, LlamaCpp, Message}

  setup do
    reset_settings()
    configure(LlamaCpp, model: "configured/model")
    :ok
  end

  defp delta(delta, extra \\ %{}) do
    Map.merge(%{"model" => "stub-model", "choices" => [%{"index" => 0, "delta" => delta}]}, extra)
  end

  defp finish(reason), do: %{"choices" => [%{"delta" => %{}, "finish_reason" => reason}]}

  # LOCAL-1, LOCAL-2, LOCAL-9
  test "needs no key and streams a neutral message" do
    stub_openai_stream(LlamaCpp, self(), [
      delta(%{"role" => "assistant", "content" => "Hel"}),
      delta(%{"content" => "lo."}),
      finish("stop")
    ])

    request = %{
      system: "Be brief.",
      messages: [Message.user("hi")],
      tools: [%{name: "shell", description: "Run", input_schema: %{"type" => "object"}}]
    }

    events = :ets.new(:events, [:public, :duplicate_bag])
    assert {:ok, response} = LlamaCpp.stream(request, &:ets.insert(events, {:e, &1}))

    assert_receive {:request, "/v1/chat/completions", headers, body}
    refute Enum.any?(headers, fn {name, _value} -> name == "authorization" end)

    assert %{
             "model" => "configured/model",
             "stream" => true,
             "messages" => [
               %{"role" => "system", "content" => "Be brief."},
               %{"role" => "user", "content" => "hi"}
             ],
             "tools" => [%{"type" => "function", "function" => %{"name" => "shell"}}]
           } = body

    assert response.stop_reason == :end_turn
    assert response.model == "stub-model"
    assert response.message.content == [%{type: :text, text: "Hello."}]

    events = :ets.tab2list(events) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert events == [{:text_delta, "Hel"}, {:text_delta, "lo."}]
  end

  # LOCAL-2: a key is sent only when one is set, for a server started with its
  # own --api-key.
  test "sends a bearer token only when a key is configured" do
    configure(LlamaCpp, api_key: "local-secret")
    stub_openai_stream(LlamaCpp, self(), [delta(%{"content" => "ok"}), finish("stop")])

    assert {:ok, _response} = LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
    assert_receive {:request, "/v1/chat/completions", headers, _body}
    assert {"authorization", "Bearer local-secret"} in headers
  end

  # LOCAL-3
  test "a base URL saved in Settings is the one it talks to" do
    configure(LlamaCpp, base_url: "http://127.0.0.1:9999")
    test = self()

    Req.Test.stub(LlamaCpp, fn conn ->
      send(test, {:reached, conn.host, conn.port})
      Req.Test.json(conn, %{"data" => [%{"id" => "stub-model"}]})
    end)

    assert LlamaCpp.base_url() == "http://127.0.0.1:9999"
    assert {:ok, [%{id: "stub-model"}]} = LlamaCpp.list_models(nil)
    assert_receive {:reached, "127.0.0.1", 9999}

    :ok = Elia.Settings.put({:base_url, "llamacpp"}, "http://127.0.0.1:8080/")
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"
    assert {:ok, _models} = LlamaCpp.list_models(nil)
    assert_receive {:reached, "127.0.0.1", 8080}
  end

  # LOCAL-3: the configuration, and then the default.
  test "the configured base URL, and the default without one" do
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"
    configure(LlamaCpp, base_url: "http://127.0.0.1:1234/")
    assert LlamaCpp.base_url() == "http://127.0.0.1:1234"
  end

  # LOCAL-4
  test "lists the server's models with the context length it reports" do
    Req.Test.stub(LlamaCpp, fn conn ->
      case conn.request_path do
        "/v1/models" -> Req.Test.json(conn, %{"data" => [%{"id" => "stub-model"}]})
        "/props" -> Req.Test.json(conn, stub_props())
      end
    end)

    assert {:ok, [model]} = LlamaCpp.list_models(nil)
    assert model.id == "stub-model"
    assert model.name == "stub.gguf"
    assert model.context_length == 4096
    refute Map.has_key?(model, :prompt_price)
  end

  # LOCAL-4: several models, where the loaded file's name belongs to none of them.
  test "lists several models by id, without one file name" do
    Req.Test.stub(LlamaCpp, fn conn ->
      case conn.request_path do
        "/v1/models" ->
          Req.Test.json(conn, %{"data" => [%{"id" => "one"}, %{"id" => "two"}]})

        "/props" ->
          Req.Test.json(conn, stub_props())
      end
    end)

    assert {:ok, [one, two]} = LlamaCpp.list_models(nil)
    assert [one.id, one.name, two.id, two.name] == ["one", "one", "two", "two"]
  end

  # LOCAL-5: a server that isn't up yet is not an error in the picker — the
  # configured model is offered on its own.
  test "offers the configured model when the server does not answer" do
    Req.Test.stub(LlamaCpp, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:ok, [%{id: "configured/model", context_length: nil}]} = LlamaCpp.list_models(nil)
  end

  # LOCAL-6
  test "the default model is the configured one, else the server's, else local" do
    assert LlamaCpp.default_model() == "configured/model"

    configure(LlamaCpp)

    Req.Test.stub(LlamaCpp, fn conn -> Req.Test.json(conn, %{"data" => [%{"id" => "loaded"}]}) end)

    assert LlamaCpp.default_model() == "loaded"

    Req.Test.stub(LlamaCpp, fn conn -> Plug.Conn.send_resp(conn, 503, "no") end)
    assert LlamaCpp.default_model() == "local"
  end

  # LOCAL-7, CONF-5: nothing to bill and no credits to look up.
  test "reports no balance" do
    refute LLM.balance_supported?("llamacpp")
    assert LLM.balance("llamacpp") == :unsupported
    assert LLM.provider_info("llamacpp").billing_url == nil
  end

  # LOCAL-8: a connection a server that is still coming up refuses is retried,
  # and the message names the fix.
  test "a refused connection is retried and names the fix" do
    configure(LlamaCpp)
    attempts = :counters.new(1, [])

    Req.Test.stub(LlamaCpp, fn conn ->
      :counters.add(attempts, 1, 1)
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error,
            %Error{
              transient: true,
              message: "No llama.cpp server at http://127.0.0.1:8080: start one in Settings"
            }} = LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert :counters.get(attempts, 1) > 1
  end

  # LOCAL-8: another transport failure is not blamed on a missing server.
  test "another transport failure keeps the provider's wording" do
    configure(LlamaCpp)
    Req.Test.stub(LlamaCpp, fn conn -> Req.Test.transport_error(conn, :closed) end)

    assert {:error,
            %Error{
              transient: true,
              message: "llama.cpp server API request failed: socket closed"
            }} = LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  # LOCAL-9: tool calls stream the same way as OpenRouter's, without its
  # reasoning details.
  test "streams tool calls, and does not send reasoning details back" do
    stub_openai_stream(LlamaCpp, self(), [
      delta(%{"reasoning" => "Let me think."}),
      delta(%{"content" => "Listing."}),
      delta(%{
        "tool_calls" => [
          %{
            "index" => 0,
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "shell", "arguments" => "{\"command\":"}
          }
        ]
      }),
      delta(%{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\"ls\"}"}}]}),
      finish("tool_calls")
    ])

    request = %{messages: [Message.user("list files")]}
    assert {:ok, response} = LlamaCpp.stream(request, fn _ -> :ok end)
    assert_receive {:request, "/v1/chat/completions", _headers, _body}

    assert [
             %{type: :reasoning, text: "Let me think."},
             %{type: :text, text: "Listing."},
             %{type: :tool_call, id: "call_1", name: "shell", input: %{"command" => "ls"}}
           ] = response.message.content

    assert response.stop_reason == :tool_use

    history = [
      %Message{
        role: :assistant,
        content: [
          %{
            type: :reasoning,
            text: "Let me think.",
            raw: {Elia.LLM.OpenRouter, %{"reasoning_details" => [%{"index" => 0}]}}
          },
          Message.text("Listing.")
        ]
      }
    ]

    # LOCAL-9: no reasoning details go back, and the reasoning text is not a
    # message of its own; OpenRouter sends both (LLM-21).
    assert [%{"role" => "assistant", "content" => "Listing."}] = LlamaCpp.encode_messages(history)

    assert [%{"role" => "assistant", "reasoning_details" => [%{"index" => 0}]}] =
             Elia.LLM.OpenRouter.encode_messages(history)
  end

  # LOCAL-9: an unparsable tool call is kept, as it is for OpenRouter.
  test "keeps a tool call whose arguments are not JSON" do
    stub_openai_stream(LlamaCpp, self(), [
      delta(%{
        "tool_calls" => [
          %{
            "index" => 0,
            "id" => "call_1",
            "function" => %{"name" => "shell", "arguments" => "{not json"}
          }
        ]
      }),
      finish("tool_calls")
    ])

    assert {:ok, response} = LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

    assert [
             %{
               type: :tool_call,
               id: "call_1",
               name: "shell",
               input: %{},
               invalid_input: "{not json"
             }
           ] =
             response.message.content
  end

  # LOCAL-9, LLM-36: the code the server names decides whether a retry may help.
  test "a stream error names the service and its code" do
    stub_openai_stream(LlamaCpp, self(), [
      %{"error" => %{"message" => "model is loading", "code" => 503}}
    ])

    assert {:error,
            %Error{transient: true, message: "llama.cpp server stream error: model is loading"}} =
             LlamaCpp.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)
  end

  defp stub_props do
    %{
      "model_path" => "/models/stub.gguf",
      "default_generation_settings" => %{"n_ctx" => 4096}
    }
  end
end
