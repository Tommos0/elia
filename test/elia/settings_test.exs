defmodule Elia.SettingsTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.{LLM, Settings}
  alias Elia.LLM.{Anthropic, OpenRouter}

  setup do
    reset_settings()
    configure(Anthropic)
    configure(OpenRouter)
    :ok
  end

  # CONF-1
  test "the database defaults to the XDG data directory" do
    previous = Application.get_env(:elia, Settings)
    xdg = System.get_env("XDG_DATA_HOME")

    on_exit(fn ->
      Application.put_env(:elia, Settings, previous)
      if xdg, do: System.put_env("XDG_DATA_HOME", xdg), else: System.delete_env("XDG_DATA_HOME")
    end)

    Application.delete_env(:elia, Settings)
    System.put_env("XDG_DATA_HOME", "/data/home")
    assert Settings.path() == "/data/home/elia/settings.dets"

    System.delete_env("XDG_DATA_HOME")
    assert Settings.path() == Path.join(System.user_home!(), ".local/share/elia/settings.dets")

    Application.put_env(:elia, Settings, path: "/custom/settings.dets")
    assert Settings.path() == "/custom/settings.dets"
  end

  # CONF-2, CONF-4
  test "the database is private and outside the workspace" do
    path = Settings.path()
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    refute String.starts_with?(path, Elia.Workspace.root() <> "/")
  end

  # CONF-3
  test "values survive a restart of the settings process" do
    :ok = Settings.put({:api_key, "openrouter"}, "sk-or-kept")

    :ok = Supervisor.terminate_child(Elia.Supervisor, Settings)
    {:ok, _pid} = Supervisor.restart_child(Elia.Supervisor, Settings)
    assert Settings.get({:api_key, "openrouter"}) == "sk-or-kept"
  end

  # CONF-5
  test "a stored key wins over a configured one" do
    assert LLM.api_key("openrouter") == nil

    configure(OpenRouter, api_key: "from-env")
    assert LLM.api_key("openrouter") == {:env, "from-env"}

    :ok = Settings.put({:api_key, "openrouter"}, "stored")
    assert LLM.api_key("openrouter") == {:stored, "stored"}
  end

  # CONF-6
  # LLM-16: a provider may implement `check_key/1` (CONF-6) — `list_models/1` and
  # `balance/1` are the other two — so checking a key asks the provider itself.
  test "checking a key asks the provider" do
    Req.Test.stub(OpenRouter, fn conn ->
      assert conn.request_path == "/api/v1/key"

      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer good"] ->
          Req.Test.json(conn, %{"data" => %{"label" => "mine"}})

        _ ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "No auth credentials found"}})
      end
    end)

    assert :ok = LLM.check_key("openrouter", "good")

    assert {:error, "OpenRouter API error 401: No auth credentials found"} =
             LLM.check_key("openrouter", "bad")

    Req.Test.stub(Anthropic, fn conn ->
      assert conn.request_path == "/v1/models"

      case Plug.Conn.get_req_header(conn, "x-api-key") do
        ["good"] ->
          Req.Test.json(conn, %{"data" => []})

        _ ->
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "invalid x-api-key"}})
      end
    end)

    assert :ok = LLM.check_key("anthropic", "good")

    assert {:error, "Anthropic API error 401: invalid x-api-key"} =
             LLM.check_key("anthropic", "x")
  end

  # CONF-6
  test "a blank key is rejected without a request" do
    Req.Test.stub(OpenRouter, fn _conn -> flunk("no request expected") end)
    assert {:error, "Enter an API key"} = LLM.check_key("openrouter", "   ")
    assert {:error, "Unknown provider"} = LLM.check_key("nope", "key")
  end

  # CONF-7, CONF-8
  test "saving stores only verified, trimmed keys; removing restores the configured key" do
    Req.Test.stub(OpenRouter, fn conn ->
      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer good"],
        do: Req.Test.json(conn, %{"data" => %{}}),
        else:
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => %{"message" => "no"}})
    end)

    configure(OpenRouter, api_key: "from-env")

    assert {:error, _} = LLM.save_key("openrouter", "bad")
    assert LLM.api_key("openrouter") == {:env, "from-env"}

    assert :ok = LLM.save_key("openrouter", "  good \n")
    assert LLM.api_key("openrouter") == {:stored, "good"}

    assert :ok = LLM.delete_key("openrouter")
    assert LLM.api_key("openrouter") == {:env, "from-env"}
  end
end
