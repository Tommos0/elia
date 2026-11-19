defmodule Elia.Skills.Shell do
  @moduledoc """
  Runs shell commands in the workspace. Every call requires user approval.

  A call's timeout is bounded (SHELL-10): `timeout_seconds` is `default_timeout`
  when the call gives none — 300s, because a compile or a whole test suite is an
  ordinary command — and never more than `max_timeout`.

      config :elia, Elia.Skills.Shell,
        default_timeout: 300,       # seconds, used when a call gives none
        max_timeout: 1_800,         # seconds, the most a call may ask for
        max_output: 30_000          # characters returned to the model
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "shell"

  @impl true
  def description, do: "Run shell commands on the user's machine."

  @impl true
  def instructions do
    """
    The shell is how you work with files: there are no file tools, so read a \
    file with a command (`cat` a short file, `sed -n '<first>,<last>p'` a \
    range), find text in the tree with the shell's own search (`grep -n`, `rg`) \
    rather than reading files one by one, and create, edit and delete a file \
    with a command of its own — a heredoc (`<<'EOF'`, quoted so nothing is \
    expanded), `sed -i` or `patch`. What a command prints is truncated like any \
    other command's output when it is long, and a change to a file is reviewed \
    as the command that makes it: the user approves the command as it stands, \
    so make it one readable command that says what it changes, and edit the \
    lines you have read rather than rewriting a file whole. Use the `shell` \
    tool to run programs and inspect the machine as well. The user approves \
    each command before it runs, so prefer one clear command over many small \
    ones. Commands run non-interactively (stdin is empty) with `bash -c` where \
    bash is installed, and POSIX `sh -c` otherwise, in the chat's working \
    directory — the chat's project folder (PROJ-12) until the `cd` tool moves \
    it (WD-1, WD-9), which changes what a relative path in a command names. \
    Prefer POSIX constructs so a command works under either: bash-only syntax \
    such as `${PIPESTATUS[0]}`, `[[ ... ]]`, arrays and `set -o pipefail` fails \
    where the shell is `sh`. After a pipeline, `$?` is the status of its last \
    command only, so a failing `mix test | tail` can look like a success.

    A command runs in a jail by default: a fresh mount namespace that holds the \
    workspace and the toolchain and nothing else. The settings database, the \
    saved conversations and the user's credentials (`~/.ssh`, \
    `~/.git-credentials`, `~/.config/gh`, `~/.netrc`) are not in it, so a \
    command that can't find them is expected, not broken — with the jail on \
    nothing reaches them, and that is the boundary rather than a reason to look \
    for another way in. In a chat whose jail the user turned off, commands run \
    unjailed, on the whole machine, and what an approved command reads or \
    changes is the whole of it.

    A command also runs at a lower scheduling priority than the server, on the \
    CPU (`nice`) and on the disk (`ionice`), so a compile or a test suite \
    doesn't take the machine from the UI and the agent loops that drive them. \
    On a busy machine such a command therefore takes longer than it would on an \
    idle one, which is expected, not a failure; timings from one are not a \
    measure of speed.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "shell",
        description:
          "Run a command with `bash -c` where bash is installed, POSIX `sh -c` " <>
            "otherwise, and return its combined stdout/stderr and exit code. " <>
            "Prefer POSIX constructs: bash-only `${PIPESTATUS[0]}`, `[[ ... ]]`, " <>
            "arrays and `set -o pipefail` fail under `sh`. Long output is " <>
            "truncated in the middle. " <>
            "There are no file tools: read a file with `cat` or " <>
            "`sed -n '<first>,<last>p'`, find text in the tree with `grep -n` or " <>
            "`rg`, and create, edit or delete a file with a command of its own — " <>
            "the command the user approves as it stands is what changes it. " <>
            "The command runs in a jail by default, which holds the workspace and " <>
            "the toolchain and nothing else: the settings database, the saved " <>
            "conversations and the user's credentials are not in it, so a command " <>
            "that can't find them is expected, not broken. In a chat whose jail " <>
            "the user turned off, commands run unjailed. " <>
            "The command runs at a lower CPU and I/O priority than the server, " <>
            "so a heavy one takes longer on a busy machine than on an idle one. " <>
            "It runs in the chat's working directory (WD-9), which is the chat's " <>
            "project folder until the `cd` tool moves it (WD-1), so a relative " <>
            "path in it reaches there.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "The shell command to run"},
            "timeout_seconds" => %{
              "type" => "integer",
              "description" =>
                "Kill the command after this many seconds. The default is " <>
                  "#{config(:default_timeout)} and the most is #{config(:max_timeout)}: a " <>
                  "larger value runs with the maximum and the result says so. Ask for more " <>
                  "for a long build, a cold compile or a whole test suite."
            }
          },
          "required" => ["command"]
        },
        approval: :required,
        run: &run/2
      }
    ]
  end

  def run(input, ctx \\ %{}) do
    # SHELL-10: what the call asked for, against the configured default and the
    # configured maximum — a call that asks for more than the maximum runs with
    # the maximum, and the result (SHELL-4) says which ceiling it hit.
    case Elia.Shell.resolve_timeout(
           input["timeout_seconds"],
           config(:default_timeout),
           config(:max_timeout)
         ) do
      {:ok, seconds, asked} ->
        timeout = :timer.seconds(seconds)

        result(
          Elia.Shell.run(input["command"],
            # SHELL-2, WD-9: the command runs in the chat's working directory,
            # which is its workspace root until `cd` changes it (WD-3).
            cd: dir(ctx),
            # ISOL-13: the jail holds the tree the call belongs to — the chat's
            # workspace (PROJ-12) — not the directory it runs in, so a call that
            # `cd`s into a subdirectory is still confined to the whole tree.
            workspace: workspace(ctx),
            env: chat_env(ctx),
            timeout: timeout,
            jail: ctx[:jail],
            max_output: max_output()
          ),
          timeout,
          asked: asked
        )

      {:error, :invalid} ->
        {:error,
         "timeout_seconds must be a whole number of seconds of at least 1 " <>
           "(got #{inspect(input["timeout_seconds"])}); the default is " <>
           "#{config(:default_timeout)}s and the most is #{config(:max_timeout)}s."}
    end
  end

  # SHELL-2, WD-9: the command runs in the chat's working directory — its
  # workspace root until `cd` changes it (PROJ-12: the folder of the chat's
  # project, the live tree for a chat in Elia's own project, DEPLOY-1) — else
  # Elia's own root.
  defp dir(ctx), do: Elia.Workdir.of(ctx)

  # ISOL-13: what the call's jail holds is the chat's workspace — the tree it
  # belongs to (PROJ-12) — not the directory it runs in, so a call that `cd`s
  # into a subdirectory is confined to the whole tree all the same.
  defp workspace(ctx), do: ctx[:workspace] || Elia.Workspace.root()

  # SHELL-14: a command is told which chat it belongs to, so a chat can name the
  # worktree and the branch it makes for itself (DEPLOY-28) without being told
  # its own id. A step the harness runs for no chat gets no such variable
  # (DEPLOY-18).
  defp chat_env(ctx) do
    case ctx[:session_id] do
      id when is_binary(id) and id != "" -> [{"ELIA_CHAT_ID", id}]
      _no_chat -> []
    end
  end

  @doc """
  The tool result for a run: the combined output and its exit status (SHELL-4).
  `timeout` is in milliseconds, as `Elia.Shell.run/2` takes it; `opts[:asked]`
  is the timeout the call asked for in seconds when it was clamped to the
  configured maximum (SHELL-10), so a timeout result says which ceiling it hit.
  """
  def result(run_result, timeout, opts \\ []) do
    case run_result do
      {:ok, output, 0} ->
        {:ok, format(output, 0)}

      {:ok, output, status} ->
        {:error, format(output, status)}

      {:timeout, output} ->
        {:error, format(output, Elia.Shell.timeout_status(timeout, opts[:asked]))}
    end
  end

  # SHELL-5, SHELL-13: the run was given `max_output/0`, so its output is
  # already cut; cutting it here again would cut out its marker.
  defp format(output, status), do: "#{output}\n[exit: #{status}]"

  @doc """
  The most characters of a command's output a tool result holds (SHELL-5): what
  a run whose output goes to the model passes to `Elia.Shell.run/2` as
  `:max_output` (SHELL-13).
  """
  def max_output, do: config(:max_output)

  defp config(key) do
    Keyword.merge(
      [default_timeout: 300, max_timeout: 1_800, max_output: 30_000],
      Application.get_env(:elia, __MODULE__, [])
    )[key]
  end
end
