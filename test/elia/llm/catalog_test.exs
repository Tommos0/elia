defmodule Elia.LLM.CatalogTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.LLM
  alias Elia.LLM.{Anthropic, OpenRouter}

  setup do
    reset_settings()
    configure(Anthropic, model: "claude-configured")
    configure(OpenRouter)
    :ok
  end

  defp openrouter_models do
    %{
      "data" => [
        %{
          "id" => "zeta/tools",
          "name" => "Zeta: Tools",
          "context_length" => 200_000,
          "pricing" => %{"prompt" => "0.000003", "completion" => "0.000015"},
          "supported_parameters" => ["tools", "tool_choice", "reasoning"]
        },
        %{
          "id" => "alpha/tools",
          "name" => "alpha: Tools",
          "pricing" => %{"prompt" => "-1", "completion" => "0"},
          "supported_parameters" => ["tools"]
        },
        %{"id" => "no/tools", "name" => "No Tools", "supported_parameters" => ["temperature"]},
        %{"id" => "no/params", "name" => "No Params"}
      ]
    }
  end

  # LLM-15
  test "registers Anthropic and OpenRouter" do
    assert [%{key: "anthropic", module: Anthropic}, %{key: "openrouter", module: OpenRouter}] =
             LLM.providers()
  end

  # MODEL-5, MODEL-7
  test "OpenRouter offers tool-capable models, sorted by name, without a key" do
    Req.Test.stub(OpenRouter, fn conn ->
      assert conn.request_path == "/api/v1/models"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, openrouter_models())
    end)

    assert {:ok, [alpha, zeta]} = LLM.models("openrouter")
    assert %{id: "alpha/tools", prompt_price: nil, completion_price: +0.0} = alpha

    assert %{id: "zeta/tools", name: "Zeta: Tools", context_length: 200_000} = zeta
    assert_in_delta zeta.prompt_price, 3.0, 1.0e-9
    assert_in_delta zeta.completion_price, 15.0, 1.0e-9
  end

  # MODEL-6
  test "Anthropic lists models with a key and falls back to the configured model" do
    assert {:ok, [%{id: "claude-configured"}]} = LLM.models("anthropic")
    LLM.Catalog.clear("anthropic")

    configure(Anthropic, api_key: "ak", model: "claude-configured")

    Req.Test.stub(Anthropic, fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["ak"]

      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "claude-a", "display_name" => "Claude A", "max_input_tokens" => 1000}
        ]
      })
    end)

    assert {:ok, [%{id: "claude-a", name: "Claude A", context_length: 1000}]} =
             LLM.models("anthropic")

    LLM.Catalog.clear("anthropic")
    Req.Test.stub(Anthropic, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:ok, [%{id: "claude-configured"}]} = LLM.models("anthropic")
  end

  # MODEL-14
  test "Anthropic models get prices from the built-in table and config" do
    configure(Anthropic, api_key: "ak", prices: %{"claude-custom" => {1.5, 7.5}})

    Req.Test.stub(Anthropic, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{"id" => "claude-opus-5-5", "display_name" => "Claude Opus 5.5"},
          %{"id" => "claude-haiku-4-5-20251001", "display_name" => "Claude Haiku 4.5"},
          %{"id" => "claude-custom", "display_name" => "Custom"},
          %{"id" => "claude-unknown", "display_name" => "Unknown"}
        ]
      })
    end)

    assert {:ok, [opus, haiku, custom, unknown]} = LLM.models("anthropic")
    assert %{prompt_price: 4.0, completion_price: 20.0} = opus
    assert %{prompt_price: 1.0, completion_price: 5.0} = haiku
    assert %{prompt_price: 1.5, completion_price: 7.5} = custom
    refute Map.has_key?(unknown, :prompt_price)
  end

  # CTX-7: context_window never fetches; it reads the cache or built-in fallbacks.
  test "context_window reads the catalog cache without fetching" do
    LLM.Catalog.clear("anthropic")
    assert LLM.Catalog.peek("anthropic") == :miss
    # No cache: Anthropic's built-in window applies.
    assert %{provider: "anthropic", context_length: 200_000} = LLM.context_window()

    # Populate the cache with a model of the selected id.
    configure(Anthropic, api_key: "ak", model: "claude-a")

    Req.Test.stub(Anthropic, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"id" => "claude-a", "name" => "Claude A", "max_input_tokens" => 1000}]
      })
    end)

    assert {:ok, [%{id: "claude-a", context_length: 1000}]} = LLM.models("anthropic")
    assert {:ok, [%{id: "claude-a", context_length: 1000}]} = LLM.Catalog.peek("anthropic")

    assert %{provider: "anthropic", model: "claude-a", context_length: 1000} =
             LLM.context_window()

    # A cached model without a reported window falls back to the default.
    configure(Anthropic, api_key: "ak", model: "claude-plain")

    Req.Test.stub(Anthropic, fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "claude-plain", "name" => "Plain"}]})
    end)

    assert {:ok, [_]} = LLM.models("anthropic")
    assert %{context_length: 200_000} = LLM.context_window()
  end

  # CTX-7: reading the window never waits on a catalog fetch in flight.
  test "context_window does not block while a fetch is in flight" do
    test_pid = self()
    configure(Anthropic, api_key: "ak", model: "claude-a")

    Req.Test.stub(Anthropic, fn conn ->
      send(test_pid, {:fetching, self()})

      receive do
        :go -> Req.Test.json(conn, %{"data" => []})
      end
    end)

    task = Task.async(fn -> LLM.models("anthropic") end)
    assert_receive {:fetching, fetcher}

    assert %{context_length: 200_000} = LLM.context_window()

    send(fetcher, :go)
    assert {:ok, _models} = Task.await(task)
  end

  # MODEL-1, CTX-7: selecting a model stores its cached context length, which
  # keeps the window known after the catalog cache is gone.
  test "selection stores the cached context length for after the cache expires" do
    Req.Test.stub(OpenRouter, &Req.Test.json(&1, openrouter_models()))
    assert {:ok, _} = LLM.models("openrouter")

    {:ok, _} = LLM.select("openrouter", "zeta/tools", "Zeta: Tools")
    assert %{context_length: 200_000} = LLM.selection()

    LLM.Catalog.clear("openrouter")
    assert %{provider: "openrouter", context_length: 200_000} = LLM.context_window()
  end

  # CTX-7: a selection stored without a length picks it up from the catalog.
  test "context_window saves a cached length the stored selection lacks" do
    {:ok, _} = LLM.select("openrouter", "zeta/tools", "Zeta: Tools")
    refute Map.has_key?(LLM.selection(), :context_length)

    Req.Test.stub(OpenRouter, &Req.Test.json(&1, openrouter_models()))
    assert {:ok, _} = LLM.models("openrouter")
    assert %{context_length: 200_000} = LLM.context_window()

    LLM.Catalog.clear("openrouter")
    assert %{context_length: 200_000} = LLM.selection()
    assert %{context_length: 200_000} = LLM.context_window()
  end

  # CTX-7, MODEL-2: the configured default is never turned into a stored selection.
  test "context_window leaves an unstored default selection alone" do
    Req.Test.stub(Anthropic, fn conn ->
      Req.Test.json(conn, %{
        "data" => [%{"id" => "claude-configured", "max_input_tokens" => 1000}]
      })
    end)

    configure(Anthropic, api_key: "ak", model: "claude-configured")
    assert {:ok, _} = LLM.models("anthropic")
    assert %{context_length: 1000} = LLM.context_window()
    assert Elia.Settings.get(:model) == nil
  end

  # CTX-7: non-Anthropic providers have no built-in fallback window.
  test "context_window is nil for a provider without a cached window" do
    LLM.select("openrouter", "vendor/model", "Vendor: Model")
    assert %{provider: "openrouter", context_length: nil} = LLM.context_window()
  end

  # MODEL-8
  test "results are cached, failures are not, and saving a key clears the cache" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(OpenRouter, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> Plug.Conn.send_resp(conn, 503, "down")
        _ -> Req.Test.json(conn, openrouter_models())
      end
    end)

    assert {:error, "OpenRouter API error 503: down"} = LLM.models("openrouter")
    assert {:ok, [_, _]} = LLM.models("openrouter")
    assert {:ok, [_, _]} = LLM.models("openrouter")
    assert Agent.get(calls, & &1) == 2

    :ok = LLM.delete_key("openrouter")
    assert {:ok, [_, _]} = LLM.models("openrouter")
    assert Agent.get(calls, & &1) == 3
  end

  # MODEL-1, MODEL-2, MODEL-4
  test "selection defaults to the configured provider and persists choices" do
    # Tests configure Elia.FakeLLM, which isn't registered: Anthropic is the fallback.
    assert %{provider: "anthropic", model: "claude-configured"} = LLM.selection()
    assert LLM.selection_request() == %{}

    assert {:ok, %{provider: "openrouter", model: "vendor/model"}} =
             LLM.select("openrouter", "vendor/model", "Vendor: Model")

    assert %{provider: "openrouter", model: "vendor/model", name: "Vendor: Model"} =
             LLM.selection()

    assert LLM.selection_request() == %{provider: OpenRouter, model: "vendor/model"}

    assert {:error, _} = LLM.select("nope", "x")
    assert {:error, _} = LLM.select("openrouter", " ")
    assert %{model: "vendor/model"} = LLM.selection()
  end
end
