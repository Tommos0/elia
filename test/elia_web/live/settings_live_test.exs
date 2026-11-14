defmodule EliaWeb.SettingsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase
  import Elia.PushCase

  alias Elia.LLM
  alias Elia.LLM.{Anthropic, LlamaCpp, LlamaServer, LlamaServerStub, OpenRouter}
  alias Elia.{Deploy, LiveTree, Push}
  alias Elia.Deploy.Runner

  setup do
    reset_settings()
    configure(Anthropic)
    configure(OpenRouter)
    # PUSH-2..PUSH-8: the push section talks to the push service through
    # Req.Test, and keeps its subscriptions in the settings database.
    configure(Push)
    stub_push_service()
    on_exit(&reset_push/0)

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

  # CONF-15, LOCAL-7: every provider that bills links to its billing page; the
  # one that runs on this machine has none to link to.
  test "every billed card links to the provider's billing page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    for info <- LLM.providers(), info.billing_url do
      assert has_element?(view, ~s|a#topup-#{info.key}[href="#{info.billing_url}"]|)
      assert has_element?(view, ~s|a#topup-#{info.key}[target="_blank"][rel~="noopener"]|)
    end

    refute has_element?(view, "#topup-llamacpp")
    assert has_element?(view, "#balance-llamacpp", "Nothing to bill")

    refute has_element?(view, "#refresh-balance-openrouter")
    assert has_element?(view, "#balance-openrouter", "Add a key")
  end

  # LOCAL-24: a provider that needs no key gets a base URL to check and save
  # instead of a key field.
  test "the local provider's card holds a base URL, not a key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#provider-llamacpp")
    assert has_element?(view, "#base-url-form-llamacpp input[name='llamacpp[base_url]']")
    assert has_element?(view, "#check-llamacpp")
    assert has_element?(view, "#save-llamacpp")
    assert has_element?(view, "#key-status-llamacpp", "No key needed")

    refute has_element?(view, "#key-form-llamacpp")
    refute has_element?(view, "#remove-llamacpp")
    refute has_element?(view, "#remove-url-llamacpp")
    refute has_element?(view, "#topup-llamacpp")

    # The providers that bill keep their key form and their credits.
    assert has_element?(view, "#key-form-openrouter")
    assert has_element?(view, "#topup-openrouter")
  end

  # LOCAL-24, LOCAL-3: Check asks the server without storing anything, Save
  # stores the URL the server answered on.
  test "the card's Check and Save use the server that answers", %{conn: conn} do
    {port, port_ref} = start_stub_server()
    on_exit(fn -> Elia.Shell.kill(port_ref) end)
    # A real socket, not Req.Test: this is the health check (LOCAL-24).
    configure(LlamaCpp, req_options: [])

    {:ok, view, _html} = live(conn, ~p"/settings")
    url = "http://127.0.0.1:#{port}"

    view
    |> form("#base-url-form-llamacpp", %{llamacpp: %{"base_url" => url}})
    |> render_submit(%{"action" => "check"})

    render_async(view)

    assert has_element?(view, "#result-llamacpp", "A server answers there.")
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"

    view
    |> form("#base-url-form-llamacpp", %{llamacpp: %{"base_url" => url}})
    |> render_submit(%{"action" => "save"})

    render_async(view)

    assert has_element?(view, "#result-llamacpp", "the URL is saved")
    assert LlamaCpp.base_url() == url
    assert has_element?(view, "#remove-url-llamacpp")

    view |> element("#remove-url-llamacpp") |> render_click()
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"
  end

  # LOCAL-24: a server that isn't there says so, and nothing is saved.
  test "the card's Check reports a server that isn't there", %{conn: conn} do
    configure(LlamaCpp, req_options: [])
    {:ok, view, _html} = live(conn, ~p"/settings")
    port = LlamaServerStub.free_port()

    view
    |> form("#base-url-form-llamacpp", %{llamacpp: %{"base_url" => "http://127.0.0.1:#{port}"}})
    |> render_submit(%{"action" => "save"})

    render_async(view)

    assert has_element?(view, "#result-llamacpp", "No llama.cpp server at")
    assert LlamaCpp.base_url() == "http://127.0.0.1:8080"
  end

  # LOCAL-25, LOCAL-26, LOCAL-27: the section starts a server with its fields,
  # shows the command, the status and the output, and stops it again.
  test "the local model server section starts and stops a server", %{conn: conn} do
    stub = LlamaServerStub.install!()

    # A free port: this host's own llama-server may be on the default 8080, and
    # the badge asks the configured port whether somebody else is there
    # (LOCAL-16).
    configure(LlamaServer,
      binary: stub,
      startup_timeout: 15_000,
      port: LlamaServerStub.free_port()
    )

    # The server's cached URL is the one it started with, so the settings change
    # has to be announced for the badge to stop reporting the external server on
    # 8080 (LOCAL-16, LOCAL-28).
    :ok = LlamaServer.reset()

    port = LlamaServerStub.free_port()
    model = model_file()
    on_exit(fn -> LlamaServer.stop_server() end)

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#local-server")
    assert has_element?(view, "#local-server-form")
    assert has_element?(view, "#local-server-badge", "Stopped")
    assert has_element?(view, "#stop-local-server[disabled]")

    view
    |> form("#local-server-form", %{
      server: %{
        binary: stub,
        model: model,
        models_dir: Path.dirname(model),
        host: "127.0.0.1",
        port: to_string(port),
        context: "4096",
        threads: "4",
        extra_args: "--stub healthy",
        jinja: "true"
      }
    })
    |> render_submit(%{"action" => "start"})

    # LOCAL-25, LOCAL-26: what it runs, where, and with which model.
    assert render(view) =~ "--port #{port}"
    assert render(view) =~ "-c 4096 -t 4 --jinja"
    assert has_element?(view, "#local-server-status", model)

    await_element(view, "#local-server-badge", "Running")

    # LOCAL-27: the output it wrote while it started, and that it is up.
    assert has_element?(view, "#local-server-log")
    assert render(view) =~ "stub: listening on #{port}"
    assert LlamaServerStub.listening?(port)

    view |> element("#stop-local-server") |> render_click()

    assert has_element?(view, "#local-server-result", "Server stopped.")
    await_element(view, "#local-server-badge", "Stopped")
    assert LlamaServerStub.wait_until(fn -> not LlamaServerStub.listening?(port) end)
  end

  # LOCAL-20, LOCAL-25: starting without a llama-server on the machine says what
  # to do about it, in the section.
  test "the section says what to do without a llama-server", %{conn: conn} do
    # A free port: this host's own llama-server may be on the default 8080, and
    # the badge asks the configured port whether somebody else is there
    # (LOCAL-16).
    port = LlamaServerStub.free_port()
    configure(LlamaServer, binary: nil, port: port)

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#local-server-form", %{server: %{model: model_file(), port: to_string(port)}})
    |> render_submit(%{"action" => "start"})

    assert has_element?(view, "#local-server-result", "No llama-server was found")
    assert has_element?(view, "#local-server-badge", "Stopped")
  end

  # LOCAL-21, LOCAL-28: the fields are stored, the models directory offers the
  # .gguf files in it, and Reset puts the configuration back.
  test "the section's fields are saved, and Reset clears them", %{conn: conn} do
    configure(LlamaServer, binary: nil, port: 8080)

    dir = Path.join(System.tmp_dir!(), "elia-settings-models")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "tiny.gguf"), "x")

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#local-server-form", %{
      server: %{
        binary: "",
        models_dir: dir,
        model: Path.join(dir, "tiny.gguf"),
        host: "127.0.0.1",
        port: "9123",
        context: "2048",
        threads: "",
        extra_args: "",
        jinja: "true"
      }
    })
    |> render_submit(%{"action" => "save"})

    assert has_element?(view, "#local-server-result", "Saved.")

    settings = LlamaServer.settings()
    assert settings[:port] == 9123
    assert settings[:context] == 2048
    assert settings[:model] == Path.join(dir, "tiny.gguf")

    # LOCAL-21: the models directory offers the .gguf files in it, read when the
    # page mounts.
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "#local-server-models option[value='#{Path.join(dir, "tiny.gguf")}']"
           )

    view |> element("#reset-local-server") |> render_click()

    assert has_element?(view, "#local-server-result", "Reset")
    assert LlamaServer.settings()[:port] == 8080
    assert LlamaServer.settings()[:context] == nil
  end

  # LOCAL-24: a stub llama-server, listening and healthy, for the tests above.
  defp start_stub_server do
    stub = LlamaServerStub.install!()
    port = LlamaServerStub.free_port()

    port_ref =
      Port.open({:spawn_executable, stub}, [
        :binary,
        :exit_status,
        :hide,
        args: ["--port", to_string(port), "--stub", "healthy"]
      ])

    assert LlamaServerStub.wait_until(fn ->
             LlamaCpp.check_base_url("http://127.0.0.1:#{port}") == :ok
           end)

    {port, port_ref}
  end

  defp model_file do
    path = Path.join(System.tmp_dir!(), "elia-settings-model.gguf")
    unless File.exists?(path), do: File.write!(path, "not really a model")
    path
  end

  defp await_element(view, selector, text, tries \\ 100) do
    cond do
      tries == 0 ->
        flunk("#{selector} never showed #{inspect(text)}")

      has_element?(view, selector, text) ->
        :ok

      true ->
        Process.sleep(50)
        await_element(view, selector, text, tries - 1)
    end
  end

  # CONF-24: the elapsed time the page has rendered — what the client sees,
  # which moves only when the page renders it again.
  defp elapsed_text(view) do
    view
    |> element("#deploy-elapsed")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # CONF-24: the elapsed time once the page has rendered it again by itself.
  # Nothing here sends the view an event, so the only thing that can have moved
  # it is the tick the page scheduled; it gives back the value it started from
  # when nothing moved it.
  defp await_elapsed_moving(view, before, tries \\ 100) do
    now = elapsed_text(view)

    cond do
      tries == 0 ->
        before

      now != before ->
        now

      true ->
        Process.sleep(50)
        await_elapsed_moving(view, before, tries - 1)
    end
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
  defp live_tree(opts \\ []) do
    tree = LiveTree.create(opts)
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
  #
  # With `hold_load`, the deploy stops in its load step and reports itself as
  # `{:loading, pid}`, and waits for `:continue`: that is how a test knows a
  # deploy is really mid-flight instead of racing one that may have finished.
  defp running_server(hold_load \\ false) do
    endpoint = Application.get_env(:elia, EliaWeb.Endpoint)
    deploy = Application.get_env(:elia, Deploy, [])
    test_pid = self()

    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(endpoint, :code_reloader, true))

    load =
      if hold_load do
        fn _endpoint ->
          send(test_pid, {:loading, self()})

          receive do
            :continue -> :ok
          after
            30_000 -> :ok
          end
        end
      else
        fn _endpoint ->
          send(test_pid, :loaded)
          :ok
        end
      end

    Application.put_env(:elia, Deploy, Keyword.put(deploy, :load, load))

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

  # A step of an operation whose two parts are seams, like the whole of it
  # (`config :elia, Elia.Deploy, packages: fun, assets: fun`; DEPLOY-19).
  defp stub_step(name, fun) do
    deploy = Application.get_env(:elia, Deploy, [])
    Application.put_env(:elia, Deploy, Keyword.put(deploy, name, fun))
    on_exit(fn -> Application.put_env(:elia, Deploy, deploy) end)
  end

  # The server going away under an operation (DEPLOY-15, DEPLOY-23): the runner
  # and the operation it holds die together, and the record is what is left
  # behind — the state a restart deploy leaves for the page that comes up after
  # it (CONF-22).
  defp restart_runner do
    pid = Process.whereis(Runner)
    ref = Process.monitor(pid)
    :ok = Supervisor.terminate_child(Elia.Supervisor, Runner)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    {:ok, _pid} = Supervisor.restart_child(Elia.Supervisor, Runner)
    :ok
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
    # The deploy is held in its load step until this test lets it finish, so the
    # page below mounts mid-deploy for real instead of racing one that may have
    # ended already (CONF-20, DEPLOY-16).
    running_server(true)
    tree = live_tree()
    work_on_trunk()

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    # DEPLOY-16: a second request while one runs is refused.
    assert Runner.start(:reload) == {:error, :busy}

    assert_receive {:loading, deploy}, 30_000

    # CONF-20: a page that mounts mid-deploy shows it in flight, without having
    # started it.
    {:ok, during, _html} = live(conn, ~p"/settings")
    assert has_element?(during, "#deploy-reload[disabled]")

    send(deploy, :continue)

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

  # CONF-21, DEPLOY-21, DEPLOY-22: while an operation runs the section shows the
  # steps that have finished with how long each took, the step it is on now and
  # how long it has been running — from the runner, so a page that mounts in the
  # middle of one shows the same.
  test "an operation in flight shows its steps and the step it is on", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()
    assert {:ok, _message} = Deploy.hot_reload()
    earlier = LiveTree.head(tree)
    work_on_trunk()
    assert {:ok, _message} = Deploy.hot_reload()
    work_on_trunk()

    # The deploy is held in its load step, so the test looks at a real operation
    # in flight rather than at one that may have ended already (DEPLOY-22).
    running_server(true)

    {:ok, view, _html} = live(conn, ~p"/settings")
    Runner.subscribe()
    view |> element("#deploy-reload") |> render_click()

    assert_receive {:loading, operation}, 120_000

    # CONF-21: the finished steps, each with how long it took — never the
    # unknown-duration placeholder — the step in flight and the elapsed time.
    assert has_element?(view, "#deploy-steps", "Merging the trunk into the live tree")
    assert has_element?(view, "#deploy-steps", "Running the tests in the live tree")
    refute has_element?(view, "#deploy-steps", "—")
    assert has_element?(view, "#deploy-step", "Hot reloading the running app")
    assert has_element?(view, "#deploy-elapsed")

    # CONF-21: a page that mounts mid-operation shows the same — the deploy's own
    # asset change reloads a page, and this is what it comes back to.
    {:ok, during, _html} = live(conn, ~p"/settings")
    assert has_element?(during, "#deploy-steps", "Running the tests in the live tree")
    assert has_element?(during, "#deploy-step", "Hot reloading the running app")
    assert has_element?(during, "#deploy-elapsed")
    # CONF-24: and it counts on by itself from there — a page that mounts while
    # one runs has the tick that keeps the elapsed time current.
    refute is_nil(:sys.get_state(during.pid).socket.assigns.deploy_timer)

    # CONF-23: going back is offered, and its controls are disabled while an
    # operation runs, the way the deploy buttons are (CONF-20).
    assert has_element?(during, "#deploy-rollback", String.slice(earlier, 0, 12))
    assert has_element?(during, "#deploy-rollback-reload[disabled]")
    assert has_element?(during, "#deploy-rollback-restart[disabled]")

    # CONF-21: a step event advances the section on its own, rather than only
    # when the runner's next report arrives.
    send(
      view.pid,
      {:deploy_progress, %{step: :assets, phase: :started, at: DateTime.utc_now(), ms: nil}}
    )

    assert has_element?(view, "#deploy-step", "Building the live tree's assets")

    send(
      view.pid,
      {:deploy_progress, %{step: :assets, phase: :finished, at: DateTime.utc_now(), ms: 1_500}}
    )

    assert has_element?(view, "#deploy-steps", "Building the live tree's assets")
    assert has_element?(view, "#deploy-steps", "1.5s")
    # CONF-21: the section is no longer on the load step.
    refute has_element?(view, "#deploy-step", "Hot reloading the running app")

    send(operation, :continue)
    assert {:ok, message} = await_deploy()
    assert message =~ "Recompiled and reloaded"

    # CONF-21: the steps it took are still there once it has ended, so the
    # section says what it did rather than only how it turned out.
    assert has_element?(view, "#deploy-steps", "Running the tests in the live tree")
    refute has_element?(view, "#deploy-step")
  end

  # CONF-24: the elapsed time comes from the clock, and the page keeps it
  # current by itself while an operation runs — so it counts on with no reload,
  # no click and nothing new from the runner — and stops once one has ended.
  test "the elapsed time advances by itself while an operation runs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    # An operation in flight (CONF-21, DEPLOY-22), started over a minute ago, so
    # what the section renders is the time since then rather than a fraction of
    # a second.
    started = DateTime.add(DateTime.utc_now(), -65, :second)
    send(view.pid, {:deploy_started, %{mode: :reload, started: started}})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#deploy-elapsed", "1m ")
    # CONF-24: the page has scheduled the tick that keeps it current.
    refute is_nil(:sys.get_state(view.pid).socket.assigns.deploy_timer)

    # CONF-24: it moves with nothing sent to the page and no reload — the tick
    # it scheduled is what renders it again.
    before = elapsed_text(view)

    assert await_elapsed_moving(view, before) != before,
           "the elapsed time never moved: nothing re-rendered it"

    # CONF-24: nothing ticks for an operation that has ended, so a page left
    # open renders no more than it has to.
    send(view.pid, {:deploy_finished, %{mode: :reload, result: {:ok, "done"}}})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#deploy-elapsed")
    assert :sys.get_state(view.pid).socket.assigns.deploy_timer == nil
  end

  # CONF-22, DEPLOY-23: a page that comes back after a restart deploy — whose
  # result died with the process the runner lived in — still says what the
  # deploy did, and where it stopped when it did not finish.
  test "a page that comes back after a restart deploy shows the record", %{conn: conn} do
    running_server()
    live_tree(front_end: true)
    work_on_trunk()
    test = self()

    # The front-end step waits, so the deploy is held in it while the server
    # goes away under it (DEPLOY-15, DEPLOY-23).
    stub_step(:packages, fn _root ->
      send(test, {:packages, self()})

      receive do
        :continue -> {:ok, ""}
      after
        30_000 -> {:ok, ""}
      end
    end)

    stub_step(:assets, fn _root -> {:ok, ""} end)

    Runner.subscribe()
    assert :ok = Runner.start(:restart)
    assert_receive {:packages, _operation}, 120_000

    # The server going away under the operation: the runner and the operation it
    # holds die together, and the record is what is left behind (DEPLOY-23).
    :ok = restart_runner()

    {:ok, view, _html} = live(conn, ~p"/settings")

    # CONF-22: what the deploy did, and where it stopped when it did not finish.
    assert has_element?(view, "#deploy-result", "never finished")
    assert has_element?(view, "#deploy-result", "Installing the live tree's Node packages")
    assert has_element?(view, "#deploy-steps", "Running the tests in the live tree")

    # CONF-20, CONF-22: nothing is in flight any more, so the section says so
    # and the controls are usable again.
    refute has_element?(view, "#deploy-step")
    refute has_element?(view, "#deploy-reload[disabled]")
  end

  # CONF-23, DEPLOY-25, DEPLOY-26: the section offers going back to the newest
  # revision the app has run that is not the one it is running now, and the
  # control goes through the runner — one operation at a time.
  test "the rollback control names the earlier revision and goes back to it", %{conn: conn} do
    running_server()
    tree = live_tree()
    work_on_trunk()
    assert {:ok, _message} = Deploy.hot_reload()
    earlier = LiveTree.head(tree)
    work_on_trunk()
    assert {:ok, _message} = Deploy.hot_reload()
    running_now = LiveTree.head(tree)

    # The rollback is held in its load step, so the test sees it in flight.
    running_server(true)

    {:ok, view, _html} = live(conn, ~p"/settings")

    # CONF-23: the revision to go back to, named by its short sha and when it
    # was loaded — and not the one the app is running now (DEPLOY-26).
    assert has_element?(view, "#deploy-rollback", String.slice(earlier, 0, 12))
    assert has_element?(view, "#deploy-rollback", "loaded")
    refute has_element?(view, "#deploy-rollback", String.slice(running_now, 0, 12))

    Runner.subscribe()
    view |> element("#deploy-rollback-reload") |> render_click()
    assert_receive {:loading, operation}, 30_000

    # CONF-23, CONF-20: a control is disabled while an operation runs.
    assert has_element?(view, "#deploy-rollback-reload[disabled]")
    assert has_element?(view, "#deploy-rollback-restart[disabled]")

    send(operation, :continue)
    assert {:ok, message} = await_deploy(30_000)
    assert message =~ "Rolled"

    # DEPLOY-26: `live` is back at that revision, it is what the app runs, and
    # the operation is recorded as a rollback rather than a deploy.
    assert LiveTree.head(tree) == earlier
    assert %{kind: :rollback, sha: ^earlier} = Deploy.last_deploy()
    assert has_element?(view, "#deploy-result", "Rolled")

    # CONF-23: what is left to go back to is the revision it came from.
    assert has_element?(view, "#deploy-rollback", String.slice(running_now, 0, 12))
  end

  # CONF-23, DEPLOY-26: nothing to go back to when the app has only ever run the
  # revision it is running now.
  test "the rollback control is absent when there is no earlier revision", %{conn: conn} do
    running_server()
    live_tree()
    assert {:ok, _message} = Deploy.hot_reload()
    assert [%{sha: sha}] = Deploy.loaded_revisions()

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#deploy-reload")
    refute has_element?(view, "#deploy-rollback")
    assert {:ok, %{loaded: ^sha, behind?: false}} = Deploy.status()

    # CONF-23, RECOVER-10: the recovery page's address is said anyway, for when
    # this page's own UI is what a deploy broke.
    assert has_element?(view, "#recover-note", "/recover")
    assert has_element?(view, ~s|#recover-note a[href="/recover"]|)
  end

  # PUSH-2
  test "the push section carries the key a browser subscribes with", %{conn: conn} do
    key = Push.public_key()
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, ~s(#push-section[data-vapid-public-key="#{key}"]))
    assert has_element?(view, "#push-toggle")
  end

  # PUSH-22
  test "a page that has not reached the server says so; a connected one checks", %{conn: conn} do
    # The dead render: the browser has the page, but none of the section's own
    # script has run and nothing has been read, so it says which of the two it
    # is doing. On a phone, which has no console, that is how a page that never
    # connected is told from a reading that failed.
    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ "This page has not reached the server yet"
    refute html =~ "Checking this browser"

    # Connected, and before the hook has answered (PUSH-20): reading it is.
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#push-reason", "Checking this browser")
  end

  # PUSH-23
  test "a reason takes the switch's place, not the server's own controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    # What a reason replaces (PUSH-5) is the switch, and the switch is the whole
    # of that row: the count, the test notification and "remove all" are about
    # the server, so they stay reachable where this browser cannot push.
    assert has_element?(view, "#push-switch-row #push-toggle")
    refute has_element?(view, "#push-switch-row #push-send-test")
    refute has_element?(view, "#push-switch-row #push-remove-all")
    refute has_element?(view, "#push-switch-row #push-count")

    assert has_element?(view, "#push-controls #push-send-test")
    assert has_element?(view, "#push-controls #push-remove-all")
    assert has_element?(view, "#push-controls #push-count")
  end

  # PUSH-3, PUSH-7
  test "a subscription the page reports is stored, and the section counts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#push-count", "No device is subscribed yet.")
    assert has_element?(view, "#push-remove-all[disabled]")

    render_hook(view, "push-subscribe", %{"subscription" => subscription(receiver())})

    assert Push.Subscriptions.count() == 1
    assert has_element?(view, "#push-count", "1 device is subscribed.")
    assert has_element?(view, "#push-status", "This device is subscribed.")
    refute has_element?(view, "#push-remove-all[disabled]")
  end

  # PUSH-3
  test "a subscription that is not a usable one is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_hook(view, "push-subscribe", %{
      "subscription" => %{"endpoint" => "http://push.example.net/sub/1"}
    })

    assert Push.Subscriptions.count() == 0
    assert has_element?(view, "#push-status", "not a usable one")
  end

  # PUSH-3, PUSH-4
  test "unsubscribing one device leaves the others", %{conn: conn} do
    :ok = Push.Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/1"))
    :ok = Push.Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/2"))

    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#push-count", "2 devices are subscribed.")

    render_hook(view, "push-unsubscribe", %{"endpoint" => "https://push.example.net/sub/1"})

    assert Push.Subscriptions.count() == 1
    assert has_element?(view, "#push-count", "1 device is subscribed.")
    assert has_element?(view, "#push-status", "no longer subscribed")
  end

  # PUSH-7
  test "remove all forgets every device", %{conn: conn} do
    :ok = Push.Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/1"))
    :ok = Push.Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/2"))

    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> element("#push-remove-all") |> render_click()

    assert Push.Subscriptions.count() == 0
    assert has_element?(view, "#push-count", "No device is subscribed yet.")
    assert has_element?(view, "#push-status", "Every subscribed device was removed.")
  end

  # PUSH-8
  test "the test notification reports what the push service said", %{conn: conn} do
    store()

    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> element("#push-send-test") |> render_click()

    assert_receive {:push_request, "/sub/1", _headers, _body}
    render_async(view)
    assert has_element?(view, "#push-status", "Accepted by the push service for 1 subscription.")
  end

  # PUSH-8
  test "the test notification says when no device is subscribed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    view |> element("#push-send-test") |> render_click()

    render_async(view)

    assert has_element?(
             view,
             "#push-status",
             "No device is subscribed yet, so there was nowhere to send it."
           )
  end
end
