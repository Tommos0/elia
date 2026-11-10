defmodule EliaWeb.TerminalLiveTest do
  @moduledoc """
  A chat's terminal page (TERM-19 - TERM-23, TERM-29): how it is reached, what
  it offers a chat without a terminal, what it shows for one, and how it reads
  when that terminal ends.
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

  # TERM-19: the chat page is how the terminal is reached.
  test "the chat page links to its terminal", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-terminal-link[href='/c/#{id}/terminal']")
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

    # TERM-22: the font size is a setting on the page, and it reaches the hook
    # that owns the terminal.
    test "the font size is a setting on the page", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, ~p"/c/#{id}/terminal")

      assert has_element?(view, "#terminal-font-size")

      view |> element("#terminal-font-form") |> render_change(%{"font_size" => "20"})
      assert_push_event(view, "font_size", %{size: 20})
    end
  end

  defp workspace(id) do
    snapshot = Agent.snapshot(id)
    Elia.Deploy.workspace(snapshot.project, id)
  end
end
