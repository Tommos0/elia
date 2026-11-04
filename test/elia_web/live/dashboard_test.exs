defmodule EliaWeb.DashboardTest do
  @moduledoc """
  The dashboard at `/` (DASH-1 - DASH-11): the home screen the app opens on,
  which lists what needs the user, where they left off, their projects, the
  machine and the deploy state — and starts nothing.
  """
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Deploy, LiveTree, Projects, Store, Workspace}
  alias Elia.LLM.Message

  # DASH-1: a store of its own — a throwaway runtime root, where Elia's data,
  # its chats and its projects live — so a test sees only what it wrote.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "dashboard-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf!(root)
      Elia.Settings.delete(:default_project)
    end
  end

  # A saved chat with one message, so it has a title (STORE-7).
  defp saved_chat(text \\ "where I left off") do
    id = Agent.new_id()
    :ok = Store.save(id, [Message.user(text)])
    id
  end

  # A sub-task chat (STORE-16).
  defp saved_task_chat(parent, status \\ "done") do
    id = Agent.new_id()

    :ok =
      Store.save(id, [Message.user("preamble")],
        task: %{parent_id: parent, title: "A task", brief: "Brief", status: status}
      )

    id
  end

  # A chat the app stopped mid-turn: it carries the turn it was running, which
  # is what STORE-31 turns into `interrupted` while no session for it runs
  # (INTR-2).
  defp interrupted_chat(text) do
    id = Agent.new_id()

    :ok =
      Store.save(id, [Message.user(text)], turn: %{id: "turn-1", started_at: DateTime.utc_now()})

    id
  end

  # What a session reports (SESS-19): the registry value, which is what a page
  # reads on first render, and the activity broadcast, which is what a page that
  # is already open follows.
  defp publish_status(id, status) do
    case Registry.register(Elia.Agent.Registry, id, status) do
      {:ok, _} ->
        :ok

      # A status the same test process already published: update it, as a
      # session's own `Registry.update_value` has it (SESS-19).
      {:error, {:already_registered, _pid}} ->
        Registry.update_value(Elia.Agent.Registry, id, fn _ -> status end)

      {:error, reason} ->
        raise "could not publish #{status} for #{id}: #{inspect(reason)}"
    end

    Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})
  end

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    [left | _rest] = String.split(html, second)
    left =~ first
  end

  ## Home (DASH-1, DASH-2)

  # DASH-1, DASH-2: the app's start URL is a page of cards, not a chat.
  test "/ is the dashboard: it opens no chat and writes nothing", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/")

      assert page_title(view) == "Elia - Home"
      assert has_element?(view, "h1", "Home")
      # DASH-1: no session, no chat, nothing written.
      assert Store.list(1000) == []
      refute has_element?(view, "#chat-form")

      # DASH-2: the standard header, with the logo home and Chats to the chat
      # list's entry point (UI-32, UI-77); no chat list of its own.
      assert has_element?(view, "header a[href='/'][title='Home']")
      assert has_element?(view, "header #chats-link[href='/chats']")
      refute has_element?(view, "#chats-toggle")
      refute has_element?(view, "#sidebar")
    end)
  end

  ## Where you left off (DASH-3, DASH-4)

  # DASH-3
  test "the Continue card shows the chat you left off in", %{conn: conn} do
    with_empty_store(fn ->
      older = saved_chat("the first one")
      # A sub-task chat started after it is not where the user left off
      # (STORE-29, UI-77).
      task = saved_task_chat(older)
      newest = saved_chat("where I left off")
      publish_status(newest, :awaiting_approval)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#continue-link[href='/c/#{newest}']")
      assert has_element?(view, "#continue-title", "where I left off")
      assert has_element?(view, "#continue-project", "Elia")
      # UI-34: when it was started, relative, with the exact time on hover.
      assert has_element?(view, "#continue-time[datetime][title]", "just now")
      # UI-47, UI-59: the same status the sidebar shows.
      assert has_element?(view, "#continue-status[data-status='awaiting_approval']")

      refute has_element?(view, "#continue-link[href='/c/#{task}']")
      refute has_element?(view, "#continue-empty")
    end)
  end

  # DASH-3, DONE-10, DONE-2: a done chat is not where the user left off, though
  # the dashboard still lists it (DASH-7) with its done status (UI-59).
  test "a done chat is not the chat to continue", %{conn: conn} do
    with_empty_store(fn ->
      older = saved_chat("where I left off")
      done = Agent.new_id()
      :ok = Store.save(done, [Message.user("finished")], done: true)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#continue-link[href='/c/#{older}']")
      refute has_element?(view, "#continue-link[href='/c/#{done}']")
      assert has_element?(view, "#recent-#{done}")
      assert has_element?(view, "#recent-status-#{done}[data-status='done']")
    end)
  end

  # DASH-4
  test "the New chat button starts a chat in the default project", %{conn: conn} do
    with_empty_store(fn ->
      root = Path.join(Workspace.root(), "dashboard-default-project")
      File.mkdir_p!(root)
      {:ok, project} = Projects.create("Default one", root)
      on_exit(fn -> File.rm_rf!(root) end)

      # DASH-4: with nothing saved there is no chat to continue.
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#continue-empty")
      assert has_element?(view, "#new-chat[href='/p/harness/new']")

      Elia.Projects.set_default(project.id)
      new = saved_chat()

      {:ok, view, _html} = live(conn, ~p"/")
      # DASH-4: the button follows the default project (PROJ-8), and stays when
      # there is a chat to continue.
      assert has_element?(view, "#new-chat[href='/p/#{project.id}/new']")
      assert has_element?(view, "#continue-link[href='/c/#{new}']")
      refute has_element?(view, "#continue-empty")
    end)
  end

  ## Needs attention (DASH-5, DASH-6)

  # DASH-5, DASH-6: everything that wants the user, each a link to its chat.
  test "the Needs attention card lists what wants the user", %{conn: conn} do
    with_empty_store(fn ->
      waiting = saved_chat("waiting on me")
      paused = saved_chat("paused one")
      # UI-47: a sub-task chat needs the user too.
      task = saved_task_chat(waiting, "running")
      cut = interrupted_chat("a turn a restart killed")

      publish_status(waiting, :awaiting_approval)
      publish_status(paused, :paused)
      publish_status(task, :awaiting_approval)

      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#attention-#{waiting}[data-reason='awaiting_approval']")
      assert has_element?(view, "#attention-#{paused}[data-reason='paused']")
      assert has_element?(view, "#attention-#{cut}[data-reason='interrupted']")
      assert has_element?(view, "#attention-#{task}[data-reason='awaiting_approval']")

      # DASH-6: a row links to the chat and says why in words; the controls for
      # it stay in the chat itself.
      assert has_element?(view, "#attention-#{waiting} a[href='/c/#{waiting}']", "Needs approval")

      assert has_element?(
               view,
               "#attention-#{paused} a[href='/c/#{paused}']",
               "Paused at a limit"
             )

      assert has_element?(
               view,
               "#attention-#{cut} a[href='/c/#{cut}']",
               "Interrupted by a restart"
             )

      refute has_element?(view, "#attention-#{waiting} button")

      # DASH-5: the chats that block a turn come first, then the interrupted.
      assert before?(html, "id=\"attention-#{waiting}\"", "id=\"attention-#{cut}\"")
      assert before?(html, "id=\"attention-#{paused}\"", "id=\"attention-#{cut}\"")
      refute has_element?(view, "#attention-empty")
    end)
  end

  # DASH-5: an idle chat is not listed, and with nothing waiting the card says
  # so rather than being empty.
  test "the Needs attention card is quiet when nothing needs you", %{conn: conn} do
    with_empty_store(fn ->
      fine = saved_chat("all done")
      task = saved_task_chat(fine, "done")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#attention-empty", "Nothing needs you right now.")
      refute has_element?(view, "#attention-#{fine}")
      refute has_element?(view, "#attention-#{task}")
    end)
  end

  # DASH-5: every blocking chat is listed; interrupted ones are capped.
  test "the interrupted rows are capped, with the rest counted", %{conn: conn} do
    with_empty_store(fn ->
      cut = for i <- 1..7, do: interrupted_chat("run #{i}")
      waiting = saved_chat("waiting on me")
      publish_status(waiting, :awaiting_approval)

      {:ok, view, _html} = live(conn, ~p"/")

      # The blocking one is never capped away.
      assert has_element?(view, "#attention-#{waiting}")
      assert Enum.count(cut, &has_element?(view, "#attention-#{&1}")) == 5
      assert has_element?(view, "#attention-more", "and 2 more")
    end)
  end

  ## Live updates (DASH-5, DASH-8)

  # DASH-5, DASH-8: a chat that starts waiting for approval shows up, and a
  # chat saved after the page opened arrives with its session.
  test "the cards follow the chats live", %{conn: conn} do
    with_empty_store(fn ->
      id = saved_chat("quiet one")

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#attention-#{id}")
      assert has_element?(view, "#recent-status-#{id}[data-status='idle']")

      # SESS-19: the activity broadcast is what a page that is open follows.
      publish_status(id, :awaiting_approval)
      assert has_element?(view, "#attention-#{id}[data-reason='awaiting_approval']")
      assert has_element?(view, "#recent-status-#{id}[data-status='awaiting_approval']")
      assert has_element?(view, "#recent-#{id}", "quiet one")

      # Its session reports it is running, then idle again.
      publish_status(id, :running)
      assert has_element?(view, "#recent-status-#{id}[data-status='working']")
      refute has_element?(view, "#attention-#{id}")

      publish_status(id, :idle)
      assert has_element?(view, "#recent-status-#{id}[data-status='idle']")
      assert has_element?(view, "#attention-empty")

      # UI-72: a chat whose turn a restart cut short stops being flagged once a
      # session for it runs (STORE-31).
      cut = interrupted_chat("run it")
      publish_status(cut, :running)
      assert has_element?(view, "#recent-status-#{cut}[data-status='working']")
      refute has_element?(view, "#recent-#{cut}[data-status='interrupted']")

      # DASH-8: a chat saved after the page opened is listed when its session
      # reports, so a turn that starts brings its chat with it.
      late = saved_chat("late arrival")
      refute has_element?(view, "#recent-#{late}")
      publish_status(late, :running)
      assert has_element?(view, "#recent-#{late}")
      assert has_element?(view, "#recent-status-#{late}[data-status='working']")
    end)
  end

  ## Recent chats (DASH-7)

  # DASH-7: the eight most recently started chats, newest first, and the way to
  # the whole list.
  test "the Recent chats card lists the newest chats and links to the rest", %{conn: conn} do
    with_empty_store(fn ->
      chats = for i <- 1..9, do: saved_chat("chat #{i}")
      oldest = List.first(chats)
      newest = List.last(chats)

      {:ok, view, html} = live(conn, ~p"/")

      assert has_element?(view, "#recent-#{newest}", "chat 9")
      # UI-34: when it was started, relative, with the exact time on hover; and
      # the project it is in (PROJ-24).
      assert has_element?(view, "#recent-time-#{newest}[datetime][title]")
      assert has_element?(view, "#recent-#{newest} span", "Elia")
      assert has_element?(view, "#all-chats[href='/chats']")

      # DASH-7: the newest eight — the oldest of the nine is left to the chat
      # list itself — listed newest first.
      assert has_element?(view, "#recent-#{Enum.at(chats, 1)}")
      refute has_element?(view, "#recent-#{oldest}")
      assert before?(html, "id=\"recent-#{newest}\"", "id=\"recent-#{Enum.at(chats, 1)}\"")
    end)
  end

  # DASH-13: the title has the row to itself — the project and the relative
  # time sit on a muted line below it.
  test "a Recent chats row puts the project and the time below the title", %{conn: conn} do
    with_empty_store(fn ->
      id = saved_chat("a fairly long title")

      {:ok, view, _html} = live(conn, ~p"/")

      # The row's first line is the title alone (so it can use the full width)…
      assert has_element?(
               view,
               "#recent-#{id} a > span:nth-child(2) > span:first-child",
               "a fairly long title"
             )

      # …and the second line carries the project and the time, which are no
      # longer beside the title (DASH-7, UI-34).
      assert has_element?(
               view,
               "#recent-#{id} a > span:nth-child(2) > span:nth-child(2)",
               "Elia"
             )

      assert has_element?(
               view,
               "#recent-#{id} a > span:nth-child(2) > span:nth-child(2) > #recent-time-#{id}[datetime][title]"
             )

      refute has_element?(view, "#recent-#{id} a > #recent-time-#{id}")
    end)
  end

  # DASH-7, UI-45, UI-46: a sub-task chat is listed under its task title, with
  # its task status.
  test "a task chat in the Recent chats card shows its task", %{conn: conn} do
    with_empty_store(fn ->
      parent = saved_chat("the parent chat")
      task = saved_task_chat(parent, "done")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#recent-#{task}", "A task")
      assert has_element?(view, "#recent-status-#{task}[data-status='done']")
      assert has_element?(view, "#recent-#{parent}", "the parent chat")
    end)
  end

  # DASH-7: with no chat at all.
  test "the Recent chats card says there are no chats yet", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#recent-empty", "No chats yet")
      assert has_element?(view, "#all-chats[href='/chats']")
    end)
  end

  ## Projects (DASH-9)

  # DASH-9
  test "the Projects card shows every project with its chats", %{conn: conn} do
    with_empty_store(fn ->
      root = Path.join(Workspace.root(), "dashboard-project")
      File.mkdir_p!(root)
      {:ok, project} = Projects.create("Another one", root)
      on_exit(fn -> File.rm_rf!(root) end)

      # PROJ-9: a chat without a project id belongs to Elia's own project (it is
      # created first, so it is listed whether or not the other one is).
      mine = saved_chat("in Elia's own project")
      theirs = Agent.new_id()
      :ok = Store.save(theirs, [Message.user("in the other project")], project: project.id)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#dash-project-harness", "Elia")
      assert has_element?(view, "#dash-project-chats-harness", "1")
      assert has_element?(view, "#dash-project-#{project.id}", "Another one")
      assert has_element?(view, "#dash-project-#{project.id}", root)
      assert has_element?(view, "#dash-project-chats-#{project.id}", "1")
      assert has_element?(view, "#dash-project-new-#{project.id}[href='/p/#{project.id}/new']")
      assert has_element?(view, "#all-projects[href='/projects']")

      # Deleting the chat leaves the count right on the next render.
      Store.delete(mine)
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#dash-project-chats-harness", "0")
      assert has_element?(view, "#dash-project-chats-#{project.id}", "1")
    end)
  end

  ## System (DASH-10)

  # DASH-10, SYS-2: the numbers the System page shows, refreshed every 2 seconds.
  test "the System card shows the machine and links to the System page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#system-card")
    # SYS-2: one sample is not a rate, so CPU is measuring until the next one.
    assert has_element?(view, "#dash-cpu", "Measuring")
    assert has_element?(view, "#dash-memory", " of ")
    assert has_element?(view, "#dash-load")
    assert has_element?(view, "#dash-vm", "procs")
    assert has_element?(view, "#dash-system-link[href='/system']")

    # DASH-10, SYS-7: the 2-second tick has the percentage the first sample
    # could not know.
    send(view.pid, :stats)
    assert has_element?(view, "#dash-cpu", "%")
    refute has_element?(view, "#dash-cpu", "Measuring")
  end

  # DASH-10, SYS-1: a section whose source is missing reads "Unavailable" while
  # the others still render.
  test "a System section with no source says Unavailable", %{conn: conn} do
    # SystemStats reads /proc; a root with nothing in it is a host without one.
    dir = Path.join(System.tmp_dir!(), "elia-dashboard-proc-#{Agent.new_id()}")
    File.mkdir_p!(dir)
    Application.put_env(:elia, :proc_root, dir)

    on_exit(fn ->
      Application.delete_env(:elia, :proc_root)
      File.rm_rf!(dir)
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#dash-cpu", "Unavailable")
    assert has_element?(view, "#dash-memory", "Unavailable")
    assert has_element?(view, "#dash-load", "Unavailable")
    # The VM's own numbers don't come from procfs, so they are still there.
    assert has_element?(view, "#dash-vm", "procs")
  end

  ## Deploy (DASH-11)

  # DASH-11, DEPLOY-14: a live tree that isn't set up for deployment says why.
  test "the Deploy card explains a tree that can't be deployed", %{conn: conn} do
    # The test workspace is not on the branch `live`.
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#deploy-card")
    assert has_element?(view, "#deploy-error", "not on the branch live")
    assert has_element?(view, "#deploy-settings-link[href='/settings']")
  end

  # DASH-11, DEPLOY-13, DEPLOY-15, DEPLOY-17: what is waiting on the trunk, and
  # an app that never loaded it.
  test "the Deploy card counts what is waiting on the trunk", %{conn: conn} do
    tree = live_tree()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#deploy-ok", "Up to date")
    refute has_element?(view, "#deploy-pending")
    refute has_element?(view, "#deploy-behind")

    # A chat's merge onto the trunk (DEPLOY-13), then the page's own refresh.
    LiveTree.git!(tree, ["checkout", "master"])
    File.write!(Path.join(tree, "lib/trunk_work.ex"), "defmodule TrunkWork do\nend\n")
    LiveTree.commit(tree, "a chat's work")
    LiveTree.git!(tree, ["checkout", "live"])

    send(view.pid, :deploy)
    assert has_element?(view, "#deploy-pending", "1 commit to deploy")
    refute has_element?(view, "#deploy-ok")

    # DEPLOY-15: a deploy that merged and never reached the load.
    path = Deploy.loaded_path(tree)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "0000000000000000000000000000000000000000\n")
    send(view.pid, :deploy)
    assert has_element?(view, "#deploy-behind")

    # Nothing left behind for the next test.
    send(view.pid, :deploy)
    File.rm!(Deploy.loaded_path(tree))
  end

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
end
