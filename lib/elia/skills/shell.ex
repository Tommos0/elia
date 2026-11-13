defmodule Elia.Skills.Shell do
  @moduledoc """
  Runs shell commands in the workspace. Every call requires user approval.

  A call's timeout is bounded (SHELL-10): `timeout_seconds` is `default_timeout`
  when the call gives none, and never more than `max_timeout`.

      config :elia, Elia.Skills.Shell,
        default_timeout: 60,        # seconds, used when a call gives none
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
    Never use the shell to read, create or edit files (`cat`, `sed`, `echo >`, \
    scripts that rewrite files): use the file tools, which apply the workspace \
    policy. Use the `shell` tool to run programs and inspect the machine. The \
    user approves each command before it runs, so prefer one clear command over \
    many small ones. Commands run non-interactively (stdin is empty) with \
    `bash -c` where bash is installed, and POSIX `sh -c` otherwise, in the \
    workspace root. Prefer POSIX constructs so a command works under either: \
    bash-only syntax such as `${PIPESTATUS[0]}`, `[[ ... ]]`, arrays and \
    `set -o pipefail` fails where the shell is `sh`. After a pipeline, `$?` is \
    the status of its last command only, so a failing `mix test | tail` can look \
    like a success.

    A command runs in a jail by default: a fresh mount namespace that holds the \
    workspace and the toolchain and nothing else. The settings database, the \
    saved conversations and the user's credentials (`~/.ssh`, \
    `~/.git-credentials`, `~/.config/gh`, `~/.netrc`) are not in it, so a \
    command that can't find them is expected, not broken — and with the jail on \
    the file tools can't reach them either (FILE-12), so a refusal there is the \
    same policy, not a reason to look for another way in. In a chat whose jail \
    the user turned off, commands run unjailed, on the whole machine, and \
    reading outside the workspace with the file tools needs their approval.

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
            "truncated in the middle. Do not use this to read or edit files " <>
            "(cat, sed, echo >, scripts): use read_file, list_files, write_file, " <>
            "edit_file and delete_file. " <>
            "The command runs in a jail by default, which holds the workspace and " <>
            "the toolchain and nothing else: the settings database, the saved " <>
            "conversations and the user's credentials are not in it, so a command " <>
            "that can't find them is expected, not broken. In a chat whose jail " <>
            "the user turned off, commands run unjailed. " <>
            "The command runs at a lower CPU and I/O priority than the server, " <>
            "so a heavy one takes longer on a busy machine than on an idle one.",
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
          Elia.Shell.run(input["command"], cd: root(ctx), timeout: timeout, jail: ctx[:jail]),
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

  # The workspace root of the turn (PROJ-12): the chat's own worktree for a chat
  # in Elia's own project (DEPLOY-1), Elia's own root when unset.
  defp root(ctx), do: ctx[:workspace] || Elia.Workspace.root()

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

  defp format(output, status),
    do: "#{Elia.Shell.truncate(output, config(:max_output))}\n[exit: #{status}]"

  defp config(key) do
    Keyword.merge(
      [default_timeout: 60, max_timeout: 1_800, max_output: 30_000],
      Application.get_env(:elia, __MODULE__, [])
    )[key]
  end
end
