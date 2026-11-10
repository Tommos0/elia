defmodule EliaWeb.TerminalChannelTest do
  @moduledoc """
  The stream between a chat's terminal and one browser client (TERM-12 -
  TERM-17): the screen a join is answered with, the output that follows, what is
  typed, the size of the client's box, and a client that falls behind.
  """
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Elia.Terminal

  @endpoint EliaWeb.Endpoint

  @moduletag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")

  setup do
    id = "terminal-channel-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    dir = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(dir)

    on_exit(fn ->
      case Terminal.fetch(id) do
        {:ok, pid} ->
          Terminal.stop(id)
          DynamicSupervisor.terminate_child(Terminal.supervisor(), pid)

        :error ->
          :ok
      end

      File.rm_rf(dir)
    end)

    %{id: id, dir: dir}
  end

  # TERM-12: a chat with no terminal has nothing to stream.
  test "joining a chat with no terminal is refused", %{id: id} do
    assert {:error, %{reason: "no_terminal"}} =
             subscribe_and_join(terminal_socket(), "terminal:#{id}")
  end

  # TERM-12, TERM-14: a join is answered with the screen the session has now, so
  # a reload or a reconnect shows the app as it is rather than an empty
  # terminal.
  test "a join is answered with the screen the session has now", %{id: id, dir: dir} do
    start(id, dir, "printf 'hello channel\\n'; sleep 60")
    assert_app_wrote(id, "hello channel")

    assert {:ok, reply, _socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert reply.running
    assert reply.workspace == dir

    assert collect_push("hello channel") =~ "hello channel"
  end

  # TERM-13: what the user types goes to the app, and what the app answers comes
  # back over the channel — bytes both ways, in base64.
  test "what is typed reaches the app, and its answer comes back", %{id: id, dir: dir} do
    # The chat's own shell, which is reading: an app busy with something else
    # never takes the input at all.
    {:ok, _pid} = Terminal.start(id, workspace: dir, jail: false)

    assert {:ok, _reply, socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    push(socket, "input", %{data: Base.encode64("echo typed-$((2+2))\r")})
    assert collect_push("typed-4") =~ "typed-4"
  end

  # TERM-15: the client says how big its box is, and that is the app's pty.
  test "the client's size is the app's size", %{id: id, dir: dir} do
    {:ok, _pid} = Terminal.start(id, workspace: dir, jail: false)

    assert {:ok, _reply, socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    push(socket, "resize", %{cols: 40, rows: 12})
    push(socket, "input", %{data: Base.encode64("stty size\r")})

    assert collect_push("12 40") =~ "12 40"
    assert {:ok, %{cols: 40, rows: 12}} = Terminal.status(id)
  end

  # TERM-23: how the terminal is doing is pushed too, so a page can say that a
  # terminal's command has ended rather than leaving it looking quiet.
  test "the end of a session is pushed with how it ended", %{id: id, dir: dir} do
    start(id, dir, "exit 4")

    assert {:ok, _reply, _socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    assert_push "status", %{ended: :exited, running: false, exit_status: 4}, 15_000
  end

  # TERM-18: a join for a session that has already ended is answered with what
  # ended it and the screen it left, rather than a stream that never starts.
  test "a join for a session that has ended gets its status and its last screen", %{
    id: id,
    dir: dir
  } do
    start(id, dir, "printf 'last words\\n'; sleep 0.2")
    # Wait for the app to have written and then ended (TERM-4).
    assert_app_wrote(id, "last words")
    assert_receive {:terminal_status, %{ended: :exited}}, 15_000

    assert {:ok, reply, _socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    refute reply.running
    assert reply.ended == :exited

    assert collect_push("last words") =~ "last words"
  end

  # TERM-16: a session is the chat's, not the tab's. Both clients are sent the
  # stream, and what either types reaches the command. A channel's pushes are
  # told apart by its `join_ref`, so "both were sent it" is asserted per client
  # rather than as two messages from anywhere.
  test "two clients watch one session and either can type into it", %{id: id, dir: dir} do
    {:ok, _pid} = Terminal.start(id, workspace: dir, jail: false)

    assert {:ok, _reply, first} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    assert {:ok, _reply, second} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    # The second tab types it, and both tabs are sent what came back: the
    # command's output is asked for, not its echo, which the pty sends whether
    # or not anything runs it.
    push(second, "input", %{data: Base.encode64("printf 'BT-%s\\n' $((6*7))\r")})

    assert collect_push("BT-42", second.join_ref) =~ "BT-42"
    assert collect_push("BT-42", first.join_ref) =~ "BT-42"

    # And the other tab can type into the same session.
    push(first, "input", %{data: Base.encode64("printf 'FT-%s\\n' $((6*8))\r")})
    assert collect_push("FT-48", second.join_ref) =~ "FT-48"
  end

  # TERM-17: a client that falls too far behind is told so and dropped, rather
  # than the session holding its backlog in memory for it. The channel here is
  # the slow client: nothing takes its pushes out of the mailbox.
  test "a client that falls behind is told and dropped", %{id: id, dir: dir} do
    previous = Application.get_env(:elia, Terminal)
    Application.put_env(:elia, Terminal, max_pending: 5)
    on_exit(fn -> Application.put_env(:elia, Terminal, previous) end)

    start(id, dir, "while :; do echo flood; done")

    assert {:ok, _reply, _socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")

    assert_push "overflow", %{message: message}, 15_000
    assert message =~ "outran"
  end

  # TERM-12: a terminal is a chat's, and a session that goes away takes the
  # channel with it (TERM-3) rather than leaving it streaming from nothing.
  test "a terminal that goes away stops the channel", %{id: id, dir: dir} do
    start(id, dir, "sleep 60")

    assert {:ok, _reply, _socket} = subscribe_and_join(terminal_socket(), "terminal:#{id}")
    assert_push "screen", _screen, 15_000

    {:ok, pid} = Terminal.fetch(id)
    DynamicSupervisor.terminate_child(Terminal.supervisor(), pid)

    assert_push "status", %{running: false}, 15_000
  end

  ## Helpers

  # TERM-12: the socket a terminal streams over, which is not the LiveView's.
  defp terminal_socket, do: socket(EliaWeb.TerminalSocket)

  defp start(id, dir, command) do
    {:ok, _pid} = Terminal.start(id, command: command, workspace: dir, jail: false)
  end

  # A session is asked for its screen before the channel joins, so what the join
  # is answered with is not a race: the test process subscribes as a client of
  # its own (TERM-12) and waits for the app to have written. The screen may
  # already hold the line the test is after — the capture races with the write —
  # so it is collected as well as the output that follows it.
  defp assert_app_wrote(id, needle) do
    :ok = Terminal.subscribe(id)
    assert_receive {:terminal_screen, screen}, 15_000
    collect_session(needle, screen)
  end

  defp collect_session(needle, collected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    if String.contains?(collected, needle) do
      collected
    else
      receive do
        {:terminal_output, output} ->
          collect_session(needle, collected <> output, deadline)

        {:terminal_screen, screen} ->
          collect_session(needle, collected <> screen, deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("the app never wrote #{inspect(needle)}")
      end
    end
  end

  # What the channel pushed: the only thing a browser sees, so a test about the
  # channel reads these and nothing else. With a `join_ref` it reads one
  # client's pushes, which is how two tabs are told apart (TERM-16).
  defp collect_push(needle, join_ref \\ nil, collected \\ "", deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    if String.contains?(collected, needle) do
      collected
    else
      receive do
        %Phoenix.Socket.Message{event: event, payload: %{data: data}, join_ref: ref}
        when event in ["screen", "output"] and (is_nil(join_ref) or join_ref == ref) ->
          collect_push(needle, join_ref, collected <> Base.decode64!(data), deadline)
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("the channel never pushed #{inspect(needle)}, saw #{inspect(collected)}")
      end
    end
  end
end
