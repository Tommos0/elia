defmodule Elia.Terminal.Session do
  @moduledoc """
  One chat's terminal (TERM-1): a tmux server, a control-mode client and the
  command the user asked for, in one jailed and niced process tree (TERM-7,
  TERM-8).

  tmux is here for the pty. The BEAM has none, and a plain port gives a child no
  line discipline, no window size and no `SIGWINCH`, so a full-screen app drawn
  through one is wrong from the first redraw. Control mode is what makes tmux
  usable from a port with no terminal of its own: the client reads commands on
  stdin — `send-keys` for what the user or the agent types (TERM-13, TERM-30), `refresh-client -C` for
  the size (TERM-15), `capture-pane` for the screen (TERM-14, TERM-26) — and
  writes notifications on stdout: `%output %<pane> <bytes>` for the app's output
  (TERM-12) and `%subscription-changed` for the one thing tmux must say
  unprompted, that the app's process has ended and with what status (TERM-4).

  Every command sent gets exactly one reply back — a `%begin`/`%end` block, or
  `%error` — in the order the commands were sent, so a reply is matched to its
  command by that order and handed to whoever asked for it: a browser joining
  (TERM-14), `terminal_read` (TERM-26), or the final capture that keeps the
  screen of a session that has ended (TERM-23).

  The tree is killed as a whole when the session stops (TERM-3): the kill is the
  one a timed-out command gets, so with the jail on the pid namespace goes with
  it (ISOL-10). Nothing of a stopped session is left running, and the session
  process stays on to answer for it — what it ran, how it ended, and the screen
  it was showing.

  The whole thing runs inside one jail: the tmux server's socket lives in the
  jail's own `/tmp`, so the server and this client are the only two processes
  that can ever see each other, and a new session can never attach to a
  previous one's server.
  """

  use GenServer

  require Logger

  alias Elia.{Shell, Terminal}

  # The size a session starts at, before a browser says what it has (TERM-15).
  @initial_cols 80
  @initial_rows 24

  # How many bytes of input go into one `send-keys` (TERM-13): a paste is split
  # so no single command line gets long enough to be refused.
  @input_chunk 512

  # TERM-17: the fallback for how much output may be waiting for one client
  # before it is dropped and told so, rather than the session holding its
  # backlog in memory (config `max_pending`).
  @max_pending 1_000

  # The format tmux evaluates and reports a change of (TERM-4): empty while the
  # pane is alive, the command's exit status once it has ended. tmux expands it,
  # so the `#` is escaped here — this string goes to tmux as it is.
  @dead_status_format "\#{pane_dead_status}"

  # TERM-36: the line the script prints its server's socket path on, before the
  # client attaches and control mode begins.
  @socket_path_marker "elia-socket-path "

  # TERM-36: how long ending the server may take. It runs inside `terminate/2`,
  # where the session is on its way out: the run is awaited there, so SHELL-12's
  # watcher never sees its waiting process go first, and it has to finish well
  # inside the supervisor's shutdown window (5 s for a worker), after which the
  # session is killed outright and the run's group with it. `kill-server` on a
  # local socket answers in milliseconds; 2 s leaves the rest of that window to
  # spare.
  @release_timeout 2_000

  defstruct [
    :chat_id,
    :argv,
    :command,
    :workspace,
    :jail,
    :socket,
    # TERM-36: where the server's socket file is, as tmux reported it at start;
    # nil until then, and for a jailed session it is the jail's own `/tmp`.
    :socket_path,
    # TERM-36: whether the session really runs in a jail — the chat's setting,
    # the host's and bubblewrap's presence together (ISOL-12, ISOL-16), decided
    # once, as the argv was built — rather than only what the chat asked for.
    :jailed,
    # NET-18: what `Elia.Net.prepare/1` built for this session, if anything, so
    # its proxy is ended with it (NET-21).
    :net,
    :port,
    :cols,
    :rows,
    :status,
    :ended,
    :exit_status,
    :screen,
    :started_at,
    :reply,
    partial: "",
    stderr: "",
    subscribed: false,
    pending: :queue.new(),
    subscribers: %{},
    joining: MapSet.new()
  ]

  ## API

  @doc "The registry name a chat's session is registered under (TERM-1)."
  def via(chat_id), do: {:via, Registry, {Terminal.registry(), chat_id}}

  @doc "Starts a session. See `Elia.Terminal.start/2`."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts[:chat_id]))

  @doc "How the session is doing (TERM-23)."
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Whether the session's command is still running (TERM-1)."
  def running?(pid), do: GenServer.call(pid, :running?)

  @doc "The session's screen as plain text (TERM-26)."
  def read(pid), do: GenServer.call(pid, :read, 15_000)

  @doc "Sends bytes to the app as if typed (TERM-13)."
  def input(pid, bytes), do: GenServer.call(pid, {:input, bytes})

  @doc """
  Sends what `Elia.Terminal.Keys.parse/1` made of a notation: text as bytes and
  a named key by name, in order (TERM-30).
  """
  def keys(pid, segments), do: GenServer.call(pid, {:keys, segments})

  @doc "Resizes the app's pty (TERM-15)."
  def resize(pid, cols, rows), do: GenServer.call(pid, {:resize, cols, rows})

  @doc "Kills the session's tree and keeps what it was showing (TERM-3)."
  def stop(pid), do: GenServer.call(pid, :stop, 15_000)

  @doc "Subscribes `pid` to this session's output (TERM-12)."
  def subscribe(session, pid \\ self()), do: GenServer.call(session, {:subscribe, pid})

  # The script that brings the session up, as the shell runs it (TERM-7).
  #
  # A holding `sleep` becomes the first pane, so the session exists before the
  # options are set and before the app is put in it: an app that exits at once
  # (`bash -lc true`) would otherwise take its window — and the session — with it
  # before `remain-on-exit` could keep it, and with it the exit status and the
  # screen of TERM-4 and TERM-23. `respawn-pane` then replaces the holding
  # process with the app, in the same pty.
  @doc false
  def script(socket, argv, tmux) do
    tmux = q(tmux)
    sock = q(socket)

    [
      "set -e",
      "#{tmux} -L #{sock} -f /dev/null new-session -d -s elia -x #{@initial_cols} -y #{@initial_rows} -- sleep 3600",
      # TERM-36: where the server's socket is, said as soon as the server is
      # up — before anything else can fail and before the client attaches — so
      # the session knows the one file to remove however it ends. tmux leaves
      # the file in place even when its server exits cleanly.
      "#{tmux} -L #{sock} -f /dev/null display-message -p -t elia '#{@socket_path_marker}\#{socket_path}'",
      # TERM-4, TERM-23: the pane stays after its process ends, so tmux can say
      # the status and still show the screen it was showing.
      "#{tmux} -L #{sock} -f /dev/null set-option -g remain-on-exit on",
      # What the app is told it is talking to, and what the browser draws.
      "#{tmux} -L #{sock} -f /dev/null set-option -g default-terminal tmux-256color",
      # TERM-15: with several clients (TERM-16) the window follows the one that
      # resized last, which is tmux's own answer to "whose size is it anyway".
      "#{tmux} -L #{sock} -f /dev/null set-option -g window-size latest",
      # No status line: the page is the only client UI there is.
      "#{tmux} -L #{sock} -f /dev/null set-option -g status off",
      "#{tmux} -L #{sock} -f /dev/null set-option -g history-limit #{Terminal.config(:scrollback_lines)}",
      # TERM-3: nothing outlives the session, however it ends. The tmux server
      # daemonises out of the process group the kill reaches (it is not a child
      # of the script, so a group kill left it — and the app in its pane —
      # running), so the session is destroyed when the client it belongs to
      # goes. It is set once this client is attached rather than here: the
      # option takes effect at once, and a session that has no client yet is
      # exactly what it destroys.
      "#{tmux} -L #{sock} -f /dev/null set-option -g mouse on",
      "#{tmux} -L #{sock} -f /dev/null respawn-pane -k -t elia -- #{Enum.map_join(argv, " ", &q/1)}",
      "exec #{tmux} -L #{sock} -f /dev/null -C attach -t elia"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # A single-quoted word for the shell that runs the script (SHELL-2): the
  # workspace, the socket name and the command come from outside, so nothing in
  # them may be read as shell syntax.
  defp q(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    chat_id = Keyword.fetch!(opts, :chat_id)
    workspace = Keyword.fetch!(opts, :workspace)
    jail = Keyword.get(opts, :jail, true)
    command = Keyword.get(opts, :command)
    argv = Terminal.command_argv(command)
    socket = "elia-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    # TERM-7, TERM-8, NET-18: the jail's argv, the network the session's whole
    # process tree gets (NET-13, NET-16) and the priority wrapper all come from
    # `Elia.Shell`, the same ones a command runs with — a terminal is not a way
    # around any of them. The jail holds the chat's workspace, the tree the
    # session belongs to, not the directory it starts in (TERM-2, ISOL-13).
    # SECRET-5: what the caller passes as `:env` — the project's secrets — is
    # added to the session's environment, in the jail's `--setenv` arguments and
    # in the port's own environment alike.
    env = [{"TERM", "xterm-256color"}] ++ Keyword.get(opts, :env, [])

    session_opts =
      Elia.Net.prepare(
        workspace: workspace,
        jail: jail,
        env: env,
        network: Keyword.get(opts, :network),
        session_id: chat_id
      )
      |> elem(0)

    {exe, args} =
      Shell.argv(
        script(socket, argv, Terminal.tmux()),
        workspace,
        Keyword.put(session_opts, :workspace, workspace)
      )

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :hide,
        args: args,
        cd: workspace,
        env: Shell.port_env(env: env)
      ])

    state = %__MODULE__{
      chat_id: chat_id,
      argv: argv,
      command: Enum.join(argv, " "),
      workspace: workspace,
      jail: jail,
      jailed: Shell.jailed?(jail: jail),
      # NET-21: the proxy, its socket and its directory go when this session
      # does, whatever ends it (TERM-3, TERM-4).
      net: Keyword.get(session_opts, :net),
      socket: socket,
      port: port,
      cols: @initial_cols,
      rows: @initial_rows,
      status: :running,
      started_at: DateTime.utc_now()
    }

    # TERM-41: a session that has just started says so, on the chat's own topic
    # and on the terminal's activity topic, so a list of chats shows that this
    # chat has a terminal running (UI-111) without asking every chat's session.
    notify_status(state)

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}
  def handle_call(:running?, _from, state), do: {:reply, state.status == :running, state}

  # TERM-13: what the user typed, as bytes, straight into the app's stdin.
  def handle_call({:input, _bytes}, _from, %{status: status} = state) when status != :running do
    {:reply, {:error, "This terminal's command has ended, so there is nothing to type into."},
     state}
  end

  def handle_call({:input, ""}, _from, state), do: {:reply, :ok, state}

  def handle_call({:input, bytes}, _from, state) do
    {:reply, :ok, send_segment({:text, bytes}, state)}
  end

  # TERM-30: the agent's keystrokes, through the same door as the user's
  # (TERM-13) — a named key by name, so that tmux expands it for the pane's own
  # mode, and text as bytes.
  def handle_call({:keys, _segments}, _from, %{status: status} = state)
      when status != :running do
    {:reply, {:error, "This terminal's command has ended, so there is nothing to type into."},
     state}
  end

  def handle_call({:keys, segments}, _from, state) do
    # TERM-31: a name reaches a line tmux parses, so only what `Keys.parse/1`
    # guarantees — and `valid?/1` re-checks — may be sent.
    if Enum.all?(segments, &Terminal.Keys.valid?/1) do
      {:reply, :ok, Enum.reduce(segments, state, &send_segment/2)}
    else
      {:reply, {:error, "That is not something this terminal can send."}, state}
    end
  end

  # TERM-15: the app's pty takes the size of the box the browser draws in.
  def handle_call({:resize, _cols, _rows}, _from, %{status: status} = state)
      when status != :running do
    {:reply, :ok, state}
  end

  def handle_call({:resize, cols, rows}, _from, state) do
    cols = clamp(cols, 2, 1_000)
    rows = clamp(rows, 1, 1_000)

    state = send_command(state, "refresh-client -C #{cols},#{rows}")

    {:reply, :ok, %{state | cols: cols, rows: rows}}
  end

  # TERM-26: what the app is showing now, as plain text.
  def handle_call(:read, from, %{status: :running} = state) do
    {:noreply, send_command(state, capture(plain: true), {:read, from})}
  end

  def handle_call(:read, _from, state) do
    {:reply, {:ok, state.screen |> strip() |> trim()}, state}
  end

  # TERM-3: the user's Stop. The screen is captured first, so the page can still
  # show what the terminal was showing (TERM-23), and then the whole tree goes.
  def handle_call(:stop, from, %{status: :running} = state) do
    state = %{state | status: :ending, ended: :stopped}
    {:noreply, send_command(state, capture(), {:stop, from})}
  end

  def handle_call(:stop, _from, state), do: {:reply, {:ok, status_map(state)}, state}

  # TERM-12, TERM-14: a client joins and is sent the screen it has now, then the
  # live stream. Until that screen arrives it gets no output: what it would have
  # been sent is in the capture, and a line or two around the join is what
  # TERM-14 allows to go missing.
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)

    state = %{
      state
      | subscribers: Map.put(state.subscribers, pid, ref),
        joining: MapSet.put(state.joining, pid)
    }

    state =
      if state.status == :running do
        send_command(state, capture(), {:join, pid})
      else
        send(pid, {:terminal_screen, state.screen || ""})
        %{state | joining: MapSet.delete(state.joining, pid)}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, {_eol, data}}}, %{port: port} = state) do
    {:noreply, %{state | stderr: cap_stderr(state.stderr <> data)}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, ingest(state, data)}

  # The port program is gone: the client exited, so either the session ended on
  # its own or it never started. Either way there is nothing left to talk to.
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state =
      case %{state | port: nil} do
        %{status: :running} = state -> end_session(state, :crashed, code)
        %{status: :ending} = state -> end_session(state, state.ended, state.exit_status)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # TERM-3: a session that goes away — the chat was deleted, the server is
    # shutting down — takes its process tree with it.
    if state.port, do: kill_port(state.port)
    # TERM-36: a session that already ended released its tmux then.
    if state.status != :ended, do: release_tmux(state)
    # NET-21: the network this session was given ends with it.
    Elia.Net.release(net: state.net)
    :ok
  end

  # TERM-36: an unjailed session's tmux server is outside any jail, and the
  # port may be closed already — the client gone before or after it attached —
  # so neither of `kill_port/1`'s mechanisms reaches it. The server is ended by
  # its own socket name, as a command of its own, awaited here with a short
  # timeout (`@release_timeout`); a server already gone makes it fail, which is
  # fine. Then the one socket file tmux reported for this session goes: tmux
  # leaves it however its server exits. A jailed session has nothing to release:
  # its server went with the jail's pid namespace and its socket with its `/tmp`.
  # It runs in the temp dir rather than the workspace, which may be gone by now
  # (a chat's worktree removed before its terminal's `terminate/2`).
  defp release_tmux(%{jailed: false, socket: socket} = state) when is_binary(socket) do
    _ =
      Shell.run("#{q(Terminal.tmux())} -L #{q(socket)} -f /dev/null kill-server",
        jail: false,
        cd: System.tmp_dir!(),
        timeout: @release_timeout,
        max_output: 1_000
      )

    if state.socket_path, do: File.rm(state.socket_path)
    :ok
  end

  defp release_tmux(_state), do: :ok

  ## The protocol

  defp ingest(state, data) do
    {lines, partial} = split_lines(state.partial <> data)

    state =
      Enum.reduce(lines, %{state | partial: partial}, fn line, state ->
        handle_line(state, line)
      end)

    state
  end

  # The protocol is line-oriented and tmux escapes every byte that could break
  # that (a newline arrives as `\015\012`, a backslash as `\134`), so splitting
  # on a newline is safe even though the payload carries raw bytes.
  defp split_lines(data) do
    case :binary.split(data, "\n", [:global]) do
      [] -> {[], ""}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # A reply block is a unit: inside one, everything is its content, so a screen
  # that happens to contain a line starting with `%output` is not read as a
  # notification. Output written while a capture is in flight is dropped, which
  # is the same moment TERM-14 allows a joining client to miss.
  defp handle_line(%{reply: {lines, owner}} = state, line) do
    case line do
      "%end " <> rest -> finish_reply(state, rest, :ok, lines, owner)
      "%error " <> rest -> finish_reply(state, rest, :error, lines, owner)
      _ -> %{state | reply: {[line | lines], owner}}
    end
  end

  # TERM-12: the app's output, as bytes.
  defp handle_line(%{reply: nil} = state, "%output %" <> rest) do
    case :binary.split(rest, " ") do
      [_pane, data] -> broadcast(state, unescape(data))
      _ -> state
    end
  end

  defp handle_line(%{reply: nil} = state, "%begin " <> rest) do
    # A block with flags 1 answers a command of ours; flags 0 is tmux speaking
    # unprompted (at attach), and it must not consume a pending command.
    case rest |> String.split(" ") |> List.last() do
      "1" ->
        {owner, pending} = pop_pending(state.pending)
        %{state | reply: {[], owner}, pending: pending}

      _ ->
        %{state | reply: {[], nil}}
    end
  end

  # TERM-4: the app's process ended, and this is the only notification that says
  # so — with `remain-on-exit` the session stays, so there is no `%exit` to wait
  # for. The pane is still there to be captured, which is how the last screen
  # survives (TERM-23).
  defp handle_line(%{reply: nil, status: :running} = state, "%subscription-changed " <> rest) do
    case String.split(rest, " : ", parts: 2) do
      [subscription, value] ->
        if String.starts_with?(subscription, subscription_name()) do
          app_exited(state, String.trim(value))
        else
          state
        end

      _ ->
        state
    end
  end

  # The client is attached and has a session: this is the moment to ask for the
  # one notification tmux gives unprompted — that the app's process ended, and
  # with what status (TERM-4). With `remain-on-exit` the session outlives the
  # app, so the status arrives this way; there is no `%exit` to wait for.
  #
  # `destroy-unattached` is set here too, and not a moment earlier: it takes
  # effect at once, and until this client is attached the session is exactly
  # what it destroys. From here on the session belongs to this client alone —
  # the server lives inside this session's jail and no other client can ever
  # reach it — so a client that goes away takes the app with it (TERM-3).
  defp handle_line(%{reply: nil} = state, "%session-changed " <> _rest), do: on_attach(state)

  # TERM-36: the script's report of where its server's socket is. Only a path
  # whose file is this session's own socket name is kept, so nothing the pane
  # prints can point the clean-up at another file.
  defp handle_line(%{reply: nil, socket_path: nil} = state, @socket_path_marker <> path) do
    path = String.trim(path)

    if Path.type(path) == :absolute and Path.basename(path) == state.socket,
      do: %{state | socket_path: path},
      else: state
  end

  # Everything else tmux says unprompted — `%layout-change`, `%window-renamed`,
  # `%exit` — is bookkeeping this session has no use for.
  defp handle_line(%{reply: nil} = state, _line), do: state

  defp on_attach(%{subscribed: true} = state), do: state

  defp on_attach(state) do
    state =
      send_command(
        state,
        ~s(refresh-client -B "#{subscription_name()}:%*:#{@dead_status_format}")
      )

    state =
      state
      |> send_command("set-option -g destroy-unattached on")
      |> Map.put(:subscribed, true)

    state
  end

  defp app_exited(state, value) do
    case Integer.parse(value) do
      {status, ""} ->
        state = %{state | status: :ending, ended: :exited, exit_status: status}
        send_command(state, capture(), :final)

      _ ->
        # Not a status: the subscription fires once with an empty value as the
        # pane is still alive, and that is not the app ending.
        state
    end
  end

  defp finish_reply(state, _rest, result, lines, owner) do
    text = lines |> Enum.reverse() |> Enum.join("\n")
    deliver(%{state | reply: nil}, owner, text, result)
  end

  # TERM-14: the screen a joining client is sent, and then the stream. A screen
  # that was captured is also the last one the session knows of, which is what
  # an ended session keeps when its port closed before the stop's own capture
  # could run (TERM-35, TERM-23).
  defp deliver(state, {:join, pid}, text, result) do
    send(pid, {:terminal_screen, text})
    state = %{state | joining: MapSet.delete(state.joining, pid)}
    if result == :ok, do: %{state | screen: text}, else: state
  end

  # TERM-26: what terminal_read asked for.
  defp deliver(state, {:read, from}, text, :ok), do: reply_read(state, from, {:ok, trim(text)})

  defp deliver(state, {:read, from}, text, :error) do
    reply_read(state, from, {:error, "The terminal could not be read: #{String.trim(text)}"})
  end

  # TERM-3, TERM-23: the last screen is kept, and the tree goes.
  defp deliver(state, {:stop, from}, text, _result) do
    state = end_session(%{state | screen: text}, :stopped, nil)
    GenServer.reply(from, {:ok, status_map(state)})
    state
  end

  # TERM-4, TERM-23: the app ended on its own; the capture is the screen it left.
  defp deliver(%{status: :ending} = state, :final, text, _result) do
    end_session(%{state | screen: text}, state.ended, state.exit_status)
  end

  defp deliver(state, _owner, _text, _result), do: state

  defp reply_read(state, from, result) do
    GenServer.reply(from, result)
    state
  end

  ## Commands

  # TERM-13, TERM-30: text goes as bytes, so nothing in it — a space, a quote, a
  # `;` — can be read as part of the command tmux runs.
  defp send_segment({:text, text}, state) do
    text
    |> chunks(@input_chunk)
    |> Enum.reduce(state, fn chunk, state ->
      send_command(state, "send-keys -H #{hex(chunk)}")
    end)
  end

  # TERM-30, TERM-31: a key goes to tmux by name, so tmux sends the bytes the
  # pane's mode asks for — `ESC O A` for `<Up>` in an app that turned on
  # application cursor keys, `ESC [ A` in one that did not. The name is a word
  # of `Keys.parse/1`'s alphabet and nothing else (TERM-31).
  defp send_segment({:key, name}, state), do: send_command(state, "send-keys #{name}")

  # Every command sent gets one reply, so one pending entry is pushed for each
  # and the order of the queue is the order of the replies. An entry with no
  # owner is one whose reply nobody needs (`send-keys`, `refresh-client`).
  defp send_command(state, command, owner \\ nil) do
    with port when not is_nil(port) <- state.port,
         :ok <- port_send(port, command <> "\n") do
      %{state | pending: :queue.in(owner, state.pending)}
    else
      nil -> state
      :closed -> answer_closed(state, owner)
    end
  end

  # TERM-35: the port's program has exited and its `exit_status` is still on its
  # way, so the command will get no reply. Whoever was waiting on it is answered
  # now instead, as its reply would have — a stop ends the session as stopped,
  # keeping the last screen, and replies — since queueing it would leave the
  # caller waiting out its timeout.
  defp answer_closed(state, {:read, _from} = owner),
    do: deliver(state, owner, "its command has exited", :error)

  defp answer_closed(state, owner), do: deliver(state, owner, state.screen || "", :error)

  # TERM-35: a port whose program has exited is closed, and `Port.command/2` and
  # `Port.close/1` raise on a closed port. Whether it is still open can change
  # between any check and the call, so the call itself is what is guarded.
  defp port_send(port, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> :closed
  end

  defp port_close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp pop_pending(pending) do
    case :queue.out(pending) do
      {{:value, owner}, rest} -> {owner, rest}
      {:empty, _} -> {nil, pending}
    end
  end

  defp capture(opts \\ []) do
    escapes = if Keyword.get(opts, :plain, false), do: "", else: " -e"
    "capture-pane -p#{escapes} -S -#{Terminal.config(:scrollback_lines)}"
  end

  defp subscription_name, do: "elia-exit"

  defp hex(bytes), do: Enum.map_join(:binary.bin_to_list(bytes), " ", &Integer.to_string(&1, 16))

  defp chunks(bytes, size) when byte_size(bytes) <= size, do: [bytes]

  defp chunks(bytes, size) do
    <<chunk::binary-size(size), rest::binary>> = bytes
    [chunk | chunks(rest, size)]
  end

  defp clamp(value, min, max) do
    value
    |> max(min)
    |> min(max)
  end

  # Control mode escapes what would break its line protocol: a newline arrives
  # as `\015\012`, a backslash as `\134`, and a byte outside ASCII comes through
  # raw. So only a backslash with three octal digits behind it is an escape;
  # every other byte is itself (verified against tmux 3.5a).
  defp unescape(data), do: unescape(data, [])

  defp unescape(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?7 and b in ?0..?7 and c in ?0..?7 do
    unescape(rest, [(a - ?0) * 64 + (b - ?0) * 8 + (c - ?0) | acc])
  end

  defp unescape(<<byte, rest::binary>>, acc), do: unescape(rest, [byte | acc])
  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> :erlang.list_to_binary()

  # TERM-26 and the screen a page shows for a session that has ended: the same
  # text without the attributes a terminal draws with.
  defp strip(nil), do: nil

  defp strip(text) do
    text
    |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]/, "")
    |> String.replace(~r/\e[()][A-Za-z0-9]/, "")
  end

  # What the terminal shows, for a reader rather than for a terminal: the blank
  # lines below the last thing written are the pane's height, not its content.
  defp trim(nil), do: ""

  defp trim(text) do
    text
    |> String.trim_trailing()
  end

  defp cap_stderr(text) when byte_size(text) > 4_000, do: binary_part(text, 0, 4_000)
  defp cap_stderr(text), do: text

  ## Subscribers

  # TERM-12: bytes to every client watching, unless it is joining (its screen is
  # on the way, TERM-14) or it has fallen too far behind (TERM-17).
  defp broadcast(%{subscribers: subscribers} = state, bytes) do
    Enum.reduce(subscribers, state, fn {pid, _ref}, state ->
      cond do
        MapSet.member?(state.joining, pid) ->
          state

        busy?(pid) ->
          drop_subscriber(state, pid, :overflow)

        true ->
          send(pid, {:terminal_output, bytes})
          state
      end
    end)
  end

  defp busy?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length > (Terminal.config(:max_pending) || @max_pending)
      nil -> true
    end
  end

  defp drop_subscriber(state, pid, reason \\ :down) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        %{state | joining: MapSet.delete(state.joining, pid)}

      {ref, subscribers} ->
        if reason == :overflow, do: send(pid, {:terminal_overflow, :dropped})
        Process.demonitor(ref, [:flush])

        %{state | subscribers: subscribers, joining: MapSet.delete(state.joining, pid)}
    end
  end

  defp notify_status(state) do
    status = status_map(state)

    for {pid, _ref} <- state.subscribers, do: send(pid, {:terminal_status, status})
    Terminal.broadcast_status(state.chat_id, status)
  end

  ## Ending

  # TERM-3: the whole tree, killed the way a timed-out command is (SHELL-3), so
  # with the jail on the pid namespace goes with it (ISOL-10). The port is
  # closed here and the field cleared, so the `exit_status` the kill produces is
  # not mistaken for a session that crashed.
  defp end_session(%{status: :ended} = state, _ended, _exit_status), do: state

  defp end_session(state, ended, exit_status) do
    if state.port, do: kill_port(state.port)
    # TERM-36: whether or not the port was still there to carry a kill-server.
    release_tmux(state)

    state = %{state | status: :ended, ended: ended, exit_status: exit_status, port: nil}
    state = settle_pending(state)
    notify_status(state)
    state
  end

  # Whatever was still waiting on a command that will never be answered because
  # the client is gone is settled here: a reader gets an error instead of
  # hanging (TERM-26), a joiner gets the screen there is (TERM-14), and a Stop
  # gets its answer (TERM-3).
  defp settle_pending(state) do
    state.pending
    |> :queue.to_list()
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn
      {:read, from} ->
        GenServer.reply(from, {:error, "The terminal ended while its screen was being read."})

      {:join, pid} ->
        send(pid, {:terminal_screen, state.screen || ""})

      {:stop, from} ->
        GenServer.reply(from, {:ok, status_map(state)})

      _other ->
        :ok
    end)

    %{state | pending: :queue.new(), joining: MapSet.new()}
  end

  # TERM-3: the whole tree, and nothing left running. The tmux server is asked
  # to take its sessions — and the app in the pane — down, and the process group
  # is killed the way a timed-out command is (SHELL-3), so with the jail on the
  # pid namespace goes with it (ISOL-10). Either mechanism alone leaves a
  # terminal running (the server outlives the group; a server that is already
  # gone has nothing to ask), which is why both are here. The port is closed
  # here and the field cleared, so the `exit_status` the kill produces is not
  # mistaken for a session that crashed.
  # TERM-35: the port can close at any point here — the kill is what closes it
  # — so each call on it is the guarded one rather than checked first.
  defp kill_port(port) do
    _ = port_send(port, "kill-server\n")
    Shell.kill(port)
    port_close(port)
  end

  defp status_map(state) do
    %{
      chat_id: state.chat_id,
      running: state.status == :running,
      ending: state.status == :ending,
      command: state.command,
      workspace: state.workspace,
      jail: state.jail,
      # TERM-39: the confinement the session actually has — the chat's setting
      # at its start, the host's and bubblewrap's presence together (ISOL-12,
      # ISOL-20) — where `jail` is only what was asked for.
      jailed: state.jailed,
      cols: state.cols,
      rows: state.rows,
      ended: state.ended,
      exit_status: state.exit_status,
      started_at: state.started_at,
      error: if(state.ended == :crashed, do: String.trim(state.stderr), else: nil)
    }
  end
end
