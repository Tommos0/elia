defmodule EliaWeb.SettingsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase

  alias Elia.LLM
  alias Elia.LLM.{Anthropic, OpenRouter}
  alias Elia.{Deploy, LiveTree}
  alias Elia.Deploy.Runner

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

    # DEPLOY-16: the runner belongs to Elia's application and every case here
    # shares it, so a case starts with no deploy in flight and no last result.
    settle_deploy()

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

  ## Deployment (CONF-19, CONF-20)

  # A live tree set up for deployment (DEPLOY-14), as Elia's own is.
  defp live_tree do
    tree = LiveTree.create()
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)
    on_exit(fn -> LiveTree.remove(tree) end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)
    end)

    tree
  end

  # A change on the trunk, the way a chat's merge leaves one (DEPLOY-13).
  defp work_on_trunk do
    id = Elia.Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(id)
    on_exit(fn -> Deploy.remove_worktree(id) end)
    LiveTree.work!(path)
    LiveTree.push_to_trunk(path)
  end

  # The running server, as far as a deploy can tell: the endpoint's code
  # reloader is on (HOT-2, HOT-7; the suite turns it off, config/test.exs), and
  # loading a deploy is a message to the test instead of a real recompile, which
  # would rebuild Elia's own endpoint inside the test run (HOT-5).
  defp running_server do
    endpoint = Application.get_env(:elia, EliaWeb.Endpoint)
    deploy = Application.get_env(:elia, Deploy, [])
    test_pid = self()

    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(endpoint, :code_reloader, true))

    Application.put_env(
      :elia,
      Deploy,
      Keyword.put(deploy, :load, fn _endpoint ->
        send(test_pid, :loaded)
        :ok
      end)
    )

    on_exit(fn ->
      Application.put_env(:elia, EliaWeb.Endpoint, endpoint)
      Application.put_env(:elia, Deploy, deploy)
    end)
  end

  # How the server stops for a restart (RESTART-1): a message to the test.
  defp stop_server_with(test_pid) do
    deploy = Application.get_env(:elia, Deploy, [])

    Application.put_env(:elia, Deploy, Keyword.put(deploy, :stop, &send(test_pid, {:stop, &1})))
    on_exit(fn -> Application.put_env(:elia, Deploy, deploy) end)
  end

  # DEPLOY-15, DEPLOY-16: a deploy runs in the runner's own process, so a test
  # waits for the runner's events rather than for a view's async work. Call
  # `Runner.subscribe/0` before clicking, so nothing is missed.
  defp await_deploy(timeout \\ 120_000) do
    assert_receive {:deploy_started, %{mode: _mode}}, 5_000
    assert_receive {:deploy_finished, %{result: result}}, timeout
    result
  end

  # A case starts with no deploy in flight and no last result: wait out one a
  # failed case may have left behind (DEPLOY-16), then forget the result.
  defp settle_deploy(timeout \\ 120_000) do
    Runner.subscribe()

    if Runner.running() do
      assert_receive {:deploy_finished, _}, timeout
    end

    Runner.reset()
    :ok
  end

  # CONF-19, DEPLOY-14
  test "the deployment section says how the live tree stands", %{conn: conn} do
    # The test workspace isn't set up for deployment: it is not on `live`.
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#deployment")
    assert has_element?(view, "#deploy-status", "not on the branch live")
    refute has_element?(view, "#deploy-reload")
    refute has_element?(view, "#deploy-restart")
  end

  # CONF-19, CONF-20, DEPLOY-6
  test "hot reload deploys what the chats merged, and the page stays responsive", %{
    conn: conn
  } do
    running_server()
    tree = live_tree()
    work_on_trunk()

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#deploy-status", "1 commit on master is not deployed yet")
    assert has_element?(view, "#deploy-reload", "Hot reload")
    assert has_element?(view, "#deploy-restart", "Restart")

    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    # CONF-20: both buttons are disabled while the deploy runs.
    assert has_element?(view, "#deploy-reload[disabled]")
    assert has_element?(view, "#deploy-restart[disabled]")

    # CONF-20, DEPLOY-15: the deploy runs in the runner, not in the view.
    assert {:ok, message} = await_deploy()
    assert message =~ "Recompiled and reloaded"
    assert_receive :loaded

    # CONF-20: the result stays in the section rather than flashing by.
    assert has_element?(view, "#deploy-result", "Recompiled and reloaded")
    assert has_element?(view, "#deploy-status", "nothing to deploy")
    assert {:ok, %{pending: 0}} = Deploy.status()
    assert LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
  end

  # CONF-19, CONF-20, DEPLOY-7, RESTART-11
  test "restart deploys and restarts the server", %{conn: conn} do
    running_server()
    stop_server_with(self())
    tree = live_tree()
    work_on_trunk()

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-restart") |> render_click()

    # Only a non-zero status makes `bin/serve` start the server again (RESTART-1).
    assert_receive {:stop, status}, 120_000
    assert status != 0

    assert {:ok, message} = await_deploy()
    assert message =~ "Restarting the server"
    assert has_element?(view, "#deploy-result", "Restarting the server")
    assert LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
  end

  # CONF-20
  test "a deploy that refuses says why", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()
    File.write!(Path.join(tree, "lib/hand_edited.ex"), "defmodule HandEdited do\nend\n")

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    assert {:error, reason} = await_deploy(30_000)
    assert reason =~ "uncommitted changes"
    assert has_element?(view, "#deploy-result", "uncommitted changes")
    refute LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
  end

  # DEPLOY-15: a deploy runs to the end when the page that started it goes away
  # — a deploy's own asset change reloads the page (DEPLOY-12, HOT-9), and a
  # page's teardown must not abort it.
  test "a deploy runs to the end when the page goes away", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    # The page goes away while the deploy runs.
    GenServer.stop(view.pid)

    assert {:ok, message} = await_deploy()
    assert message =~ "Recompiled and reloaded"
    # The merge and the load both happened, though no page was watching.
    assert LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
    # DEPLOY-17: the app's loaded revision is recorded, so nothing looks behind.
    assert {:ok, %{behind?: false}} = Deploy.status()
  end

  # CONF-20, DEPLOY-16: one deploy at a time, and the runner's state reaches a
  # page that mounts while a deploy runs or after it finished.
  test "a page that mounts during or after a deploy shows it", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    # DEPLOY-16: a second request while one runs is refused.
    assert Runner.start(:reload) == {:error, :busy}

    # CONF-20: a page that mounts mid-deploy shows it in flight, without having
    # started it.
    {:ok, during, _html} = live(conn, ~p"/settings")
    assert has_element?(during, "#deploy-reload[disabled]")

    assert {:ok, message} = await_deploy()
    assert message =~ "Recompiled and reloaded"
    assert has_element?(during, "#deploy-result", "Recompiled and reloaded")

    # CONF-20: and a page that mounts after it finished finds the result too.
    {:ok, after_deploy, _html} = live(conn, ~p"/settings")
    assert has_element?(after_deploy, "#deploy-result", "Recompiled and reloaded")
    assert has_element?(after_deploy, "#deploy-status", "nothing to deploy")

    assert LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
  end

  # CONF-19, DEPLOY-17: a deploy that merged but never loaded is reported as
  # such, rather than looking up to date.
  test "the deployment section says the app is behind live", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()

    # A deploy that loaded: the app and `live` agree.
    assert {:ok, _message} = Deploy.hot_reload()
    assert {:ok, %{behind?: false}} = Deploy.status()

    # Another change merges into the live tree without a load — a deploy that was
    # interrupted between the merge and the load (DEPLOY-15).
    work_on_trunk()
    assert {:ok, _message} = Deploy.deploy()
    assert {:ok, %{behind?: true}} = Deploy.status()

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#deploy-status", "the running app is still on")
    # The buttons stay available: a hot reload brings the app up to date with no
    # new tests or merge (DEPLOY-6).
    assert has_element?(view, "#deploy-reload", "Hot reload")

    # The recovery the section describes: hot reload with nothing to deploy
    # still loads, and clears the warning.
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()
    assert {:ok, _message} = await_deploy()

    assert {:ok, %{behind?: false}} = Deploy.status()
    assert has_element?(view, "#deploy-status", "nothing to deploy")
    assert LiveTree.head(tree) == LiveTree.sha(tree, LiveTree.trunk())
  end
end
