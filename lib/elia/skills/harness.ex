defmodule Elia.Skills.Harness do
  @moduledoc "Tools for the agent to extend and maintain the harness itself."

  @behaviour Elia.Skill

  alias Elia.{Checkpoint, Harness, Workspace}

  @impl true
  def name, do: "harness"

  @impl true
  def description, do: "Extend Elia with new skills and safely change its own code."

  @impl true
  def instructions do
    """
    You can extend yourself. Prefer adding a folder skill over changing Elixir code:

    1. Create `skills/<name>/SKILL.md` with frontmatter (`name`, `description`) \
    followed by instructions for yourself. Optionally add `skills/<name>/tools.json` \
    with script-backed tools and the scripts they run. The format is documented in \
    `lib/elia/skills/folder.ex`.
    2. Call `reload_skills` and fix any reported errors. New tools are available \
    from your next step.

    Folder skills need no approval to write, but their tools always ask the user \
    before running.

    Changing Elixir code (`lib/`, `config/`, `test/`) needs the user's approval. \
    The workspace is checkpointed before your first change in each turn. When you \
    finish a turn that changed Elixir files, the harness runs `mix test`; if it \
    fails, your changes are rolled back and you are told why. Run `run_tests` \
    yourself before finishing. Never edit \
    `lib/elia/harness.ex`, `lib/elia/checkpoint.ex` or `lib/elia/workspace.ex` \
    to weaken these guardrails.

    Some files are guarded because they enforce these guardrails (the list is in \
    `lib/elia/guarded.ex`). In development the dev server auto-reloads ordinary \
    non-guarded Elixir changes on the next request, so web-app-only edits need no \
    `hot_reload`. A change that touches a guarded file only takes effect after a \
    successful `hot_reload` (dev server only), and while any guarded file has \
    unloaded changes the dev server pauses automatic reloading for everything, so \
    even non-guarded edits stay invisible until `hot_reload` succeeds or the \
    change is rolled back. Tell the user when a change touches guarded files.

    This project is spec-driven: each feature has a spec in `specs/` with \
    numbered requirements (workflow and index in `specs/README.md`). Before \
    changing Elixir code, update the affected spec or add one for a new feature, \
    then implement it and cite the requirement IDs you touched in your tests \
    (e.g. `# SHELL-3`). Never renumber or reuse requirement IDs. Folder skills \
    don't need a spec.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "reload_skills",
        description: "Rescan the skills folder. Returns loaded skills and any load errors.",
        input_schema: %{"type" => "object", "properties" => %{}},
        run: fn _ -> reload_skills() end
      },
      %Elia.Tool{
        name: "run_tests",
        description:
          "Run `mix test` in the workspace. `args` may hold test paths under test/ " <>
            "(optionally path:line) and the flags --failed, --stale, --trace, --seed N, " <>
            "--max-failures N, --only TAG, --exclude TAG.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"args" => %{"type" => "array", "items" => %{"type" => "string"}}}
        },
        run: fn input -> Harness.run_tests(input["args"] || []) end
      },
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

  defp reload_skills do
    %{skills: skills, errors: errors} = Elia.Skills.reload()

    loaded =
      Enum.map_join(skills, "\n", fn skill ->
        tools = Enum.map_join(skill.tools, ", ", & &1.name)
        "- #{skill.name}#{if tools != "", do: " (tools: #{tools})"}"
      end)

    case errors do
      [] ->
        {:ok, "Loaded skills:\n#{loaded}"}

      errors ->
        failed = Enum.map_join(errors, "\n", fn {folder, reason} -> "- #{folder}: #{reason}" end)
        {:error, "Loaded skills:\n#{loaded}\n\nFailed to load:\n#{failed}"}
    end
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
