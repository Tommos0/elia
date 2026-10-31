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
    The workspace is checkpointed before your first change in each turn. When you \
    finish a turn that changed Elixir files, the harness runs `mix test`; if it \
    fails, your changes are rolled back and you are told why. Run `run_tests` \
    yourself before finishing.

    Some files are guarded because they enforce these guardrails (the list is in \
    `lib/elia/guarded.ex`); tell the user when a change touches one. Never edit \
    `lib/elia/harness.ex`, `lib/elia/checkpoint.ex` or `lib/elia/workspace.ex` \
    to weaken them. The dev server never reloads code on its own: no Elixir \
    change (guarded or not) takes effect until a successful `hot_reload` (dev \
    server only), so a multi-file edit can't break the running app halfway. Make \
    all the edits for a change, run `run_tests`, then call `hot_reload` and tell \
    the user the change is live. `list_checkpoints` shows recent checkpoints and \
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
          "Run the full test suite, then recompile and load changed Elixir code into the " <>
            "running app. If tests fail, the turn's changes are rolled back instead.",
        input_schema: %{"type" => "object", "properties" => %{}},
        approval: :required,
        run: fn _input, ctx -> Harness.hot_reload(ctx[:turn_id]) end
      },
      %Elia.Tool{
        name: "list_checkpoints",
        description: "List recent workspace checkpoints, newest first.",
        input_schema: %{"type" => "object", "properties" => %{}},
        run: fn _ -> list_checkpoints() end
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

  defp list_checkpoints do
    case Checkpoint.list() do
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
         {:ok, undo} <- Checkpoint.rollback(target) do
      Elia.Skills.reload()

      {:ok,
       "Restored #{Workspace.root()} to #{String.slice(target, 0, 12)}. " <>
         "Undo with rollback to #{String.slice(undo, 0, 12)}. Running code is unchanged " <>
         "until hot_reload."}
    end
  end
end
