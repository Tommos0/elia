defmodule Elia.Shell do
  @moduledoc """
  Runs OS commands with a timeout, empty stdin and combined output.

  Commands run with `bash -c` where bash is installed, otherwise with POSIX
  `sh -c` (SHELL-2), so bash-only syntax works only where bash is present.

  A command runs inside a bubblewrap jail unless it is turned off (ISOL): a
  fresh mount namespace holding the tree the call belongs to — its workspace
  (ISOL-13) — the toolchain and nothing else, and a fresh pid namespace whose
  `/proc` doesn't show the server. So a command can't reach the settings
  database with the provider API keys (CONF-1), the saved conversations under
  `.elia/sessions` or the user's credentials (ISOL-5), and can't read the
  server's memory (ISOL-9). `jail: false` — the chat's own setting (ISOL-16) —
  or a host without bubblewrap (ISOL-12, ISOL-20) runs the command directly, as
  it did before.

  Every command starts below the server's own CPU and I/O priority (PRIO-1), so
  a compile or a test suite doesn't take the machine from the UI and the agent
  loops: see `Elia.Priority` and `run/2`'s `:priority`.
  """
  alias Elia.{Priority, Workspace}

  @type result :: {:ok, binary(), non_neg_integer()} | {:timeout, binary()}

  # Bound read-only so a jailed command finds the shell, Elixir, git and mix
  # (ISOL-4).
  @toolchain ~w(/usr /lib /lib64 /bin /sbin /etc)

  # The only environment a jailed command gets from the server (ISOL-8).
  @env_allowlist ~w(PATH HOME LANG TERM)

  # ISOL-12: a run that wanted a jail and didn't get one says so, so it never
  # looks like one that was isolated.
  @jail_skipped_notice "[jail: skipped, bubblewrap is unavailable]"

  @doc """
  The shell that runs commands: bash when it is installed, otherwise POSIX
  `sh` (SHELL-2). Pass `shell: <path or name>` to override the choice.
  """
  @spec shell(keyword()) :: binary() | nil
  def shell(opts \\ []) do
    case Keyword.get(opts, :shell) do
      nil -> System.find_executable("bash") || System.find_executable("sh")
      # Resolve a name on PATH, but keep a path as given.
      name -> System.find_executable(name) || name
    end
  end

  @doc "Whether bubblewrap is installed, so a jail can be built (ISOL-12)."
  @spec available?() :: boolean()
  def available?, do: bwrap() != nil

  @doc """
  What a run says when it wanted a jail and didn't get one (ISOL-12). It is
  prepended to the command's own output, so a caller that reads that output
  rather than showing it — the harness's own `git` calls (ISOL-1) — knows to
  look below it.
  """
  @spec jail_skipped_notice() :: binary()
  def jail_skipped_notice, do: @jail_skipped_notice

  @doc """
  Resolves the timeout of one call against the configured default and ceiling
  (SHELL-10, VERIFY-9): `asked` is what the call gave (`nil` when it gave none),
  and `default` and `max` are the settings, in whatever unit the caller works
  in.

  The first value returned is the one to use with. What the call asked for
  comes back beside it when it asked for more than the maximum and was clamped
  to it, so the result can say which ceiling was hit instead of leaving the
  model to wonder why its command stopped. Anything that is not a whole number
  of at least 1 is `{:error, :invalid}`, and nothing runs.
  """
  @spec resolve_timeout(term(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer(), pos_integer() | nil} | {:error, :invalid}
  def resolve_timeout(nil, default, max), do: {:ok, min(default, max), nil}

  def resolve_timeout(asked, _default, max) when is_integer(asked) and asked >= 1,
    do: {:ok, min(asked, max), if(asked > max, do: asked)}

  def resolve_timeout(_asked, _default, _max), do: {:error, :invalid}

  @doc """
  The `[exit: ...]` status of a run that reached its timeout (SHELL-4,
  SHELL-10): how long it ran for, and — for a call that was clamped to the
  configured maximum — what it asked for and the ceiling it hit.
  """
  @spec timeout_status(integer(), pos_integer() | nil) :: binary()
  def timeout_status(timeout_ms, nil), do: "timeout after #{div(timeout_ms, 1000)}s"

  def timeout_status(timeout_ms, asked) do
    used = div(timeout_ms, 1000)
    "timeout after #{used}s (asked for #{asked}s, the most is #{used}s)"
  end

  @doc """
  Takes the notice a run may have put in front of its output off it (ISOL-12),
  for a caller that reads that output as a value — a ref, a path, a
  NUL-separated list — rather than showing it.
  """
  @spec strip_notices(binary()) :: binary()
  def strip_notices(output) do
    String.replace_leading(output, @jail_skipped_notice <> "\n", "")
  end

  @doc """
  Whether a command would run jailed: the host allows it (ISOL-20), the caller
  didn't turn it off (ISOL-16) and bubblewrap is installed (ISOL-12).
  """
  @spec jailed?(keyword()) :: boolean()
  def jailed?(opts \\ []), do: wanted?(opts) and available?()

  @doc """
  Whether the call wants a jail: the caller's setting (ISOL-16) and the host's
  (ISOL-20), whether or not bubblewrap is installed (ISOL-12). `jailed?/1` is
  this with a jail that can actually be built.

  A tool that runs no process — the file tools (FILE-12) — follows this one:
  what turns a confinement off is the user's own setting, not a missing
  bubblewrap.
  """
  @spec wanted?(keyword()) :: boolean()
  def wanted?(opts \\ []) do
    Keyword.get(opts, :jail) != false and
      Application.get_env(:elia, __MODULE__, [])[:jail] != false
  end

  @doc """
  Whether a jailed command in `workspace` can reach the absolute path `abs`
  (ISOL-25): the workspace it belongs to and nothing else — a jail binds one
  tree (ISOL-13) — and never the `.elia` the live tree is masked with (ISOL-6).
  Another project's folder reaches no further than itself, and neither does a
  chat's worktree, whose jail holds its own tree.

  Symlinks are followed (WS-5), so a link inside the workspace that points out
  of it is not reachable either. The toolchain and `$HOME/.mix` (ISOL-4) are
  bound too, but they are for running a program, not for reading, so they are
  not part of this reach.
  """
  @spec reachable?(binary(), binary()) :: boolean()
  def reachable?(abs, workspace) do
    live = Workspace.real_location(Workspace.runtime_root())
    workspace = Workspace.real_location(workspace)
    abs = Workspace.real_location(abs)

    cond do
      # WS-6: a path with no real location is reachable by nothing.
      :unresolvable in [live, workspace, abs] ->
        false

      not inside?(abs, workspace) ->
        false

      workspace == live ->
        not inside?(abs, Path.join(live, ".elia"))

      true ->
        true
    end
  end

  @doc """
  The directory the user-wide Playwright CLI is installed in: it holds
  `node_modules/playwright` (BROWSER-2, ISOL-26).

  `:elia, :playwright_dir` names it (`ELIA_PLAYWRIGHT_DIR` to override it), and
  the browser driver is pointed at the same value, so the path a jailed run
  resolves is the path the driver was told to use.
  """
  @spec playwright_dir() :: Path.t()
  def playwright_dir do
    Application.get_env(:elia, :playwright_dir, Path.expand("~/.local/lib"))
  end

  @doc """
  Runs `command` with the shell from `shell/1`.

  Options: `:cd` (default `Elia.Workspace.root/0`), `:workspace` (the tree the
  jail holds, default: the `cd` — ISOL-13), `:env` (list of string pairs),
  `:shell` (path or name, to override the shell), `:timeout` in milliseconds
  (default 60s), `:jail` (`false` runs the command unjailed, ISOL-16),
  `:priority` (`Elia.Priority` settings for this command, e.g. `[nice: 0]` to
  run it at the server's own priority, PRIO-5) and `:max_output` (characters:
  the output is held bounded while the command runs and comes back cut as
  `truncate/2` cuts it, SHELL-13; without it the run keeps every byte, as the
  harness's own commands need).

  `:workspace` is what the jail holds; `:cd` is where the command runs in it
  (WD-1). A caller that knows the tree its command belongs to — a chat's
  workspace (PROJ-12), the live tree (ISOL-14) — passes it, so a call that
  `cd`s into a subdirectory, or a folder skill's script in its own folder
  (FOLDER-6), is still confined to the tree it belongs to.
  """
  @spec run(binary(), keyword()) :: result()
  def run(command, opts \\ []) do
    # Commands must not wait on stdin.
    script = "exec </dev/null\n" <> drop_mix_env(command, opts)
    cd = Keyword.get_lazy(opts, :cd, &Workspace.root/0)

    execute(script, cd, opts)
  end

  # ISOL-24: the server has its own `MIX_ENV` (`bin/serve`'s, RESTART-8), and a
  # port's environment can only *add* to the one it inherits, so without this an
  # unjailed command would build in the server's env whatever its own project
  # asks for. Mix honours a project's `preferred_envs` only while `MIX_ENV` is
  # unset, so `mix precommit` would compile and test in the server's `dev`. The
  # unset has to be in the shell that runs the command — `env: [{"MIX_ENV",
  # false}]` is not a port option and `nil` crashes the child — and `unset` is
  # POSIX, so it works under either shell (SHELL-2). A caller that sets the value
  # itself keeps it (VERIFY-1), and a caller's `:env` reaches the command anyway
  # where it set the value itself (ISOL-8).
  defp drop_mix_env(command, opts) do
    if env_set?(opts, "MIX_ENV"), do: command, else: "unset MIX_ENV\n" <> command
  end

  # A caller's `:env` keys may arrive as strings or atoms.
  defp env_set?(opts, name) do
    Enum.any?(Keyword.get(opts, :env, []), fn {key, _value} -> to_string(key) == name end)
  end

  @doc """
  The program and its arguments that run `script` in `cd`: the jail where one
  can be built (ISOL-2), otherwise the shell (SHELL-2), with the priority
  wrapper in front (PRIO-1, PRIO-3).

  `run/2` starts a command with it, and a terminal session starts its own
  process tree with it too (TERM-7): one definition of the jail and of the
  priority, so a change to either reaches the terminal as well, and a terminal
  is confined exactly like a command instead of by a second copy of the same
  arguments.

  The jail holds the tree the call belongs to — `opts[:workspace]`, or `cd`
  when the caller names none (ISOL-13) — and `--chdir` is `cd`, the directory
  the call runs in (WD-1).
  """
  @spec argv(binary(), binary(), keyword()) :: {binary(), [binary()]}
  def argv(script, cd, opts \\ []) do
    {exe, args} =
      if jailed?(opts) do
        {bwrap(), jail_args(script, cd, opts)}
      else
        {shell(opts), ["-c", script]}
      end

    # PRIO-1, PRIO-3: the command starts below the server's own CPU and I/O
    # priority, so a compile or a suite doesn't take the machine from the UI and
    # the agent loops. It is a prefix on the executable rather than a wrapper
    # around the command: `nice` and `ionice` `exec`, so the process started
    # here is still the session and process group leader whose group the
    # timeout kills (SHELL-3), and everything the command starts inherits the
    # priority. The jail is around the command either way: the prefix is set on
    # the `bwrap` process and inherited by what it starts (ISOL-10).
    Priority.spawn_argv(exe, args, Keyword.get(opts, :priority, []))
  end

  @doc """
  The environment a spawned port gets from `opts[:env]`, as the charlists
  `Port.open/2` takes.

  A jailed command's environment is built by the jail's own `--setenv`
  arguments instead (ISOL-8); this is what an unjailed command and a terminal
  session's port are given, so both take their environment from the same place.
  """
  @spec port_env(keyword()) :: [{charlist(), charlist()}]
  def port_env(opts \\ []) do
    for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), to_charlist(v)}
  end

  defp execute(script, cd, opts) do
    timeout = Keyword.get(opts, :timeout, :timer.seconds(60))
    deadline = System.monotonic_time(:millisecond) + timeout
    {exe, args} = argv(script, cd, opts)
    port = open(exe, args, cd, opts)

    watched(port, fn -> collect(port, buffer(opts), deadline) |> skipped(opts) end)
  end

  # SHELL-12: a command never outlives the process waiting on it. A watcher of
  # its own monitors that process while `fun` waits on the port; if the process
  # exits first — a stopped turn (SESS-43), a deleted chat, a crash — the port
  # closes with it but the command doesn't, so the watcher kills its group. The
  # watcher holds the OS pid, since the port is gone by then. A run that ends on
  # its own tells the watcher, which then goes without killing anything.
  defp watched(port, fun) do
    caller = self()

    watcher =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> spawn(fn -> watch(caller, os_pid) end)
        nil -> nil
      end

    try do
      fun.()
    after
      if watcher, do: send(watcher, :done)
    end
  end

  # A caller already gone when the monitor is set is reported `:noproc` at
  # once, so that command is killed too.
  defp watch(caller, os_pid) do
    ref = Process.monitor(caller)

    receive do
      :done -> :ok
      {:DOWN, ^ref, :process, ^caller, _reason} -> kill_group(os_pid)
    end
  end

  defp open(exe, args, cd, opts) do
    # Spawned directly: the VM makes a port program its own session and process
    # group leader, so `kill -PGID` in `kill/1` reaches the command and
    # everything it started (SHELL-3). A `setsid` wrapper must not go here —
    # `setsid` forks when it is already a group leader, and the pid the port
    # reports would then be the wrapper's, whose group holds the command
    # itself only (a timeout killed the server's child and leaked the command).
    # A killed jail takes its pid namespace with it (ISOL-10).
    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: args,
      cd: cd,
      env: port_env(opts)
    ])
  end

  ## The jail

  defp jail_args(script, cd, opts) do
    binds = bind_args(workspace(cd, opts))

    [
      "--die-with-parent",
      "--unshare-pid",
      "--unshare-uts",
      "--unshare-ipc",
      "--unshare-cgroup-try",
      "--clearenv"
    ] ++
      setenv_args(Keyword.get(opts, :env, [])) ++
      ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"] ++
      read_only_args(@toolchain) ++
      home_args() ++
      binds ++
      ["--chdir", cd, "--", shell(opts), "-c", script]
  end

  # ISOL-13: the tree the jail holds — the workspace the call belongs to, which
  # is the `cd` when the caller names none.
  defp workspace(cd, opts) do
    case Keyword.get(opts, :workspace) do
      nil -> cd
      path -> Path.expand(path)
    end
  end

  # The environment is rebuilt, not inherited: nothing else reaches a command,
  # so a key in the server's own environment can't leak through `env` (ISOL-8).
  defp setenv_args(env) do
    extra = Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)

    inherited =
      for name <- @env_allowlist, value = System.get_env(name), value, do: {name, value}

    inherited
    |> Map.new()
    |> Map.merge(extra)
    |> Enum.flat_map(fn {name, value} -> ["--setenv", name, value] end)
  end

  defp read_only_args(dirs) do
    Enum.flat_map(dirs, fn dir ->
      # `/lib`, `/bin` and `/sbin` are symlinks on a merged-/usr system.
      if File.dir?(dir), do: ["--ro-bind", dir, dir], else: []
    end)
  end

  # mix keeps its archives and its lock in `$HOME/.mix`, which has to be
  # writable (ISOL-4). The browser the real-browser tests drive lives in the
  # user's cache, bound read-only so a jailed `mix test --only real_browser`
  # works; it holds browsers, not secrets, and nothing else in the cache is
  # bound. Nothing else under the home directory is bound either — only what
  # these two and `playwright_args/0` name — so a credential store anywhere else
  # in it doesn't exist inside the jail (ISOL-5).
  defp home_args do
    case System.get_env("HOME") do
      nil -> []
      home -> ["--dir", home] ++ mix_args(home) ++ browser_args(home) ++ playwright_args()
    end
  end

  defp bind_try(path, flag), do: [flag, path, path]

  defp mix_args(home), do: bind_try(Path.join(home, ".mix"), "--bind-try")

  defp browser_args(home) do
    cache = Path.join([home, ".cache", "ms-playwright"])

    if File.dir?(cache), do: ["--ro-bind", cache, cache], else: []
  end

  # The Playwright CLI is user-wide (BROWSER-2), so a jailed browser run has to
  # reach it: the package the driver starts (`playwright/cli.js`), and
  # `playwright-core` beside it for the install that hoisted it there rather
  # than nesting it inside the package. Both are bound read-only — packages, not
  # secrets — and nothing else of `~/.local` is bound, so `~/.local/bin`,
  # `~/.local/share` and the rest stay absent (ISOL-5, ISOL-26).
  defp playwright_args do
    Enum.flat_map(["playwright", "playwright-core"], fn package ->
      path = Path.join([playwright_dir(), "node_modules", package])

      if File.dir?(path), do: ["--ro-bind", path, path], else: []
    end)
  end

  # ISOL-13: what the jail holds follows from the workspace the call belongs to —
  # the tree itself, bound read-write, and never its parent (ISOL-6).
  defp bind_args(workspace) do
    live = Workspace.real_location(Workspace.runtime_root())
    real = Workspace.real_location(workspace)

    cond do
      real == :unresolvable ->
        ["--bind", workspace, workspace]

      real == live ->
        # The live tree itself, for a chat that works in it (DEPLOY-1) and for
        # the deploy's own steps (ISOL-14). Elia's data is masked with an empty
        # tmpfs *after* the tree is bound — bubblewrap mounts in argument order,
        # so the mask wins (ISOL-6).
        ["--bind", workspace, workspace] ++ mask_args(workspace)

      inside?(real, live) ->
        # A worktree a chat made inside the live tree (DEPLOY-28): its own tree
        # and the repository's git directory behind its `.git` pointer file
        # (ISOL-4) — the live tree around it is not bound, so `.elia/sessions`
        # and the other chats' worktrees are not in the jail (ISOL-6).
        ["--bind", workspace, workspace] ++ git_args(workspace)

      true ->
        # Another project (PROJ-12): its own folder is all it needs.
        ["--bind", workspace, workspace]
    end
  end

  # Elia's data under the live tree is masked with an empty tmpfs (ISOL-6): the
  # sessions and the settings database live there, and a jail holds neither.
  defp mask_args(live) do
    data = Path.join(live, ".elia")
    if File.exists?(data), do: ["--tmpfs", data], else: []
  end

  # ISOL-4: a workspace that is a linked git worktree — one a chat made inside
  # its project's folder (DEPLOY-28) — comes with the repository's git directory
  # behind its `.git` pointer file, read-write: the worktree's own directory,
  # which holds its index, HEAD and in-progress rebase or merge, and the common
  # directory it shares with the repository, where the objects, the refs and the
  # logs are. A commit, a rebase and the fast-forward of `master` need both
  # (ISOL-3, DEPLOY-13). A workspace whose `.git` is a directory — the live tree
  # itself, another project — is bound whole with the workspace, so it needs
  # nothing here.
  defp git_args(workspace) do
    workspace
    |> git_dirs()
    |> Enum.uniq()
    |> Enum.flat_map(fn dir -> ["--bind-try", dir, dir] end)
  end

  defp git_dirs(workspace) do
    with {:ok, text} <- File.read(Path.join(workspace, ".git")),
         [_, dir] <- Regex.run(~r/^gitdir:[ \t]*(.+?)[ \t]*$/m, text) do
      gitdir = Path.expand(dir, workspace)
      [gitdir | common_dirs(gitdir)]
    else
      _ -> []
    end
  end

  # A linked worktree's git directory names the directory it shares with the
  # repository in a `commondir` file, relative to itself.
  defp common_dirs(gitdir) do
    case File.read(Path.join(gitdir, "commondir")) do
      {:ok, text} -> [Path.expand(String.trim(text), gitdir)]
      {:error, _reason} -> []
    end
  end

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp bwrap do
    case Application.get_env(:elia, __MODULE__, [])[:bwrap] do
      nil -> System.find_executable("bwrap")
      path -> System.find_executable(path)
    end
  end

  # A command that wanted a jail and didn't get one says so, so a run that
  # wasn't isolated never looks like one that was (ISOL-12).
  defp skipped(result, opts) do
    if wanted?(opts) and not available?() do
      notice = @jail_skipped_notice <> "\n"

      case result do
        {:ok, output, status} -> {:ok, notice <> output, status}
        {:timeout, output} -> {:timeout, notice <> output}
      end
    else
      result
    end
  end

  ## Collecting

  defp collect(port, buf, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        buf = add(buf, data)

        # SHELL-11: the timeout is a deadline for the whole run, not a quiet
        # period. It is checked here as well as in the `after` below, because a
        # command that keeps writing fills this receive: an endless loop that
        # prints must still end at the deadline rather than run until the VM
        # runs out of memory.
        if System.monotonic_time(:millisecond) >= deadline do
          kill(port)
          {:timeout, output(buf)}
        else
          collect(port, buf, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:ok, output(buf), status}
    after
      remaining ->
        kill(port)
        {:timeout, output(buf)}
    end
  end

  # SHELL-13: what a run holds of the output. Uncapped, every byte, as iodata.
  # Capped at `max` characters, the start and the end that `truncate/2` can
  # keep — `limit` bytes each, enough for `max / 2` characters of up to four
  # bytes — and only a count of the bytes in between, which are dropped as
  # they arrive.
  defp buffer(opts) do
    case Keyword.get(opts, :max_output) do
      nil -> {:all, []}
      max -> %{max: max, limit: 2 * max, head: "", tail: "", dropped: 0}
    end
  end

  defp add({:all, acc}, data), do: {:all, [acc | data]}
  defp add(buf, ""), do: buf

  defp add(%{head: head, limit: limit} = buf, data) when byte_size(head) < limit do
    {now, rest} = split_at(data, limit - byte_size(head))
    add(%{buf | head: head <> now}, rest)
  end

  defp add(%{tail: tail, limit: limit, dropped: dropped} = buf, data) do
    tail = tail <> data
    over = byte_size(tail) - limit

    if over > 0,
      do: %{buf | tail: binary_part(tail, over, limit), dropped: dropped + over},
      else: %{buf | tail: tail}
  end

  defp split_at(data, n) when byte_size(data) <= n, do: {data, ""}
  defp split_at(data, n), do: {binary_part(data, 0, n), binary_part(data, n, byte_size(data) - n)}

  defp output({:all, acc}), do: IO.iodata_to_binary(acc)

  # Nothing dropped: the whole output, cut as `truncate/2` always cut it. Some
  # dropped: the same cut, with the dropped bytes counted as characters, so the
  # number in the marker may overstate but never understate what was removed.
  defp output(%{head: head, tail: tail, dropped: 0, max: max}), do: truncate(head <> tail, max)

  defp output(%{head: head, tail: tail, dropped: dropped, max: max}) do
    half = div(max, 2)
    length = String.length(head) + dropped + String.length(tail)
    String.slice(head, 0, half) <> marker(length - max) <> String.slice(tail, -half, half)
  end

  @doc """
  Kills the process `port` started and everything it started (SHELL-3).

  `Port.info/2` gives the pid of the process the VM spawned, which is a session
  and process group leader (`run/2` spawns no wrapper around it), so the
  negative pid reaches the shell, every process of a pipeline and their
  children. `--` keeps the negative pid from being read as an option; the pid
  itself is killed too, in case the group is already gone.

  A terminal session stops its own tree with it (TERM-3), so the kill that ends
  a session is the same one a timed-out command gets — and, with the jail on, it
  takes the pid namespace with it (ISOL-10).
  """
  @spec kill(port()) :: :ok
  def kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid), do: kill_group(pid)
    :ok
  end

  defp kill_group(pid) do
    System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    :ok
  end

  @doc """
  The options every git command the harness runs itself goes first with
  (ISOL-30): no hooks and no filesystem monitor, so a harness git call never
  runs code the repository's files name. A chat's own git, through the `shell`
  tool, doesn't get them.
  """
  @spec harness_git_flags() :: [String.t()]
  def harness_git_flags, do: ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]

  @doc "Shortens `output` to `max` characters by cutting out the middle."
  def truncate(output, max) do
    length = String.length(output)

    if length > max do
      half = div(max, 2)

      String.slice(output, 0, half) <> marker(length - max) <> String.slice(output, -half, half)
    else
      output
    end
  end

  defp marker(removed), do: "\n... [#{removed} characters truncated] ...\n"
end
