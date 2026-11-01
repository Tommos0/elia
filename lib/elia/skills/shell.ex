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
    `sh -c` in the workspace root.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "shell",
        description:
          "Run a command with `sh -c` and return its combined stdout/stderr and exit code. " <>
            "Long output is truncated in the middle. Do not use this to read or edit files " <>
            "(cat, sed, echo >, scripts): use read_file, write_file and edit_file.",
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
    # The command may change files, so snapshot the workspace first (PROJ-14:
    # only Elia's own project is checkpointed).
    with :ok <- ensure_checkpoint(ctx) do
      timeout = :timer.seconds(input["timeout_seconds"] || config(:default_timeout))
      result(Elia.Shell.run(input["command"], cd: root(ctx), timeout: timeout), timeout)
    end
  end

  # The workspace root of the turn (PROJ-12): the chat's own worktree for a chat
  # in Elia's own project (DEPLOY-1), Elia's own root when unset.
  defp root(ctx), do: ctx[:workspace] || Elia.Workspace.root()

  # PROJ-14: only Elia's own project is checkpointed — in the workspace the
  # chat works in, its own worktree (DEPLOY-1).
  defp ensure_checkpoint(ctx) do
    if Elia.Projects.harness_ctx?(ctx),
      do: Elia.Checkpoint.ensure(ctx[:turn_id], root(ctx)),
      else: :ok
  end

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
