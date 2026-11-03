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
  Whether a command would run jailed: the host allows it (ISOL-20), the caller
  didn't turn it off (ISOL-16) and bubblewrap is installed (ISOL-12).
  """
  @spec jailed?(keyword()) :: boolean()
  def jailed?(opts \\ []), do: wanted?(opts) and available?()

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
    script = "exec </dev/null\n" <> command
    cd = Keyword.get_lazy(opts, :cd, &Workspace.root/0)

    {exe, args} =
      if jailed?(opts) do
        {bwrap(), jail_args(script, cd, opts)}
      else
        {shell(opts), ["-c", script]}
      end

    {exe, args} =
      case System.find_executable("setsid") do
        # Own process group, so a timeout can kill the whole pipeline. A killed
        # jail takes its pid namespace with it (ISOL-10).
        nil -> {exe, args}
        setsid -> {setsid, ["--wait", exe | args]}
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
  # writable (ISOL-4). Nothing else under the home directory is bound, so a
  # credential store anywhere else in it doesn't exist inside the jail, and an
  # empty home stands where the real one is (ISOL-5).
  defp home_args do
    case System.get_env("HOME") do
      nil -> []
      home -> ["--dir", home] ++ bind_try(Path.join(home, ".mix"), "--bind-try")
    end
  end

  defp profile(cd, opts) do
    Keyword.get(opts, :profile) || if(cd == Workspace.runtime_root(), do: :live_tree, else: :worktree)
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
        ["--bind", cd, cd] ++ mask_args(cd)

      true ->
        # A chat worktree: its own tree, the repository's git directory (the
        # worktree's `.git` is a pointer file into `<live>/.git/worktrees/<id>`,
        # whose common dir commits need), and the shared dependencies.
        ["--bind", cd, cd] ++ git_args(live) ++ deps_args(live, profile)
    end
  end

  defp mask_args(live) do
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

  defp wanted?(opts) do
    Keyword.get(opts, :jail) != false and Application.get_env(:elia, __MODULE__, [])[:jail] != false
  end

  # A command that wanted a jail and didn't get one says so, so a run that
  # wasn't isolated never looks like one that was (ISOL-12).
  defp skipped(result, opts) do
    if wanted?(opts) and not available?() do
      notice = "[jail: skipped, bubblewrap is unavailable]\n"

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

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
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
