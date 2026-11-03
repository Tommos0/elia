defmodule EliaWeb.ModelPickerTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase

  alias Elia.{Agent, LLM, Settings}
  alias Elia.LLM.{Anthropic, OpenRouter}
  alias EliaWeb.ChatSettingsLive

  setup do
    reset_settings()
    configure(Anthropic, model: "claude-configured")
    configure(OpenRouter)

    Req.Test.stub(OpenRouter, fn conn ->
      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "openai/gpt-x",
            "name" => "OpenAI: GPT X",
            "context_length" => 400_000,
            "pricing" => %{"prompt" => "0.00000125", "completion" => "0.00001"},
            "supported_parameters" => ["tools"]
          },
          %{
            "id" => "google/gemini-y",
            "name" => "Google: Gemini Y",
            "supported_parameters" => ["tools"]
          }
        ]
      })
    end)

    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    %{id: id}
  end

  defp open_picker(view) do
    view |> element("#model-picker-button") |> render_click()
    render_async(view)
  end

  # MODEL-9, MODEL-13
  test "shows the selection and links to settings for providers without a key", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
    assert has_element?(view, "#selected-model", "claude-configured")
    assert has_element?(view, "#selected-provider[data-provider=anthropic]", "Anthropic")
    refute has_element?(view, "#model-picker")

    open_picker(view)
    assert has_element?(view, "#model-picker")
    assert has_element?(view, "#group-anthropic [data-provider=anthropic]")
    assert has_element?(view, "#group-openrouter [data-provider=openrouter]")
    assert has_element?(view, "#add-key-anthropic[href='/settings']")
    assert has_element?(view, "#add-key-openrouter[href='/settings']")
  end

  # MODEL-10, MODEL-12
  test "searching filters models and clicking one selects it", %{conn: conn, id: id} do
    :ok = Settings.put({:api_key, "openrouter"}, "or-key")
    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
    open_picker(view)

    gpt = "#" <> ChatSettingsLive.model_dom_id("openrouter", "openai/gpt-x")
    gemini = "#" <> ChatSettingsLive.model_dom_id("openrouter", "google/gemini-y")
    assert has_element?(view, gpt, "400K ctx")
    assert has_element?(view, "#{gpt} [data-provider=openrouter]", "OpenRouter")
    assert has_element?(view, gemini)

    view |> form("#model-search-form", model_search: %{q: "GEMINI"}) |> render_change()
    assert has_element?(view, gemini)
    refute has_element?(view, gpt)

    view |> form("#model-search-form", model_search: %{q: "openai/"}) |> render_change()
    assert has_element?(view, gpt)
    refute has_element?(view, gemini)

    view |> element("#{gpt} button") |> render_click()
    refute has_element?(view, "#model-picker")
    assert has_element?(view, "#selected-model", "OpenAI: GPT X")
    assert has_element?(view, "#selected-provider[data-provider=openrouter]")
    # MODEL-1, MODEL-15: stored on the chat, and remembered as the default.
    assert %{provider: "openrouter", model: "openai/gpt-x"} = Agent.snapshot(id).selection
    assert %{provider: "openrouter", model: "openai/gpt-x"} = LLM.selection()

    # The selected model is marked when the picker reopens.
    open_picker(view)
    assert has_element?(view, "#{gpt} button[aria-selected=true]")
    assert has_element?(view, "#{gemini} button[aria-selected=false]")
  end

  # MODEL-11
  test "a failed catalog load shows the error", %{conn: conn, id: id} do
    :ok = Settings.put({:api_key, "openrouter"}, "or-key")
    Req.Test.stub(OpenRouter, fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
    open_picker(view)
    assert has_element?(view, "#catalog-error-openrouter", "bad gateway")
  end

  # MODEL-12
  test "closing the picker keeps the selection", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
    open_picker(view)

    render_hook(view, "close_picker", %{})
    refute has_element?(view, "#model-picker")
    assert %{model: "claude-configured"} = LLM.selection()
  end

  # MODEL-1, SESS-14
  test "a selection made in another tab of the chat updates it", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
    {:ok, _} = Agent.select_model(id, "openrouter", "vendor/model", "Vendor Model")
    assert render(view) =~ "Vendor Model"
    assert has_element?(view, "#selected-model", "Vendor Model")
  end

  # MODEL-1, MODEL-15
  test "the model is chat-local; new chats start on the last choice", %{conn: conn, id: id} do
    other = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(other) end)

    {:ok, view_a, _} = live(conn, ~p"/c/#{id}/settings")
    {:ok, view_b, _} = live(conn, ~p"/c/#{other}/settings")
    {:ok, _} = Agent.select_model(id, "openrouter", "vendor/model", "Vendor Model")
    {:ok, _} = Agent.select_model(other, "anthropic", "claude-other", "Claude Other")

    assert has_element?(view_a, "#selected-model", "Vendor Model")
    assert has_element?(view_b, "#selected-model", "Claude Other")

    # Reopening a chat shows its own model, not the last choice made anywhere.
    {:ok, reopened, _} = live(conn, ~p"/c/#{id}/settings")
    assert has_element?(reopened, "#selected-model", "Vendor Model")

    # A chat that never chose one starts on the last choice.
    {:ok, fresh, _} = live(conn, ~p"/c/#{Agent.new_id()}/settings")
    assert has_element?(fresh, "#selected-model", "Claude Other")
  end
end
