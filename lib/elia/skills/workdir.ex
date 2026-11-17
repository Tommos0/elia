defmodule Elia.Skills.Workdir do
  @moduledoc """
  The chat's working directory (spec: `specs/working-directory.md`). The
  built-in skill `workdir` gives a chat `cd`, so the model can move a chat into
  part of its tree once and name paths relative to it from then on: the file
  tools (FILE-1) and the `shell` call (SHELL-2) resolve a relative path against
  it, and it is saved with the chat (STORE-46, WD-2).

  It is not a shell: it names one directory, and it needs no approval, since it
  changes no file and grants no reach of its own (WD-6).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "workdir"

  @impl true
  def description do
    "Set the chat's working directory: what relative paths in the file tools and the shell " <>
      "resolve against."
  end

  @impl true
  def instructions do
    """
    A chat works in one directory at a time: a relative path you give a file \
    tool or the `shell` tool resolves against it, and it starts as the \
    workspace root. `cd` changes it — with a directory, absolute or relative to \
    the current one — and `cd` with no argument reports where the chat is. It \
    therefore saves you the prefix a deep path would repeat, after one call.

    A result still names a path relative to the workspace root, so a path you \
    read in one is not a relative one: it is the root's. `cd` reaches no further \
    than the workspace — a directory outside it is refused — and needs no \
    approval. It takes effect from the next step: the calls of one step run at \
    the same time, so nothing else in the same batch moves with it.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "cd",
        description:
          "Set this chat's working directory — what a relative path in the file tools and " <>
            "the shell resolves against — to `path`, absolute or relative to the current " <>
            "one, and return the new directory relative to the workspace root. With no " <>
            "`path`, change nothing and return where the chat is. A directory outside the " <>
            "workspace, one that is missing and one that isn't a directory are refused. No " <>
            "approval is needed. A change applies from the next step, not to calls already " <>
            "running beside it.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" =>
                "Directory to change to; omit it to report the current working directory"
            }
          },
          "required" => []
        },
        # WD-6: moving the chat's directory changes no file and grants no reach,
        # so it never pauses the turn for approval.
        approval: :never,
        run: &cd/2
      }
    ]
  end

  @doc """
  The `cd` tool. Its result names the directory relative to the workspace root
  (WD-3), or where the chat already is when it names none (WD-4); a refusal is
  the session's message (WD-5).
  """
  def cd(input, ctx \\ %{}) do
    case ctx[:session_id] do
      # WD-12: a skill run outside a chat has no working directory to move.
      nil ->
        {:error, "There is no chat to change the working directory of."}

      id ->
        case Elia.Agent.set_cwd(id, input["path"]) do
          {:ok, dir} -> {:ok, "Working directory: #{dir}"}
          {:error, message} -> {:error, message}
        end
    end
  end
end
