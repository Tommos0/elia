defmodule EliaWeb.SettingsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase

  alias Elia.LLM
  alias Elia.LLM.{Anthropic, OpenRouter}

  setup do
    reset_settings()
    configure(Anthropic)
    configure(OpenRouter)

    # "good" is the only valid OpenRouter key.
    Req.Test.stub(OpenRouter, fn conn ->
      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer good-key-1234"],
        do: Req.Test.json(conn, %{"data" => %{}}),
        else:
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "Invalid key"}})
    end)

    :ok
  end

  defp submit(view, key, api_key, action) do
    view
    |> form("#key-form-#{key}", %{key => %{"api_key" => api_key}})
    |> render_submit(%{"action" => action})

    # Let the async check finish.
    render_async(view)
  end

  # CONF-9, CONF-12, CONF-13
  test "lists providers with their key status and the database location", %{conn: conn} do
    configure(Anthropic, api_key: "sk-ant-env-wxyz")
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-link")
    assert has_element?(view, "#provider-anthropic")
    assert has_element?(view, "#provider-openrouter")
    assert has_element?(view, "#key-status-anthropic", "From environment")
    assert has_element?(view, "#key-status-anthropic", "wxyz")
    refute render(view) =~ "sk-ant-env"
    assert has_element?(view, "#key-status-openrouter", "Not set")
    assert has_element?(view, "#settings-path", Elia.Settings.path())
  end

  # CONF-10
  test "Check verifies without storing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    submit(view, "openrouter", "bad", "check")
    assert has_element?(view, "#result-openrouter", "Invalid key")

    submit(view, "openrouter", "good-key-1234", "check")
    assert has_element?(view, "#result-openrouter", "Key is valid")
    assert LLM.api_key("openrouter") == nil
    assert has_element?(view, "#key-status-openrouter", "Not set")
  end

  # CONF-7, CONF-10, CONF-11, CONF-8
  test "Save stores a verified key, which can be checked and removed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    refute has_element?(view, "#check-current-openrouter")

    submit(view, "openrouter", "bad", "save")
    assert has_element?(view, "#result-openrouter", "Invalid key")
    assert LLM.api_key("openrouter") == nil

    submit(view, "openrouter", " good-key-1234 ", "save")
    assert has_element?(view, "#result-openrouter", "saved")
    assert LLM.api_key("openrouter") == {:stored, "good-key-1234"}
    assert has_element?(view, "#key-status-openrouter", "Saved")
    assert has_element?(view, "#key-status-openrouter", "1234")

    view |> element("#check-current-openrouter") |> render_click()
    render_async(view)
    assert has_element?(view, "#result-openrouter", "Key is valid")

    view |> element("#remove-openrouter") |> render_click()
    assert LLM.api_key("openrouter") == nil
    assert has_element?(view, "#key-status-openrouter", "Not set")
    refute has_element?(view, "#remove-openrouter")
  end
end
