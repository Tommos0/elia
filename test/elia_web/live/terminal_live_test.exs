defmodule EliaWeb.TerminalLiveTest do
  @moduledoc """
  A chat's terminal page (TERM-19 - TERM-23, TERM-29): how it is reached, what
  it offers a chat without a terminal, what it shows for one, how it reads when
  that terminal ends, and the jail it says and starts with (TERM-37 - TERM-39).
  """
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Terminal}

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    # TERM-3: deleting a chat stops its terminal, which is what a leaked session
    # needs to not leave a process tree behind for the next test.
    on_exit(fn -> Agent.delete(id) end)
    %{id: id}
  end

  # TERM-19, UI-97: the chat page is how the terminal is reached — from the
  # composer's chat menu, which holds its link.
  test "the chat page links to its terminal", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    refute has_element?(view, "#chat-terminal-link")

    view |> element("#chat-menu-button") |> render_click()

    assert has_element?(view, "#chat-menu #chat-terminal-link[href='/c/#{id}/terminal']")
  end

  # TERM-29: where tmux is missing the page says what is missing rather than
  # offering a terminal that can't start. It needs no tmux, so it runs
  # everywhere.
  test "without tmux the page says what is missing", %{conn: conn, id: id} do
    previous = Application.get_env(:elia, Terminal)
    Application.put_env(:elia, Terminal, tmux: "/nonexistent/tmux")
    on_exit(fn -> Application.put_env(:elia, Terminal, previous) end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

    assert has_element?(view, "#terminal-unavailable")
    refute has_element?(view, "#terminal-form")
  end

  describe "a chat's terminal" do
    # These start a real tmux session: skipped where there is none (TERM-29).
    @describetag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")

    # TERM-19, TERM-20: a chat with no terminal offers one, with the command to
    # run, the workspace it runs in and a status that appears once it has one.
    test "the page offers a terminal, and says where it would run", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      assert has_element?(view, "#terminal-empty")
      assert has_element?(view, "#terminal-form")
      assert has_element?(view, "#terminal-command")
      assert has_element?(view, "#terminal-start", "Start")
      assert has_element?(view, "#terminal-workspace")
      refute has_element?(view, "#terminal-stop")

      # The terminal itself is the hook's element, and exists only for a
      # session.
      refute has_element?(view, "#terminal")
    end

    # TERM-20, TERM-21, TERM-23: starting shows the terminal — the element the
    # hook draws in, filling the page — with a status and a way to stop it;
    # stopping keeps the screen, says how it ended, and offers the next one.
    test "starting shows the terminal, stopping says how it ended", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      view
      |> form("#terminal-form", terminal: %{command: "printf 'page terminal\\n'; sleep 60"})
      |> render_submit()

      assert has_element?(view, "#terminal")
      assert has_element?(view, "#terminal-pane")
      assert has_element?(view, "#terminal-status", "running")
      assert has_element?(view, "#terminal-stop")
      refute has_element?(view, "#terminal-empty")

      view |> element("#terminal-stop") |> render_click()

      assert has_element?(view, "#terminal-status", "stopped")
      assert has_element?(view, "#terminal")
      assert has_element?(view, "#terminal-start", "Start again")
    end

    # TERM-42, TERM-47, TERM-48: the bar is offered with a running session and
    # not before one, as a row of its own after the terminal's pane, so the pane
    # is fitted to what is left of the page rather than the bar covering its last
    # rows.
    test "the key bar is offered with a running session", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      refute has_element?(view, "#terminal-keys")
      refute has_element?(view, "#terminal-keys-toggle")

      view
      |> form("#terminal-form", terminal: %{command: "sleep 60"})
      |> render_submit()

      assert has_element?(view, "#terminal-keys[role='toolbar']")
      assert has_element?(view, "#terminal-keys-toggle[aria-pressed='false']")

      # TERM-42: the keys a soft keyboard has not got.
      for key <- ["Esc", "Tab", "C-c", "C-d"] do
        assert has_element?(view, "#terminal-keys [data-key='#{key}']")
      end

      # TERM-46: the arrows are the keys that repeat while they are held.
      for key <- ["Left", "Up", "Down", "Right"] do
        assert has_element?(view, "#terminal-keys [data-key='#{key}'][data-repeat]")
      end

      # TERM-44, TERM-45: the modifiers are the hook's to arm, so they arrive off.
      for modifier <- ["C-", "M-"] do
        assert has_element?(
                 view,
                 "#terminal-keys [data-modifier='#{modifier}'][data-state='off']"
               )
      end

      # TERM-47: the bar's row is after the pane in the page, not over it.
      assert render(view) =~ ~r/id="terminal-pane".*id="terminal-keys"/s
    end

    # TERM-1: a chat's terminal is one, and what the page knows is the session's
    # own state rather than what it last rendered.
    test "a chat that already has a terminal shows it", %{conn: conn, id: id} do
      {:ok, _session} = Agent.ensure_started(id)

      {:ok, _pid} = Terminal.start(id, command: "sleep 60", workspace: workspace(id), jail: false)

      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      assert has_element?(view, "#terminal")
      assert has_element?(view, "#terminal-status", "running")
      assert has_element?(view, "#terminal-stop")
      refute has_element?(view, "#terminal-empty")
    end

    # TERM-22: the font size is a setting on the page — 9 to open with, and
    # sizes below it a small screen can trade columns for — and it reaches the
    # hook that owns the terminal.
    test "the font size is a setting on the page", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      assert has_element?(view, "#terminal-font-size")
      assert has_element?(view, "#terminal-font-size option[value='9'][selected]")

      # The smaller sizes a phone wants are there, down to 5.
      for size <- [5, 6, 7, 8] do
        assert has_element?(view, "#terminal-font-size option[value='#{size}']")
      end

      view |> element("#terminal-font-form") |> render_change(%{"font_size" => "20"})
      assert_push_event(view, "font_size", %{size: 20})

      view |> element("#terminal-font-form") |> render_change(%{"font_size" => "5"})
      assert_push_event(view, "font_size", %{size: 5})

      # A size the page does not offer is the default, not whatever arrived.
      view |> element("#terminal-font-form") |> render_change(%{"font_size" => "99"})
      assert_push_event(view, "font_size", %{size: 9})
    end

    # TERM-37, TERM-38: the jail is the chat's setting as it is, not the one
    # this page read when it opened. A change made elsewhere — here through the
    # session the chat page uses (CSET-4, SESS-30) — reaches both the line and a
    # Start on a page that was already open.
    test "the jail a page says and starts with follows the chat's setting", %{
      conn: conn,
      id: id
    } do
      with_host_jail(fn ->
        {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")
        refute has_element?(view, "#terminal-jail-warning")

        # Turned off with this page open.
        :ok = Agent.set_jail(id, false)

        # TERM-38: the page follows it, without a reload.
        render(view)
        assert has_element?(view, "#terminal-jail-warning", "credentials")

        view
        |> form("#terminal-form", terminal: %{command: "sleep 60"})
        |> render_submit()

        # TERM-37: the session started with the setting as it is now, not the
        # one the page read when it opened.
        assert {:ok, status} = Terminal.status(id)
        assert status.jail == false
        refute status.jailed
      end)
    end

    # TERM-39: the line is about the terminal the page is showing — the
    # confinement it was actually started with — and the chat's setting is said
    # separately, as what the next one will use (ISOL-19).
    test "the page says a session's own confinement, and the setting separately", %{
      conn: conn,
      id: id
    } do
      with_host_jail(fn ->
        {:ok, _session} = Agent.ensure_started(id)

        {:ok, _pid} =
          Terminal.start(id, command: "sleep 60", workspace: workspace(id), jail: false)

        {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

        # The chat's setting is on; the terminal on the page is not jailed, and
        # the page says that rather than the setting — and says what the next
        # one will use, because the setting has moved since it started.
        assert has_element?(view, "#terminal-jail-warning", "credentials")
        assert has_element?(view, "#terminal-jail-next", "will be jailed")
      end)
    end

    # TERM-39, ISOL-19: the other way round — a session that did start jailed
    # keeps the confinement it was started with while the chat's setting goes
    # off, and the page says the setting as the next terminal's.
    test "a jailed session stays jailed while the chat's setting goes off", %{
      conn: conn,
      id: id
    } do
      with_host_jail(fn ->
        {:ok, _session} = Agent.ensure_started(id)

        {:ok, _pid} =
          Terminal.start(id, command: "sleep 60", workspace: workspace(id), jail: true)

        assert {:ok, %{jailed: true}} = Terminal.status(id)

        {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")
        refute has_element?(view, "#terminal-jail-warning")
        refute has_element?(view, "#terminal-jail-next")

        :ok = Agent.set_jail(id, false)
        render(view)

        refute has_element?(view, "#terminal-jail-warning")
        assert has_element?(view, "#terminal-jail-next", "will run unjailed")
      end)
    end

    # TERM-9, ISOL-12, ISOL-20: a host with no jail at all is a different
    # sentence from a chat that turned it off, and no chat's setting can turn
    # one on there.
    test "a host with no jail says so, whatever the chat's setting", %{conn: conn, id: id} do
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      assert has_element?(view, "#terminal-no-jail")
      refute has_element?(view, "#terminal-jail-warning")
      refute has_element?(view, "#terminal-jail-next")
    end
  end

  # TERM-37 to TERM-39: a page that says whether the jail is on needs a host
  # that has one — the suite's own config turns it off (ISOL-20) — and needs
  # bubblewrap to build it (ISOL-12), which is what these tests skip without.
  defp with_host_jail(fun) do
    if Elia.Shell.available?() do
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true)
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
      fun.()
    end
  end

  defp workspace(id) do
    # DEPLOY-1, PROJ-12: the chat's workspace root is its project's folder.
    Agent.snapshot(id).project.folder
  end
end
