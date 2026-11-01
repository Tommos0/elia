defmodule Elia.Skills.SelfModification do
  @moduledoc """
  Changing Elia's own code, behind the guardrails (PROJ-17, SKILL-9): the
  approval rules, the checkpoint per turn, `hot_reload` and `rollback`, and the
  spec-driven workflow. A chat has this skill only when its project is Elia's
  own; other projects get `Elia.Skills.Harness` alone (PROJ-16).
  """

  @behaviour Elia.Skill

  alias Elia.{Checkpoint, Harness, Workspace}

  @impl true
  def name, do: "self-modification"

  @impl true
  def description, do: "Change Elia's own code safely, behind the guardrails."

  @impl true
  def instructions do
    """
    Changing Elixir code (`lib/`, `config/`, `test/`) needs the user's approval. \
    The workspace you work in is checkpointed before your first change in each \
    turn. When you finish a turn that changed Elixir files, the harness runs \
    `mix test`; if it fails, your changes are rolled back and you are told why. \
    Run `run_tests` yourself before finishing.

    A chat in this project works in its own git worktree, not in the tree the \
    server runs from (DEPLOY-1). Running code therefore never changes while you \
    edit: an Elixir change takes effect only after a deploy — `hot_reload`, \
    which runs the tests, merges your branch into `live` and reloads the \
    running app, or the restart button, which also restarts the server \
    (DEPLOY-6, DEPLOY-7). Make all the edits for a change, run `run_tests`, then \
    call `hot_reload` and tell the user the change is live. Never edit \
    `lib/elia/harness.ex`, `lib/elia/checkpoint.ex` or `lib/elia/workspace.ex` \
    to weaken the guardrails. `list_checkpoints` shows recent checkpoints and \
    `rollback` undoes a change that went wrong.

    This project is spec-driven: each feature has a spec in `specs/` with \
    numbered requirements (workflow and index in `specs/README.md`). Before \
    changing Elixir code, update the affected spec or add one for a new feature, \
    then implement it and cite the requirement IDs you touched in your tests \
    (e.g. `# SHELL-3`). Never renumber or reuse requirement IDs.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "hot_reload",
        description:
          "Run the full test suite, merge this chat's branch into `live`, then recompile and " <>
            "load the live tree into the running app. If tests fail, the turn's changes are " <>
            "rolled back instead and nothing is merged or loaded.",
        input_schema: %{"type" => "object", "properties" => %{}},
        approval: :required,
        run: fn _input, ctx -> Harness.hot_reload(ctx[:turn_id], workspace(ctx)) end
      },
      %Elia.Tool{
        name: "list_checkpoints",
        description: "List recent workspace checkpoints, newest first.",
        input_schema: %{"type" => "object", "properties" => %{}},
        run: fn _input, ctx -> list_checkpoints(ctx) end
      },
      %Elia.Tool{
        name: "rollback",
        description:
          "Restore the workspace to a checkpoint (default: the one taken at the start of " <>
            "this turn). The current state is checkpointed first, so this can be undone.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"checkpoint" => %{"type" => "string", "description" => "Commit sha"}}
        },
        approval: :required,
        run: &rollback/2
      }
    ]
  end

  # The workspace of the turn: the chat's own worktree in Elia's own project
  # (DEPLOY-1), Elia's own root when unset.
  defp workspace(ctx), do: ctx[:workspace] || Workspace.root()

  defp list_checkpoints(ctx) do
    case Checkpoint.list(20, workspace(ctx)) do
      [] ->
        {:ok, "No checkpoints yet."}

      list ->
        {:ok, Enum.map_join(list, "\n", &"#{String.slice(&1.sha, 0, 12)}  #{&1.at}  #{&1.label}")}
    end
  end

  defp rollback(input, ctx) do
    target = input["checkpoint"] || Checkpoint.for_turn(ctx[:turn_id])

    with target when is_binary(target) <-
           target || {:error, "No checkpoint was taken in this turn."},
         {:ok, undo} <- Checkpoint.rollback(target, workspace(ctx)) do
      Elia.Skills.reload()

      {:ok,
       "Restored #{workspace(ctx)} to #{String.slice(target, 0, 12)}. " <>
         "Undo with rollback to #{String.slice(undo, 0, 12)}. Running code is unchanged " <>
         "until hot_reload."}
    end
  end
end
