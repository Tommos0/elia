defmodule Elia.TerminalTest do
  @moduledoc """
  A chat's terminal (TERM-1 - TERM-17, TERM-26, TERM-29): one session per chat,
  a tmux process tree in the chat's workspace, its output, its screen and how it
  ends.
  """
  use ExUnit.Case, async: false

  alias Elia.{Priority, Terminal}
  alias Elia.Terminal.Session

  # A session runs a real tmux and a real process tree. Where tmux is missing
  # the terminal is unavailable by design (TERM-29), so these are skipped; the
  # ones that need no tmux read the script instead.
  @moduletag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")

  setup do
    id = "terminal-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    dir = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(dir)

    on_exit(fn ->
      stop_session(id)
      File.rm_rf(dir)
    end)

    %{id: id, dir: dir}
  end

  # TERM-7: the script is what the port runs. It brings up tmux in control mode
  # with what a client that has no terminal of its own needs — a pane that
  # outlives its process, so the status and the last screen survive (TERM-4,
  # TERM-23) — and starts the command in that pane rather than as the first
  # process of the session: an app that exits at once would take the session,
  # the status and the screen with it.
  test "the script brings up tmux and runs the command in the pane" do
    script = Session.script("elia-x", ["/bin/sh", "-lc", "htop"], "/usr/bin/tmux")

    assert script =~ "'/usr/bin/tmux' -L 'elia-x' -f /dev/null new-session -d -s elia"
    assert script =~ "set-option -g remain-on-exit on"
    assert script =~ "set-option -g window-size latest"
    assert script =~ "respawn-pane -k -t elia -- '/bin/sh' '-lc' 'htop'"
    assert script =~ "exec '/usr/bin/tmux' -L 'elia-x' -f /dev/null -C attach -t elia"
  end

  # TERM-7, TERM-2: the command and the workspace come from outside the script,
  # so nothing in them may be read as shell syntax. The quoting is checked by
  # the shell that reads it rather than by comparing strings: `sh` splits the
  # words exactly as tmux's own command line will.
  test "the command reaches tmux as one argument, whatever is in it" do
    command = ~s(echo 'a b' "$HOME" \\ ; echo `date` ; exit 3)
    script = Session.script("elia-x", ["/bin/sh", "-lc", command], "/usr/bin/tmux")

    words =
      script
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "respawn-pane"))
      |> String.split(" -- ", parts: 2)
      |> List.last()

    assert {output, 0} = System.cmd("sh", ["-c", "set -- #{words}; printf '%s|' \"$@\""])
    assert output == "/bin/sh|-lc|#{command}|"
  end

  # TERM-5: with no command the session runs the user's login shell, which is
  # what a plain terminal is.
  test "the default command is the user's login shell" do
    [shell, "-l"] = Terminal.command_argv()
    assert File.regular?(shell)
    assert Terminal.command_argv("htop") == [shell, "-lc", "htop"]
  end

  # TERM-1, TERM-2: the chat's own session, in the workspace it was given, and
  # one of it at a time.
  test "a chat has one running session, in the workspace it was given", %{id: id, dir: dir} do
    assert {:ok, pid} = Terminal.start(id, command: "sleep 30", workspace: dir, jail: false)

    assert {:ok, status} = Terminal.status(id)
    assert status.running
    assert status.workspace == dir
    assert status.command =~ "sleep 30"
    assert status.jail == false

    assert {:ok, ^pid} = Terminal.fetch(id)
    assert Terminal.running_count() >= 1

    assert {:error, message} = Terminal.start(id, workspace: dir, jail: false)
    assert message =~ "already has a running terminal"
  end

  # TERM-4, TERM-23: the app's exit status is what the session records.
  # TERM-1: a session whose command has exited is not running, so the next start
  # replaces it.
  test "a session whose command has exited is replaced by the next one", %{id: id, dir: dir} do
    :ok = Terminal.subscribe_status(id)
    assert {:ok, _} = Terminal.start(id, command: "exit 3", workspace: dir, jail: false)

    assert_receive {:terminal_status, ^id, %{ended: :exited, running: false, exit_status: 3}},
                   15_000

    assert {:ok, _pid} = Terminal.start(id, command: "sleep 30", workspace: dir, jail: false)
    assert {:ok, %{running: true}} = Terminal.status(id)
  end

  # TERM-3: stopping kills the whole tree — the app's own process goes, not just
  # the shell that started it — and the screen it was showing is kept, so a page
  # can still show what the terminal was showing.
  test "stopping kills the whole tree and keeps the screen", %{id: id, dir: dir} do
    pidfile = Path.join(dir, "app.pid")

    assert {:ok, _} =
             Terminal.start(id,
               command: "echo $$ > #{pidfile}; printf 'bye now\\n'; sleep 60",
               workspace: dir,
               jail: false
             )

    :ok = Terminal.subscribe(id)
    assert_receive {:terminal_screen, _screen}, 15_000

    app_pid = wait_for_pid(pidfile)
    assert app_running?(app_pid)

    assert {:ok, status} = Terminal.stop(id)
    assert status.ended == :stopped
    refute status.running

    assert eventually_gone?(app_pid)
    assert {:ok, screen} = Terminal.read(id)
    assert screen =~ "bye now"
  end

  # TERM-12, TERM-13: what the app writes reaches a subscriber, and what is
  # typed goes into the app's stdin — into a shell that is reading, so the
  # program's answer comes back.
  test "output reaches a subscriber and what is typed reaches the app", %{id: id, dir: dir} do
    assert {:ok, _} = Terminal.start(id, workspace: dir, jail: false)
    :ok = Terminal.subscribe(id)

    # TERM-14: a joining client is sent the screen it has now, before any output.
    assert_receive {:terminal_screen, _screen}, 15_000

    :ok = Terminal.input(id, "echo typed-$((6*7))\r")
    assert collect_until("typed-42") =~ "typed-42"
  end

  # TERM-14, TERM-26: what the terminal shows, for a reader rather than for a
  # terminal — the screen it has now, with no attributes in it.
  test "the terminal's screen can be read as plain text", %{id: id, dir: dir} do
    assert {:ok, _} =
             Terminal.start(id,
               command: "printf 'first thing\\n'; sleep 60",
               workspace: dir,
               jail: false
             )

    :ok = Terminal.subscribe(id)
    assert collect_until("first thing") =~ "first thing"

    assert {:ok, screen} = Terminal.read(id)
    assert screen =~ "first thing"
    refute screen =~ "\e["
  end

  # TERM-15: the app's pty takes the size the browser can draw.
  test "the app's pty is the size the client has", %{id: id, dir: dir} do
    assert {:ok, _} = Terminal.start(id, workspace: dir, jail: false)

    :ok = Terminal.subscribe(id)
    assert_receive {:terminal_screen, _screen}, 15_000

    :ok = Terminal.resize(id, 40, 12)
    :ok = Terminal.input(id, "stty size\r")

    assert collect_until("12 40") =~ "12 40"
  end

  # TERM-8, PRIO-2: the session's tree is started with the same priority wrapper a
  # command gets (PRIO-1, PRIO-3), so a terminal can't take the machine from the
  # UI either. The app reads its own niceness out of its process table.
  test "the session's tree runs below the server's priority", %{id: id, dir: dir} do
    nice = Priority.settings()[:nice]

    if is_integer(nice) and nice > 0 do
      assert {:ok, _} =
               Terminal.start(id,
                 command: "cut -d' ' -f19 /proc/self/stat; sleep 60",
                 workspace: dir,
                 jail: false
               )

      assert read_number(id) >= nice
    end
  end

  # TERM-17: a client that falls too far behind is dropped and told, rather than
  # the session holding its backlog in memory. This test is the slow client: it
  # never takes the output out of its mailbox.
  test "a client that falls too far behind is dropped and told", %{id: id, dir: dir} do
    previous = Application.get_env(:elia, Terminal)
    Application.put_env(:elia, Terminal, max_pending: 20)
    on_exit(fn -> Application.put_env(:elia, Terminal, previous) end)

    assert {:ok, _} =
             Terminal.start(id,
               command: "while :; do echo flood; done",
               workspace: dir,
               jail: false
             )

    :ok = Terminal.subscribe(id)
    assert_receive {:terminal_overflow, :dropped}, 15_000
  end

  # TERM-26, TERM-20: a chat with no terminal says so instead of failing.
  test "reading a terminal a chat does not have is an error that says so" do
    assert {:error, message} = Terminal.read("no-such-chat")
    assert message =~ "no terminal"
    assert Terminal.status("no-such-chat") == :error
  end

  # TERM-29: where tmux is missing the terminal is unavailable, and what is
  # missing is said rather than started and failing later.
  test "without tmux the terminal is unavailable", %{id: id, dir: dir} do
    previous = Application.get_env(:elia, Terminal)
    Application.put_env(:elia, Terminal, tmux: "/nonexistent/tmux")
    on_exit(fn -> Application.put_env(:elia, Terminal, previous) end)

    refute Terminal.available?()
    assert {:error, message} = Terminal.start(id, workspace: dir, jail: false)
    assert message =~ "no tmux"
    assert Terminal.unavailable_message() =~ "apt install tmux"
  end

  # TERM-30, TERM-31: what is sent reaches the app's stdin the way a keyboard
  # would send it — text as its own bytes, and a name handed to tmux to expand
  # rather than bytes guessed here.
  test "keys reach the app as the bytes a keyboard sends", %{id: id, dir: dir} do
    assert {:ok, _} =
             Terminal.start(id,
               command: "stty raw -echo; : > ready; cat > typed",
               workspace: dir,
               jail: false
             )

    wait_for_file(Path.join(dir, "ready"))

    assert {:ok, segments} = Terminal.keys(id, "ab<Up><C-x><Enter>")
    assert segments == [{:text, "ab"}, {:key, "Up"}, {:key, "C-x"}, {:key, "Enter"}]

    assert typed_bytes(Path.join(dir, "typed"), "ab\e[A\x18\r") == "ab\e[A\x18\r"
  end

  # TERM-31: the reason a name goes to tmux instead of bytes being mapped here:
  # this app turned on application cursor keys (`ESC [ ? 1 h`), so `<Up>` has to
  # arrive as `ESC O A` where the plain app above gets `ESC [ A`.
  test "a name is expanded for the mode the app has set", %{id: id, dir: dir} do
    assert {:ok, _} =
             Terminal.start(id,
               command: "printf '\\033[?1h'; stty raw -echo; : > ready; cat > typed",
               workspace: dir,
               jail: false
             )

    wait_for_file(Path.join(dir, "ready"))

    assert {:ok, _segments} = Terminal.keys(id, "<Up>")
    assert typed_bytes(Path.join(dir, "typed"), "\eOA") == "\eOA"
  end

  # TERM-34: a send to a chat with no terminal says so rather than typing into
  # nothing; the session that has ended is the next test.
  test "sending to a chat with no terminal is an error that says so" do
    assert {:error, message} = Terminal.keys("no-such-chat", "x")
    assert message =~ "no terminal"
  end

  # TERM-34: a session that has ended is never typed into.
  test "sending to a session that has ended is refused", %{id: id, dir: dir} do
    :ok = Terminal.subscribe_status(id)
    assert {:ok, _} = Terminal.start(id, command: "exit 7", workspace: dir, jail: false)

    assert_receive {:terminal_status, ^id, %{running: false}}, 15_000

    assert {:error, message} = Terminal.keys(id, "x")
    assert message =~ "ended"
  end

  ## Helpers

  defp stop_session(id) do
    case Terminal.fetch(id) do
      {:ok, pid} ->
        Terminal.stop(id)
        DynamicSupervisor.terminate_child(Terminal.supervisor(), pid)

      :error ->
        :ok
    end
  end

  # Output arrives in chunks and a typed line is echoed before the program's
  # answer to it, so what a test waits for is the content it asked for rather
  # than the next message to arrive.
  defp collect_until(needle, collected \\ "", deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    if needle != "" and String.contains?(collected, needle) do
      collected
    else
      receive do
        {:terminal_output, output} -> collect_until(needle, collected <> output, deadline)
        {:terminal_screen, screen} -> collect_until(needle, collected <> screen, deadline)
      after
        remaining(deadline) ->
          flunk("no output containing #{inspect(needle)}, saw #{inspect(collected)}")
      end
    end
  end

  # TERM-8's app writes a number to the screen; the echo of the command line is
  # a line with more than the number on it, so a line that is only a number is
  # the answer.
  defp read_number(id, tries \\ 100)

  defp read_number(id, tries) do
    assert {:ok, screen} = Terminal.read(id)

    case Regex.run(~r/^\s*(\d+)\s*$/m, screen) do
      [_, number] ->
        String.to_integer(number)

      nil ->
        if tries == 0, do: flunk("no number on the screen: #{inspect(screen)}")
        Process.sleep(50)
        read_number(id, tries - 1)
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp wait_for_pid(path, tries \\ 200)
  defp wait_for_pid(_path, 0), do: flunk("the app never wrote its pid")

  defp wait_for_pid(path, tries) do
    case File.read(path) do
      {:ok, text} ->
        String.trim(text)

      {:error, _} ->
        Process.sleep(10)
        wait_for_pid(path, tries - 1)
    end
  end

  # TERM-30: the app of a send test is ready when it has said so — a pane that
  # has not put its pty in raw mode yet would buffer what is typed.
  defp wait_for_file(path, tries \\ 200)
  defp wait_for_file(path, 0), do: flunk("the app never wrote #{path}")

  defp wait_for_file(path, tries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      wait_for_file(path, tries - 1)
    end
  end

  # The bytes the app has been sent, once they have arrived: a send returns when
  # tmux has been told, and the app writes them when it reads them. What is
  # there when the wait runs out is returned, so a failure shows what arrived.
  defp typed_bytes(path, expected, tries \\ 300)

  defp typed_bytes(path, _expected, 0), do: File.read!(path)

  defp typed_bytes(path, expected, tries) do
    if File.read(path) == {:ok, expected} do
      expected
    else
      Process.sleep(10)
      typed_bytes(path, expected, tries - 1)
    end
  end

  defp app_running?(pid), do: File.exists?("/proc/#{pid}")

  defp eventually_gone?(pid, tries \\ 200)
  defp eventually_gone?(_pid, 0), do: false

  defp eventually_gone?(pid, tries) do
    if app_running?(pid) do
      Process.sleep(10)
      eventually_gone?(pid, tries - 1)
    else
      true
    end
  end
end
