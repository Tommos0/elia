defmodule Elia.Shell do
  @moduledoc """
  Runs OS commands with a timeout, empty stdin and combined output.

  Commands run with `bash -c` where bash is installed, otherwise with POSIX
  `sh -c` (SHELL-2), so bash-only syntax works only where bash is present.

  A command runs inside a bubblewrap jail unless it is turned off (ISOL): a
  fresh mount namespace holding the workspace, the toolchain and nothing else,
  and a fresh pid namespace whose `/proc` doesn't show the server. So a command
  can't reach the settings database with the provider API keys (CONF-1), the
  saved conversations under `.elia/sessions` or the user's credentials
  (ISOL-5), and can't read the server's memory (ISOL-9). `jail: false` — the
  chat's own setting (ISOL-16) — or a host without bubblewrap (ISOL-12,
  ISOL-20) runs the command directly, as it did before.
  """
  alias Elia.Workspace

  @type result :: {:ok, binary(), non_neg_integer()} | {:timeout, binary()}
  @type profile :: :worktree | :deps_sync | :live_tree

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
  Whether a jailed command in the workspace `cd` can reach the absolute path
  `abs` (ISOL-25): the workspace, plus, for a chat worktree, the trees its
  profile also binds there — the repository's git directory and the shared
  `deps` (ISOL-4, ISOL-13) — and never the `.elia` a `:live_tree` is masked with
  (ISOL-6). Another project's folder reaches no further than itself.

  Symlinks are followed (WS-5), so a link inside the workspace that points out
  of it is not reachable either. The toolchain and `$HOME/.mix` (ISOL-4) are
  bound too, but they are for running a program, not for reading, so they are
  not part of this reach.
  """
  @spec reachable?(binary(), binary(), keyword()) :: boolean()
  def reachable?(abs, cd, opts \\ []) do
    profile = profile(cd, opts)
    live = Workspace.real_location(Workspace.runtime_root())
    cd = Workspace.real_location(cd)
    abs = Workspace.real_location(abs)

    cond do
      not inside?(cd, live) ->
        inside?(abs, cd)

      cd == live ->
        inside?(abs, cd) and
          (profile == :deps_sync or not inside?(abs, Path.join(live, ".elia")))

      true ->
        inside?(abs, cd) or bound?(abs, live)
    end
  end

  # What a chat worktree's profile binds besides the worktree itself (ISOL-13).
  defp bound?(abs, live) do
    Enum.any?([Path.join(live, "deps"), Path.join(live, ".git")], fn path ->
      inside?(abs, Workspace.real_location(path))
    end)
  end

  @doc """
  Runs `command` with the shell from `shell/1`.

  Options: `:cd` (default `Elia.Workspace.root/0`), `:env` (list of string
  pairs), `:shell` (path or name, to override the shell), `:timeout` in
  milliseconds (default 60s), `:jail` (`false` runs the command unjailed,
  ISOL-16) and `:profile` (`:deps_sync` for the harness's own dependency
  compile, ISOL-7; otherwise it follows `:cd`, ISOL-13).
  """
  @spec run(binary(), keyword()) :: result()
  def run(command, opts \\ []) do
    # Commands must not wait on stdin.
    script = "exec </dev/null\n" <> drop_mix_env(command, opts)
    cd = Keyword.get_lazy(opts, :cd, &Workspace.root/0)

    # ISOL-7: a worktree's compile is a harness step, and the command that needs
    # one waits for it — including one already running, since `Elia.DepsSync`
    # lets a single sync of a shared `deps` run at a time.
    case sync_deps(cd, opts) do
      :ok -> execute(script, cd, opts)
      {:error, reason} -> with_notice(execute(script, cd, opts), unsynced(reason))
    end
  end

  # ISOL-24: the server has its own `MIX_ENV` (`bin/serve`'s, RESTART-8), and a
  # port's environment can only *add* to the one it inherits, so without this an
  # unjailed command would build in the server's env whatever its own project
  # asks for. Mix honours a project's `preferred_envs` only while `MIX_ENV` is
  # unset, so `mix precommit` would compile and test in the server's `dev`. The
  # unset has to be in the shell that runs the command — `env: [{"MIX_ENV",
  # false}]` is not a port option and `nil` crashes the child — and `unset` is
  # POSIX, so it works under either shell (SHELL-2). A caller that sets the value
  # itself keeps it (VERIFY-1, ISOL-7), and a jailed command inherits no
  # environment at all (ISOL-8).
  defp drop_mix_env(command, opts) do
    if env_set?(opts, "MIX_ENV"), do: command, else: "unset MIX_ENV\n" <> command
  end

  # A caller's `:env` keys may arrive as strings or atoms.
  defp env_set?(opts, name) do
    Enum.any?(Keyword.get(opts, :env, []), fn {key, _value} -> to_string(key) == name end)
  end

  defp execute(script, cd, opts) do
    # Spawned directly: the VM makes a port program its own session and process
    # group leader, so `kill -PGID` in `kill/1` reaches the command and
    # everything it started (SHELL-3). A `setsid` wrapper must not go here —
    # `setsid` forks when it is already a group leader, and the pid the port
    # reports would then be the wrapper's, whose group holds the command
    # itself only (a timeout killed the server's child and leaked the command).
    # A killed jail takes its pid namespace with it (ISOL-10).
    {exe, args} =
      if jailed?(opts) do
        {bwrap(), jail_args(script, cd, opts)}
      else
        {shell(opts), ["-c", script]}
      end

    env = for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), to_charlist(v)}

    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: cd,
        env: env
      ])

    timeout = Keyword.get(opts, :timeout, :timer.seconds(60))

    port
    |> collect([], System.monotonic_time(:millisecond) + timeout)
    |> skipped(opts)
  end

  ## The jail

  # ISOL-7: before a command runs in a worktree whose `mix.lock` changed since it
  # was last synced, the harness compiles the shared tree itself, under the
  # `:deps_sync` profile. Only the `:worktree` profile: that run must never
  # re-enter this, and the live tree's own profile has nothing to sync.
  defp sync_deps(cd, opts) do
    if profile(cd, opts) == :worktree, do: Elia.DepsSync.sync_worktree(cd), else: :ok
  end

  # ISOL-23: a failed sync says so in the result of the command that asked for
  # it, and the command still runs. Refusing it would leave the chat unusable
  # over a dependency it may not need — `git commit` is not a compile — while a
  # command that does need the dependencies fails with its own error, which says
  # more than a refusal. Nothing was remembered, so the next command tries the
  # sync again (ISOL-7).
  defp with_notice({:ok, output, status}, notice), do: {:ok, notice <> output, status}
  defp with_notice({:timeout, output}, notice), do: {:timeout, notice <> output}

  defp unsynced(reason) do
    "The shared dependencies could not be synced:\n" <> reason <> "\n"
  end

  defp jail_args(script, cd, opts) do
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
      bind_args(cd, profile(cd, opts)) ++
      ["--chdir", cd, "--", shell(opts), "-c", script]
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
  # bound. Nothing else under the home directory is bound either, so a
  # credential store anywhere else in it doesn't exist inside the jail (ISOL-5).
  defp home_args do
    case System.get_env("HOME") do
      nil -> []
      home -> ["--dir", home] ++ mix_args(home) ++ browser_args(home)
    end
  end

  defp mix_args(home), do: bind_try(Path.join(home, ".mix"), "--bind-try")

  defp browser_args(home) do
    cache = Path.join([home, ".cache", "ms-playwright"])

    if File.dir?(cache), do: ["--ro-bind", cache, cache], else: []
  end

  defp profile(cd, opts) do
    Keyword.get(opts, :profile) ||
      if(cd == Workspace.runtime_root(), do: :live_tree, else: :worktree)
  end

  defp bind_args(cd, profile) do
    live = Workspace.runtime_root()

    cond do
      not inside?(cd, live) ->
        # Another project (PROJ-12): its own folder is all it needs.
        ["--bind", cd, cd]

      cd == live ->
        # The live tree itself, for a chat that works in it (DEPLOY-14) and for
        # the deploy's own suite run (ISOL-14). Elia's data is masked with an
        # empty tmpfs *after* the tree is bound — bubblewrap mounts in argument
        # order, so the mask wins (ISOL-6).
        ["--bind", cd, cd] ++ mask_args(cd, profile)

      true ->
        # A chat worktree: its own tree, the repository's git directory (the
        # worktree's `.git` is a pointer file into `<live>/.git/worktrees/<id>`,
        # whose common dir commits need), and the shared dependencies.
        ["--bind", cd, cd] ++ git_args(live) ++ deps_args(live, profile)
    end
  end

  # Elia's data under the live tree is masked with an empty tmpfs (ISOL-6) — but
  # not for the harness's own `:deps_sync` steps, whose bind list keeps the live
  # tree reachable as it is (ISOL-13): a chat's worktree is created *inside*
  # `.elia/worktrees`, and a masked `.elia` would swallow it.
  defp mask_args(_live, :deps_sync), do: []

  defp mask_args(live, _profile) do
    data = Path.join(live, ".elia")
    if File.exists?(data), do: ["--tmpfs", data], else: []
  end

  defp git_args(live) do
    git = Path.join(live, ".git")
    ["--bind-try", git, git]
  end

  # The shared dependency tree is read-only for a tool call (ISOL-7): a compile
  # can want to write there, so the harness compiles it itself under
  # `:deps_sync`.
  defp deps_args(live, :deps_sync), do: bind_try(Path.join(live, "deps"), "--bind-try")
  defp deps_args(live, _profile), do: bind_try(Path.join(live, "deps"), "--ro-bind-try")

  defp bind_try(path, flag), do: [flag, path, path]

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

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} -> collect(port, [acc | data], deadline)
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(acc), status}
    after
      remaining ->
        kill(port)
        {:timeout, IO.iodata_to_binary(acc)}
    end
  end

  # Kills the command and everything it started (SHELL-3). `Port.info/2` gives
  # the pid of the process the VM spawned, which is a session and process group
  # leader (`run/2` spawns no wrapper around it), so the negative pid reaches
  # the shell, every process of a pipeline and their children. `--` keeps the
  # negative pid from being read as an option; the pid itself is killed too, in
  # case the group is already gone.
  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end
  end

  @doc "Shortens `output` to `max` characters by cutting out the middle."
  def truncate(output, max) do
    length = String.length(output)

    if length > max do
      half = div(max, 2)

      String.slice(output, 0, half) <>
        "\n... [#{length - max} characters truncated] ...\n" <>
        String.slice(output, -half, half)
    else
      output
    end
  end
end
