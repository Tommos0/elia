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

  # Valid key, with a credits endpoint that reports $7.50 of $10 left.
  defp stub_balance(credits) do
    Req.Test.stub(OpenRouter, fn conn ->
      case conn.request_path do
        "/api/v1/credits" -> credits.(conn)
        _ -> Req.Test.json(conn, %{"data" => %{}})
      end
    end)
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

  # CONF-15
  test "every card links to the provider's billing page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    for info <- LLM.providers() do
      assert has_element?(view, ~s|a#topup-#{info.key}[href="#{info.billing_url}"]|)
      assert has_element?(view, ~s|a#topup-#{info.key}[target="_blank"][rel~="noopener"]|)
    end

    refute has_element?(view, "#refresh-balance-openrouter")
    assert has_element?(view, "#balance-openrouter", "Add a key")
  end

  # CONF-14, CONF-16
  test "shows the OpenRouter account balance and can refresh it", %{conn: conn} do
    configure(OpenRouter, api_key: "sk-or-env-1234")
    {:ok, agent} = Agent.start_link(fn -> 2.5 end)

    stub_balance(fn conn ->
      used = Agent.get(agent, & &1)
      Req.Test.json(conn, %{"data" => %{"total_credits" => 10, "total_usage" => used}})
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    render_async(view)
    assert has_element?(view, "#balance-openrouter", "$7.50 remaining ($2.50 used of $10.00)")

    Agent.update(agent, fn _ -> 4 end)
    view |> element("#refresh-balance-openrouter") |> render_click()
    render_async(view)
    assert has_element?(view, "#balance-openrouter", "$6.00 remaining")
  end

  # CONF-14
  test "shows a key's usage and limit, and errors", %{conn: conn} do
    configure(OpenRouter, api_key: "sk-or-env-1234")

    Req.Test.stub(OpenRouter, fn conn ->
      case conn.request_path do
        "/api/v1/credits" ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{})

        "/api/v1/key" ->
          Req.Test.json(conn, %{
            "data" => %{"usage" => 1.5, "limit" => 5, "limit_remaining" => 3.5}
          })
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    render_async(view)
    assert has_element?(view, "#balance-openrouter", "$1.50 used · $3.50 left of $5.00 key limit")

    stub_balance(fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
    end)

    view |> element("#refresh-balance-openrouter") |> render_click()
    render_async(view)
    assert has_element?(view, "#balance-openrouter", "Couldn't load credits")
    assert has_element?(view, "#balance-openrouter", "boom")
  end

  # CONF-17, CONF-18
  test "the theme toggle is on the settings page, not in the header", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#appearance #theme-toggle button[data-phx-theme=dark]")
    assert view |> element("#appearance #theme-toggle") |> render() =~ "data-phx-theme"
    assert length(Regex.scan(~r/id="theme-toggle"/, render(view))) == 1

    {:ok, files, _html} = live(conn, ~p"/files")
    refute has_element?(files, "#theme-toggle")
  end

  # CONF-14
  test "a provider without a balance API says so", %{conn: conn} do
    configure(Anthropic, api_key: "sk-ant-env-wxyz")
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#balance-anthropic", "isn't available through the API")
    refute has_element?(view, "#refresh-balance-anthropic")
  end

  # CONF-14
  test "saving a key loads its balance", %{conn: conn} do
    stub_balance(fn conn ->
      Req.Test.json(conn, %{"data" => %{"total_credits" => 3, "total_usage" => 1}})
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    submit(view, "openrouter", "good-key-1234", "save")
    render_async(view)
    assert has_element?(view, "#balance-openrouter", "$2.00 remaining")
  end
end
