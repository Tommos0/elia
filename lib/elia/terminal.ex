defmodule Elia.Terminal do
  @moduledoc """
  The terminal a chat can have: one session per chat (TERM-1), a jailed and
  niced tmux process tree in the chat's workspace (TERM-2, TERM-7, TERM-8),
  streamed to the browser over `EliaWeb.TerminalChannel` (TERM-12) and shown on
  `/c/:id/terminal` (TERM-19).

      config :elia, Elia.Terminal,
        tmux: nil,               # resolved from PATH when unset (TERM-29)
        default_command: nil,    # nil: the user's login shell (TERM-5)
        scrollback_lines: 2_000, # what a joining client replays and terminal_read returns
        max_sessions: 8,         # across chats
        max_pending: 1_000       # output messages one client may fall behind by

  The session layer is tmux in control mode, which is what gives the command the
  pty the BEAM has none of — see `Elia.Terminal.Session` for what that buys and
  how it is driven. Everything else is Elia's own: the workspace, the jail
  (built by `Elia.Shell`, so there is one definition of it, TERM-7), the
  priority (PRIO) and the kill that ends the tree (TERM-3).
  """

  alias Elia.Terminal.Session

  @registry Elia.Terminal.Registry
  @supervisor Elia.Terminal.Supervisor

  @defaults [
    tmux: nil,
    default_command: nil,
    scrollback_lines: 2_000,
    max_sessions: 8,
    max_pending: 1_000
  ]

  @doc "The registry a chat's session is registered under, by chat id (TERM-1)."
  def registry, do: @registry

  @doc "The supervisor the sessions run under."
  def supervisor, do: @supervisor

  @doc "The configured value of `key`, with the defaults of the moduledoc."
  def config(key), do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))[key]

  @doc """
  The tmux to run: `config :elia, Elia.Terminal, tmux:` (a name or a path),
  else `tmux` on `PATH`, else `nil` where this machine has none (TERM-29).
  """
  @spec tmux() :: binary() | nil
  def tmux do
    case config(:tmux) do
      nil -> System.find_executable("tmux")
      path -> System.find_executable(path) || (File.regular?(path) && path) || nil
    end
  end

  @doc "Whether a terminal can run on this machine (TERM-29)."
  @spec available?() :: boolean()
  def available?, do: tmux() != nil

  @doc "What the page and the tools say where tmux is missing (TERM-29)."
  @spec unavailable_message() :: binary()
  def unavailable_message do
    "This machine has no tmux, so Elia can't open a terminal: install it " <>
      "(for example `apt install tmux`) and try again."
  end

  @doc """
  The command a session runs when none is given (TERM-5): the configured
  default, else the user's login shell (`$SHELL`, else `bash`, else `sh`).

  The pair is what tmux starts in the pane — the login shell alone for a plain
  terminal, or the login shell with `-lc` and the command, so a terminal app
  gets the environment a shell would give it and the session ends when the app
  does (TERM-3, TERM-4).
  """
  @spec command_argv(binary() | nil) :: [binary()]
  def command_argv(command \\ nil)

  def command_argv(nil) do
    case config(:default_command) do
      nil -> [login_shell(), "-l"]
      command -> [login_shell(), "-lc", command]
    end
  end

  def command_argv(command), do: [login_shell(), "-lc", command]

  # TERM-5: the user's own shell, but only one that is a program — a `$SHELL`
  # that names nothing (or nothing on this machine) falls through to bash, then
  # sh, then the one path that is always there.
  defp login_shell do
    with shell when is_binary(shell) <- System.get_env("SHELL"),
         true <- File.regular?(shell) do
      shell
    else
      _ -> System.find_executable("bash") || System.find_executable("sh") || "/bin/sh"
    end
  end

  @doc """
  Starts `chat_id`'s terminal (TERM-2, TERM-25).

  Options: `:command` (a command line the login shell runs; the default
  otherwise, TERM-5), `:workspace` (default `Elia.Workspace.root/0`) and
  `:jail` (default on, ISOL-16, so the terminal is confined as a command is,
  TERM-7).

  Refused when the chat already has a *running* session (TERM-1) and where tmux
  is missing (TERM-29). A session whose command has exited is not running: it is
  replaced, and the screen it was showing goes with it.
  """
  @spec start(binary(), keyword()) :: {:ok, pid()} | {:error, binary()}
  def start(chat_id, opts \\ []) do
    with :ok <- check_available(),
         :ok <- check_room(),
         :ok <- check_not_running(chat_id),
         :ok <- replace_ended(chat_id) do
      opts =
        opts
        |> Keyword.put(:chat_id, chat_id)
        |> Keyword.put_new(:workspace, Elia.Workspace.root())

      case DynamicSupervisor.start_child(@supervisor, {Session, opts}) do
        {:ok, pid} ->
          {:ok, pid}

        # TERM-1: the registry name is the chat id, so a second session for the
        # same chat can't be started even by two callers at once.
        {:error, {:already_started, _pid}} ->
          {:error, already_running_message()}

        {:error, reason} ->
          {:error, "The terminal could not start: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Stops `chat_id`'s running session (TERM-3): its whole process tree is killed,
  and what the terminal was showing is kept so the page can still show it
  (TERM-23). A session that has already ended is left as it is.
  """
  @spec stop(binary()) :: {:ok, map()} | {:error, binary()}
  def stop(chat_id) do
    case fetch(chat_id) do
      {:ok, pid} -> Session.stop(pid)
      :error -> {:error, "This chat has no terminal to stop."}
    end
  end

  @doc "The session process for `chat_id`, or `:error` when it has none."
  @spec fetch(binary()) :: {:ok, pid()} | :error
  def fetch(chat_id) do
    case Registry.lookup(@registry, chat_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  How `chat_id`'s terminal is doing (TERM-23): whether it is running, what it
  runs, where, and how it ended. `:error` when the chat has no session at all.
  """
  @spec status(binary()) :: {:ok, map()} | :error
  def status(chat_id) do
    case fetch(chat_id) do
      {:ok, pid} -> {:ok, Session.status(pid)}
      :error -> :error
    end
  end

  @doc """
  What `chat_id`'s terminal is showing, as plain text — its screen and up to
  `scrollback_lines` of it (TERM-26).
  """
  @spec read(binary()) :: {:ok, binary()} | {:error, binary()}
  def read(chat_id) do
    case fetch(chat_id) do
      {:ok, pid} -> Session.read(pid)
      :error -> {:error, "This chat has no terminal: start one with terminal_start."}
    end
  end

  @doc "Sends `bytes` to `chat_id`'s terminal as if they were typed (TERM-13)."
  @spec input(binary(), binary()) :: :ok | {:error, binary()}
  def input(chat_id, bytes) do
    case fetch(chat_id) do
      {:ok, pid} -> Session.input(pid, bytes)
      :error -> {:error, "This chat has no terminal."}
    end
  end

  @doc """
  Types `keys` into `chat_id`'s terminal (TERM-30): the notation of
  `Elia.Terminal.Keys`, in which text goes as it is and `<Name>` names a key.

  Returns what was sent, in order, so that a result can say so. An error says
  which of the three it is: the notation names a key tmux does not know
  (TERM-31), the chat has no terminal, or its command has ended (TERM-34).
  """
  @spec keys(binary(), binary()) :: {:ok, [Elia.Terminal.Keys.segment()]} | {:error, binary()}
  def keys(chat_id, keys) do
    case fetch(chat_id) do
      {:ok, pid} ->
        with {:ok, segments} <- Elia.Terminal.Keys.parse(keys),
             :ok <- Session.keys(pid, segments) do
          {:ok, segments}
        end

      :error ->
        {:error, "This chat has no terminal: start one with terminal_start."}
    end
  end

  @doc """
  Resizes `chat_id`'s terminal to `cols` by `rows` (TERM-15), so the app's pty
  is the size the browser can draw.
  """
  @spec resize(binary(), integer(), integer()) :: :ok | {:error, binary()}
  def resize(chat_id, cols, rows) do
    case fetch(chat_id) do
      {:ok, pid} -> Session.resize(pid, cols, rows)
      :error -> {:error, "This chat has no terminal."}
    end
  end

  @doc """
  Subscribes the calling process to `chat_id`'s terminal output (TERM-12).

  The session sends it `{:terminal_screen, bytes}` for the screen it has now
  (TERM-14) and then `{:terminal_output, bytes}` as the app writes, plus
  `{:terminal_status, status}` when the session ends and `{:terminal_overflow,
  :dropped}` if it falls too far behind (TERM-17).
  """
  @spec subscribe(binary(), pid()) :: :ok | {:error, binary()}
  def subscribe(chat_id, pid \\ self()) do
    case fetch(chat_id) do
      {:ok, session} -> Session.subscribe(session, pid)
      :error -> {:error, "This chat has no terminal."}
    end
  end

  @doc "The PubSub topic a chat's terminal reports its status on (TERM-23)."
  def topic(chat_id), do: "terminal:" <> chat_id

  @doc "Subscribes to `{:terminal_status, chat_id, status}` for one chat."
  def subscribe_status(chat_id), do: Phoenix.PubSub.subscribe(Elia.PubSub, topic(chat_id))

  @doc """
  Broadcasts `chat_id`'s terminal status to the page watching it. The session
  calls this when it starts running, ends or is stopped (TERM-23); the page
  needs no stream of bytes of its own, so this carries the status alone.
  """
  @spec broadcast_status(binary(), map()) :: :ok
  def broadcast_status(chat_id, status) do
    Phoenix.PubSub.broadcast(Elia.PubSub, topic(chat_id), {:terminal_status, chat_id, status})
  end

  @doc "How many sessions are running right now, across chats (TERM-1's bound)."
  @spec running_count() :: non_neg_integer()
  def running_count do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [:"$2"]}])
    |> Enum.count(&Session.running?/1)
  end

  defp check_available do
    if available?(), do: :ok, else: {:error, unavailable_message()}
  end

  # A bound on how many ptys one server hands out (config `max_sessions`). Only
  # running sessions count: a session that has ended holds no process (TERM-3)
  # and is replaced by the next start anyway.
  defp check_room do
    max = config(:max_sessions)

    if running_count() < max do
      :ok
    else
      {:error, "There are already #{max} terminals running, which is this server's limit."}
    end
  end

  defp check_not_running(chat_id) do
    case status(chat_id) do
      {:ok, %{running: true}} -> {:error, already_running_message()}
      _ -> :ok
    end
  end

  defp replace_ended(chat_id) do
    case fetch(chat_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      :error ->
        :ok
    end
  end

  defp already_running_message do
    "This chat already has a running terminal (TERM-1). Stop it first, or use " <>
      "the one it has — its page is at /c/<chat id>/terminal."
  end
end
