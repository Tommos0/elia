defmodule Elia.Skills.Shell do
  @moduledoc """
  Runs shell commands in the workspace. Every call requires user approval.

      config :elia, Elia.Skills.Shell,
        default_timeout: 60,        # seconds
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
            "the user turned off, commands run unjailed.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "The shell command to run"},
            "timeout_seconds" => %{
              "type" => "integer",
              "description" =>
                "Kill the command after this many seconds (default #{config(:default_timeout)})"
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
    timeout = :timer.seconds(input["timeout_seconds"] || config(:default_timeout))

    result(
      Elia.Shell.run(input["command"], cd: root(ctx), timeout: timeout, jail: ctx[:jail]),
      timeout
    )
  end

  # The workspace root of the turn (PROJ-12): the chat's own worktree for a chat
  # in Elia's own project (DEPLOY-1), Elia's own root when unset.
  defp root(ctx), do: ctx[:workspace] || Elia.Workspace.root()

  @doc false
  def result(run_result, timeout) do
    case run_result do
      {:ok, output, 0} -> {:ok, format(output, 0)}
      {:ok, output, status} -> {:error, format(output, status)}
      {:timeout, output} -> {:error, format(output, "timeout after #{div(timeout, 1000)}s")}
    end
  end

  defp format(output, status),
    do: "#{Elia.Shell.truncate(output, config(:max_output))}\n[exit: #{status}]"

  defp config(key) do
    Keyword.merge(
      [default_timeout: 60, max_output: 30_000],
      Application.get_env(:elia, __MODULE__, [])
    )[key]
  end
end
