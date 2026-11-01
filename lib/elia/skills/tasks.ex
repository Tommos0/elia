defmodule Elia.Skills.Tasks do
  @moduledoc """
  Sub-tasks (spec: `specs/subtasks.md`). The built-in skill `tasks` gives a
  chat `spawn_task`; sessions started by it get `child_skills/0` instead, which
  swaps `tasks` for the skill `task` with `finish_task` (SUBTASK-1).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "tasks"

  @impl true
  def description, do: "Hand a focused piece of work to a sub-task chat with a fresh context."

  @impl true
  def instructions do
    """
    `spawn_task` starts a separate chat (a sub-task) with a fresh context, waits \
    until it finishes and returns its result. Use it for a self-contained step of \
    a long job (for example: implement one spec, then test it) so this chat's \
    context isn't filled with the details. The sub-task does not see this chat, \
    so the `brief` is its whole input: give the goal, the files and specs to \
    read first, the constraints, and what "done" means (including that it \
    should commit). One sub-task runs at a time, and it can't start sub-tasks of \
    its own. The git working tree must be clean (commit your own changes first). \
    The user approves each spawn, and approves the sub-task's own tool calls in \
    its chat.

    The result is JSON: `status` (`done`, `blocked`, `failed`, `unfinished` or \
    `cancelled`), `reason` (`budget`, `cancelled`, `crashed`, `error` or null), \
    `summary`, `task_id`, `commit` (new HEAD, or null), `files` (changed paths) \
    and `questions`. Check it before relying on it, for example by reading the \
    changed files, and tell the user what happened.

    A sub-task that isn't `done` also reports `start_commit` and `tree_clean` \
    (false when it left uncommitted changes). The harness never undoes its work \
    by itself. To discard it, call `reset_task` with the `task_id`: it resets the \
    workspace to `start_commit` (the user approves it first). Offer this to the \
    user rather than doing it by default, since the sub-task's partial work may \
    be worth keeping or finishing.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "spawn_task",
        description:
          "Run a sub-task in a new chat and wait for its result (JSON with status, summary, " <>
            "commit, files, questions). The brief must be self-contained.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string", "description" => "Short title for the chat list"},
            "brief" => %{
              "type" => "string",
              "description" => "Everything the sub-task needs: goal, what to read, done criteria"
            },
            "model" => %{
              "type" => "string",
              "description" => "Model id on the current provider (default: this chat's model)"
            },
            "max_steps" => %{
              "type" => "integer",
              "description" => "Step limit for the sub-task (default 50, at most 100)"
            },
            "max_minutes" => %{
              "type" => "number",
              "description" =>
                "Wall-clock limit in minutes, not counting time spent waiting for approvals " <>
                  "(default 30, at most 120)"
            }
          },
          "required" => ["title", "brief"]
        },
        approval: :required,
        run: fn input, ctx -> Elia.Tasks.spawn_task(input, ctx) end
      },
      %Elia.Tool{
        name: "reset_task",
        description:
          "Reset the workspace to the commit a sub-task started from, discarding its commits " <>
            "and uncommitted changes. Only for a sub-task that didn't finish as done.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "task_id" => %{
              "type" => "string",
              "description" => "The `task_id` from the sub-task's result"
            }
          },
          "required" => ["task_id"]
        },
        approval: :required,
        run: fn input, ctx -> Elia.Tasks.reset_task(input, ctx) end
      }
    ]
  end

  @doc """
  The skills of a sub-task session in `project` (PROJ-10): the project's skills
  without `tasks`, plus the `task` skill (SUBTASK-1). `nil` means Elia's own
  project.
  """
  @spec child_skills(Elia.Projects.t() | nil) :: [Elia.Skill.t()]
  def child_skills(project \\ nil) do
    {skills, _errors} = Elia.Skills.for_project(project)
    Enum.reject(skills, &(&1.name == name())) ++ [child_skill()]
  end

  @doc "The skill with `finish_task`, only for sub-task sessions."
  @spec child_skill() :: Elia.Skill.t()
  def child_skill do
    %Elia.Skill{
      name: "task",
      description: "You are a sub-task agent: work from your brief and report with finish_task.",
      instructions: """
      You were started as a sub-task by another chat; your first message is the \
      brief. Work only from it, don't wait for the user, and commit your work \
      with git when it is done. When you are finished, or can't continue, call \
      `finish_task` with a `status` (`done`, `blocked` or `failed`) and a short \
      `summary` of what you did and found, and list unresolved questions in \
      `questions`. Then end your turn with no further tool calls. The harness \
      adds the commit and the changed files to the result itself.
      """,
      source: {:module, __MODULE__},
      tools: [
        %Elia.Tool{
          name: "finish_task",
          description:
            "Report the result of this sub-task to the chat that started it, then end your turn.",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "status" => %{
                "type" => "string",
                "description" => "done, blocked or failed"
              },
              "summary" => %{"type" => "string"},
              "questions" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            "required" => ["status", "summary"]
          },
          run: fn input, ctx ->
            case Elia.Tasks.finish(ctx[:session_id], input) do
              :ok ->
                {:ok,
                 "Result recorded. End your turn now with a short closing message and no " <>
                   "more tool calls."}

              {:error, _} = error ->
                error
            end
          end
        }
      ]
    }
  end
end
