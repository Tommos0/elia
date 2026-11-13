defmodule EliaWeb.RecoveryTest do
  # RECOVER-10 to RECOVER-15: `/recover`, the plain page that reaches the app
  # when a deploy has left the app's own UI unusable (`specs/recovery.md`).
  #
  # The page is a plug in the endpoint, not a LiveView: these tests drive it
  # through the endpoint the way a browser would (`get`/`post`), with no layout
  # and no bundle in the way.
  use EliaWeb.ConnCase, async: false

  alias Elia.Deploy
  alias Elia.Deploy.Runner
  alias Elia.LiveTree

  # A rollback runs a real `git reset` in a throwaway live tree and waits on a
  # step the test holds open, and the shared runner may still be settling.
  @moduletag timeout: 120_000

  # The times the record carries, so the page's own wording can be asserted.
  @loaded_at ~U[2025-01-02 03:04:05Z]
  @older_at ~U[2025-01-01 10:00:00Z]
  @started ~U[2025-01-02 03:00:00Z]
  @finished ~U[2025-01-02 03:05:33Z]

  # A same-origin request, which is what a browser's own POST is (RECOVER-13).
  @origin {"origin", "http://www.example.com"}

  setup do
    # DEPLOY-2: the tree the page reads is the live tree's own. A throwaway one
    # (a git repo on `live`, with a trunk), so nothing here touches the server's.
    tree = LiveTree.create(front_end: true)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)

    running_server()
    settle_runner()

    on_exit(fn ->
      LiveTree.remove(tree)

      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)
    end)

    %{tree: tree}
  end

  ## Helpers

  # The page as a document to look things up in, by the ids it renders.
  defp doc(conn, status) do
    conn |> html_response(status) |> LazyHTML.from_document()
  end

  defp id(doc, id), do: LazyHTML.query_by_id(doc, id)

  defp text(node), do: node |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()

  defp short(sha), do: String.slice(sha, 0, 7)

  # The record the runner writes as an operation goes (DEPLOY-23, DEPLOY-25), for
  # a test that needs a state it cannot reach by deploying: an operation that
  # never ended — what a restart deploy leaves when the VM dies under it
  # (DEPLOY-17, CONF-22) — or nothing at all.
  defp record(tree, revisions, opts) do
    Deploy.write_record(tree, %{
      running: opts[:running],
      last: opts[:last],
      loaded: revisions
    })
  end

  defp revision(sha, opts \\ []) do
    %{
      sha: sha,
      at: opts[:at] || @loaded_at,
      by: opts[:by] || :deploy,
      mode: opts[:mode] || :reload
    }
  end

  defp operation(opts) do
    %{
      kind: opts[:kind] || :deploy,
      mode: opts[:mode] || :reload,
      sha: opts[:sha],
      started: opts[:started] || @started,
      finished: opts[:finished],
      step: opts[:step],
      steps: opts[:steps] || [],
      result: opts[:result]
    }
  end

  # A revision added to the live tree: a change on `live`, committed there, with
  # the trunk fast-forwarded to it. A live tree whose trunk is behind `live` is
  # not set up for deployment (DEPLOY-14), and every operation is refused there.
  defp commit(tree, name) do
    File.write!(Path.join(tree, "lib/#{name}.ex"), "defmodule #{Macro.camelize(name)} do\nend\n")
    sha = LiveTree.commit(tree, name)
    LiveTree.git!(tree, ["branch", "-f", "master", "live"])
    sha
  end

  # A live tree with two revisions the app has run: the one it is on (the newest)
  # and the one a form goes back to.
  #
  # DEPLOY-23: the runner is the record's only writer, so the revisions go in
  # through it — the record on disk and the one it holds are then the same, and
  # the rollback the page starts reads back what the page offered.
  defp recorded(tree) do
    first = LiveTree.head(tree)
    second = commit(tree, "second")

    :ok = Runner.loaded(tree, first, :deploy, :reload)
    :ok = Runner.loaded(tree, second, :deploy, :reload)

    {first, second}
  end

  # The running server, as far as a rollback can tell (HOT-2, HOT-7, DEPLOY-26):
  # the endpoint's code reloader is on, and loading, stopping and the front end
  # are the test's own functions — a real recompile inside a test run would
  # rebuild Elia's own endpoint (HOT-5), `System.stop` would end the run, and npm
  # would install into a throwaway tree.
  defp running_server do
    endpoint = Application.get_env(:elia, EliaWeb.Endpoint)
    deploy = Application.get_env(:elia, Elia.Deploy, [])
    test = self()

    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(endpoint, :code_reloader, true))

    Application.put_env(
      :elia,
      Elia.Deploy,
      Keyword.merge(deploy,
        load: fn _endpoint ->
          send(test, :loaded)
          :ok
        end,
        stop: fn status -> send(test, {:stop, status}) end,
        packages: fn _root -> {:ok, ""} end,
        assets: fn _root -> {:ok, ""} end
      )
    )

    on_exit(fn ->
      Application.put_env(:elia, EliaWeb.Endpoint, endpoint)
      Application.put_env(:elia, Elia.Deploy, deploy)
    end)
  end

  # A step of an operation replaced (`config :elia, Elia.Deploy, packages: fun`),
  # the way `test/elia/deployment_test.exs` replaces it.
  defp stub_step(name, fun) do
    deploy = Application.get_env(:elia, Elia.Deploy, [])
    Application.put_env(:elia, Elia.Deploy, Keyword.put(deploy, name, fun))
    on_exit(fn -> Application.put_env(:elia, Elia.Deploy, deploy) end)
  end

  # A build step that waits for the test, so a page can be rendered while the
  # operation really is mid-flight (DEPLOY-21, DEPLOY-22).
  defp holding_step(test) do
    stub_step(:packages, fn _root ->
      send(test, {:packages, self()})

      receive do
        :continue -> {:ok, ""}
      after
        30_000 -> {:ok, ""}
      end
    end)
  end

  # DEPLOY-16: the runner belongs to Elia's application and every case here
  # shares it, so a case starts with no operation in flight and no result.
  defp settle_runner(timeout \\ 120_000) do
    if Runner.running() do
      Runner.subscribe()
      assert_receive {:deploy_finished, _event}, timeout
    end

    Runner.reset()
    :ok
  end

  # The tree's front end, gone for the length of the test: the bundle, the
  # stylesheet and the images a deploy builds live under `priv/static`.
  defp without_static(fun) do
    static = Application.app_dir(:elia, "priv/static")
    aside = static <> ".recovery-test"

    if File.dir?(static) do
      File.rm_rf!(aside)
      File.rename!(static, aside)
    end

    on_exit(fn ->
      if File.dir?(aside), do: File.rename!(aside, static)
    end)

    fun.()
  end

  ## RECOVER-10: plain, server-rendered HTML

  # RECOVER-10
  test "GET /recover is plain HTML that needs none of the app's front end", %{conn: conn} do
    conn = get(conn, "/recover")
    html = html_response(conn, 200)

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/html"

    # Its own page, end to end: no bundle, no JavaScript, no LiveView socket, and
    # not the app's own layout (`EliaWeb.Layouts`), which a broken deploy may be.
    refute html =~ "<script"
    refute html =~ "<link"
    refute html =~ "/assets/"
    refute html =~ "priv/static"
    refute html =~ "phx-"
    refute html =~ "manifest.webmanifest"

    # Its own small inline stylesheet instead, and its own ids.
    assert html =~ "<style>"
    assert html =~ "recover-revisions"
    assert html =~ "recover-last"
  end

  # RECOVER-10: the tree's front end is what a bad deploy breaks, so the page
  # answers with it gone.
  test "the page renders with the tree's front end gone", %{conn: conn} do
    without_static(fn ->
      page = conn |> get("/recover") |> doc(200)

      assert Enum.count(id(page, "recover-revisions")) == 1
      assert Enum.count(id(page, "recover-last")) == 1
      assert text(id(page, "recover-back")) == "Back to the app"
    end)
  end

  ## RECOVER-11: what the app is on, what it has run, and what the last operation did

  # RECOVER-11
  test "the page reports the running revision, the revisions it has run and the last operation",
       %{conn: conn, tree: tree} do
    first = LiveTree.head(tree)
    second = commit(tree, "second")

    record(
      tree,
      [
        revision(second),
        revision(first, by: :rollback, mode: :restart, at: @older_at)
      ],
      last:
        operation(
          kind: :rollback,
          mode: :restart,
          sha: first,
          finished: @finished,
          result: {:ok, "Rolled live back to #{short(first)}."},
          steps: [
            %{step: :reset, ms: 1200, status: :ok},
            %{step: :load, ms: 800, status: :ok}
          ]
        )
    )

    page = conn |> get("/recover") |> doc(200)

    # What the running app is on (DEPLOY-17): the newest revision, with no
    # loaded-revision file to say it separately.
    assert text(id(page, "recover-current")) == "The running app is on #{short(second)}."

    # The revisions it has run (DEPLOY-25), newest first, each with when it was
    # loaded and by what.
    revisions = id(page, "recover-revisions")
    assert Enum.count(LazyHTML.query(revisions, "li")) == 2

    newest = text(id(page, "recover-revision-" <> short(second)))
    assert newest =~ short(second)
    assert newest =~ "2025-01-02 03:04:05 UTC"
    assert newest =~ "by a deploy"
    assert newest =~ "hot reload"
    assert newest =~ "running now"

    oldest = text(id(page, "recover-revision-" <> short(first)))
    assert oldest =~ short(first)
    assert oldest =~ "2025-01-01 10:00:00 UTC"
    assert oldest =~ "by a rollback"
    assert oldest =~ "restart"
    refute oldest =~ "running now"

    # Newest first.
    rows = LazyHTML.to_html(revisions)
    {newest_at, _length} = :binary.match(rows, short(second))
    {oldest_at, _length} = :binary.match(rows, short(first))
    assert newest_at < oldest_at

    # What the last operation did (DEPLOY-23): its kind, whether it finished,
    # where it stopped and its result.
    last = text(id(page, "recover-last"))
    assert last =~ "A rollback by restart"
    assert last =~ "started 2025-01-02 03:00:00 UTC"
    assert last =~ "It finished at 2025-01-02 03:05:33 UTC"
    assert last =~ "It was going back to #{short(first)}"
    assert last =~ "Last step: Hot reloading the running app"
    assert last =~ "Moving the live tree back to that revision"
    assert last =~ "It finished: Rolled live back to #{short(first)}."
  end

  # RECOVER-11, DEPLOY-23, CONF-22: an operation that never ended — a restart
  # deploy whose VM died under it — is reported as one, and says where it got to.
  test "an operation that never finished says so, and where it stopped",
       %{conn: conn, tree: tree} do
    first = LiveTree.head(tree)

    record(tree, [revision(first)],
      running:
        operation(
          mode: :restart,
          step: :restart,
          steps: [
            %{step: :merge, ms: 100, status: :ok},
            %{step: :tests, ms: 200, status: :ok}
          ]
        )
    )

    page = conn |> get("/recover") |> doc(200)
    last = text(id(page, "recover-last"))

    assert last =~ "A deploy by restart"
    assert last =~ "It never finished: the process it was running in ended first"
    assert last =~ "It stopped at: Restarting the server"
    assert last =~ "Merging the trunk into the live tree"
    assert last =~ "Running the tests in the live tree"
    assert last =~ "It never finished: it reported no result"
  end

  # RECOVER-11: a record that isn't there at all renders as nothing recorded.
  test "a missing record renders as nothing recorded", %{conn: conn} do
    page = conn |> get("/recover") |> doc(200)

    assert text(id(page, "recover-current")) == "No revision is recorded as loaded."
    assert Enum.count(id(page, "recover-no-revisions")) == 1
    assert Enum.count(id(page, "recover-nothing")) == 1
    assert Enum.count(LazyHTML.query(page, "form")) == 0
  end

  # RECOVER-11: and so does a corrupt one — the page works when other things
  # don't, so it never crashes on what it reads.
  test "a corrupt record renders as nothing recorded", %{conn: conn, tree: tree} do
    head = LiveTree.head(tree)
    File.mkdir_p!(Path.dirname(Deploy.record_path()))
    File.write!(Deploy.record_path(), "{this is not the record")

    page = conn |> get("/recover") |> doc(200)

    assert Enum.count(id(page, "recover-no-revisions")) == 1
    assert Enum.count(id(page, "recover-nothing")) == 1
    assert text(id(page, "recover-current")) == "No revision is recorded as loaded."

    # Nothing in it is a revision to go back to, so a POST that names one is
    # refused rather than guessed at (RECOVER-14), and nothing runs.
    conn = conn |> put_origin() |> post("/recover", %{"revision" => sha(), "mode" => "reload"})
    assert html_response(conn, 400)
    assert Runner.state().running == nil
    assert LiveTree.head(tree) == head
    refute_received {:deploy_finished, _event}
    refute_received :loaded
  end

  ## RECOVER-12: going back from the page

  # RECOVER-12: every kept revision that is not the one running has a form, with
  # the revision in a `revision` field and a button per load mode.
  test "each kept revision that is not the one running has a form", %{conn: conn, tree: tree} do
    {first, second} = recorded(tree)

    page = conn |> get("/recover") |> doc(200)

    assert Enum.count(LazyHTML.query(page, "form")) == 1

    form = id(page, "recover-form-" <> short(first))
    assert LazyHTML.attribute(form, "method") == ["post"]
    assert LazyHTML.attribute(form, "action") == ["/recover"]

    # The revision the form goes back to, in a field a test can post.
    assert Enum.count(LazyHTML.query(form, ~s(input[name="revision"][value="#{first}"]))) == 1
    assert Enum.count(LazyHTML.query(form, ~s(input[name="revision"][value="#{second}"]))) == 0

    # A button per load mode (DEPLOY-6, DEPLOY-7), each posting its own mode.
    assert Enum.count(LazyHTML.query(form, ~s(button[name="mode"][value="reload"]))) == 1
    assert Enum.count(LazyHTML.query(form, ~s(button[name="mode"][value="restart"]))) == 1

    # And no form for the revision running now: there is nothing to go back to.
    assert Enum.count(id(page, "recover-form-" <> short(second))) == 0
  end

  # RECOVER-12, DEPLOY-15, DEPLOY-16: the POST hands the work to the runner — a
  # build and a load is minutes, not a request that hangs — and the page it
  # renders says the operation is running and which step it is on.
  test "a POST starts the rollback in the runner, and the page reports it",
       %{conn: conn, tree: tree} do
    {first, _second} = recorded(tree)
    test_pid = self()

    # The build waits for the test, so the page below is rendered while the
    # rollback really is mid-operation (DEPLOY-21, DEPLOY-22).
    holding_step(test_pid)
    Runner.subscribe()

    conn =
      conn
      |> put_origin()
      |> post("/recover", %{"revision" => first, "mode" => "reload"})

    # DEPLOY-16: it is the operation the runner is running, for that revision and
    # mode.
    assert %{running: %{kind: :rollback, mode: :reload, sha: ^first}} = Runner.state()

    page = doc(conn, 200)
    running = text(id(page, "recover-running"))
    assert running =~ "A rollback by hot reload is running"
    assert running =~ "It started at"

    # Following it: a link that reloads the page, and a meta refresh so it keeps
    # up by itself. No script.
    assert LazyHTML.attribute(id(page, "recover-refresh"), "href") == ["/recover"]
    assert conn.resp_body =~ ~s(http-equiv="refresh")
    refute conn.resp_body =~ "<script"

    # DEPLOY-21, DEPLOY-22: a page rendered while it runs says which step it is
    # on, and offers no second one.
    assert_receive {:packages, operation}, 120_000
    during = conn |> get("/recover") |> doc(200)
    assert text(id(during, "recover-step")) == "It is on: #{Deploy.step_label(:packages)}."
    assert Enum.count(LazyHTML.query(during, "button[disabled]")) == 2

    # DEPLOY-15: the runner owns it, so it runs to the end with no page watching,
    # and what it loaded is recorded (DEPLOY-17).
    send(operation, :continue)
    assert_receive {:deploy_finished, %{result: {:ok, _message}}}, 120_000
    assert_receive :loaded
    assert Deploy.loaded_revision() == first
    assert LiveTree.head(tree) == first
  end

  ## RECOVER-13: the origin rule

  # RECOVER-13
  test "a POST from the app's own origin is accepted", %{conn: conn, tree: tree} do
    {first, _second} = recorded(tree)
    Runner.subscribe()

    conn =
      conn
      |> put_origin()
      |> post("/recover", %{"revision" => first, "mode" => "reload"})

    assert html_response(conn, 200)
    assert %{running: %{kind: :rollback, sha: ^first}} = Runner.state()
    assert_receive {:deploy_finished, %{result: {:ok, _message}}}, 120_000
    assert_receive :loaded
  end

  # RECOVER-13: through a proxy that terminates TLS, `https://app.example.com`
  # matches `Host: app.example.com` with `X-Forwarded-Proto: https`, and the
  # first value of a forwarded header is the one that counts.
  test "a POST through a proxy matches the forwarded origin", %{tree: tree} do
    {first, _second} = recorded(tree)
    Runner.subscribe()

    # The proxy passes the request on over http, on the server's own port, with
    # the client's scheme and host in the forwarded headers.
    conn =
      build_conn(:post, "http://app.example.com/recover")
      |> put_req_header("x-forwarded-proto", "https, http")
      |> put_req_header("x-forwarded-host", "app.example.com, inner.example.com")
      |> put_req_header("origin", "https://app.example.com")
      |> post("/recover", %{"revision" => first, "mode" => "reload"})

    assert html_response(conn, 200)
    assert %{running: %{kind: :rollback, sha: ^first}} = Runner.state()
    assert_receive {:deploy_finished, %{result: {:ok, _message}}}, 120_000
  end

  # RECOVER-13: a missing, `null`, other-scheme, other-host or other-port origin
  # gets a 403 and nothing runs.
  test "a POST that is not same-origin is refused, and nothing runs", %{conn: conn, tree: tree} do
    {first, second} = recorded(tree)
    head = LiveTree.head(tree)

    refused = [
      # No origin at all.
      [],
      # A sandboxed page's own origin.
      [{"origin", "null"}],
      # Another scheme: the server received http and the origin says https.
      [{"origin", "https://www.example.com"}],
      # And the other way round: a proxy says the client used https.
      [{"x-forwarded-proto", "https"}, {"origin", "http://www.example.com"}],
      # Another host.
      [{"origin", "http://elsewhere.example"}],
      # Another port.
      [{"origin", "http://www.example.com:1234"}],
      # Not an origin at all.
      [{"origin", "www.example.com"}]
    ]

    for headers <- refused do
      request = Enum.reduce(headers, conn, &put_req_header(&2, elem(&1, 0), elem(&1, 1)))
      conn = post(request, "/recover", %{"revision" => first, "mode" => "reload"})

      assert html_response(conn, 403) =~ "did not come from this app"
      assert Runner.state().running == nil
    end

    # Nothing ran: the tree is where it was, nothing was loaded, and no second
    # revision was written.
    assert LiveTree.head(tree) == head
    assert Deploy.loaded_revision() == nil
    assert Deploy.loaded_revisions() |> Enum.map(& &1.sha) == [second, first]
    refute_received {:deploy_finished, _event}
    refute_received :loaded
  end

  ## RECOVER-14: the refusals

  # RECOVER-10: the page works when other things don't. With the deploy runner
  # gone it still renders its record, and a POST that would need the runner says
  # so rather than crashing (RECOVER-14).
  test "the page renders, and refuses, when the runner is not running",
       %{conn: conn, tree: tree} do
    {first, current} = recorded(tree)

    :ok = Supervisor.terminate_child(Elia.Supervisor, Runner)
    on_exit(fn -> Supervisor.restart_child(Elia.Supervisor, Runner) end)

    page = conn |> get("/recover") |> doc(200)
    assert text(id(page, "recover-current")) == "The running app is on #{short(current)}."

    conn = conn |> put_origin() |> post("/recover", %{"revision" => first, "mode" => "reload"})
    assert html_response(conn, 503) =~ "is not running"
  end

  # RECOVER-14
  test "any method other than GET and POST gets a 405", %{conn: conn} do
    for method <- [:put, :delete, :patch] do
      conn = dispatch(conn, EliaWeb.Endpoint, method, "/recover")

      assert html_response(conn, 405) =~ "Only GET and POST are allowed on /recover"
      assert get_resp_header(conn, "allow") == ["GET, POST"]
    end

    # HEAD too: the plug is before `Plug.Head`, which would rewrite it to a GET.
    # A HEAD response carries no body, so it is asserted by status and header.
    head = dispatch(conn, EliaWeb.Endpoint, :head, "/recover")
    assert head.status == 405
    assert get_resp_header(head, "allow") == ["GET, POST"]
  end

  # RECOVER-14
  test "a POST naming a revision the app has not run gets a 400 and nothing runs",
       %{conn: conn, tree: tree} do
    {first, _second} = recorded(tree)
    head = LiveTree.head(tree)
    conn = put_origin(conn)

    # A revision that is in no record at all, and one that is too short to name
    # a revision.
    for revision <- [sha(), String.slice(first, 0, 3)] do
      conn_post = post(conn, "/recover", %{"revision" => revision, "mode" => "reload"})
      assert html_response(conn_post, 400) =~ "not one the running app has run"
    end

    # No revision field, and a load mode this page does not offer.
    assert html_response(post(conn, "/recover", %{"mode" => "reload"}), 400)
    assert html_response(post(conn, "/recover", %{"revision" => first}), 400)
    assert html_response(post(conn, "/recover", %{"revision" => first, "mode" => "later"}), 400)

    assert Runner.state().running == nil
    assert LiveTree.head(tree) == head
    assert Deploy.loaded_revision() == nil
    refute_received {:deploy_finished, _event}
    refute_received :loaded
  end

  # RECOVER-14, DEPLOY-16: a POST while an operation runs is refused with a 409
  # saying so, the way the runner refuses a second deploy.
  test "a POST while an operation runs gets a 409", %{conn: conn, tree: tree} do
    {first, _second} = recorded(tree)

    holding_step(self())
    Runner.subscribe()
    assert :ok = Runner.rollback(first, :reload)
    assert_receive {:packages, operation}, 120_000

    conn =
      conn
      |> put_origin()
      |> post("/recover", %{"revision" => first, "mode" => "restart"})

    assert html_response(conn, 409) =~ "An operation is already running"
    # The one that was already running is still the one running.
    assert %{running: %{kind: :rollback, mode: :reload}} = Runner.state()

    send(operation, :continue)
    assert_receive {:deploy_finished, %{result: {:ok, _message}}}, 120_000
  end

  ## RECOVER-15

  # RECOVER-15
  test "the page links back to the app", %{conn: conn} do
    page = conn |> get("/recover") |> doc(200)

    assert Enum.count(LazyHTML.query(page, ~s(a[href="/"]))) == 1
    assert text(id(page, "recover-back")) =~ "Back to the app"

    # And the link leads somewhere: the app's own front page answers.
    assert conn |> get("/") |> html_response(200) =~ "<html"
  end

  # A same-origin request header (RECOVER-13).
  defp put_origin(conn), do: put_req_header(conn, elem(@origin, 0), elem(@origin, 1))

  # A sha no record holds.
  defp sha, do: String.duplicate("a", 40)
end
