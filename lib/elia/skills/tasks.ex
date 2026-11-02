defmodule Elia.Skills.Tasks do
  @moduledoc """
  Sub-tasks (spec: `specs/subtasks.md`). The built-in skill `tasks` gives a
  chat `spawn_task`, `list_tasks`, `await_task` and `reset_task`; sessions
  started by it get `child_skills/0` instead, which swaps `tasks` for the skill
  `task` with `finish_task` (SUBTASK-1).
  """

  @behaviour Elia.Skill

  @impl true
  def name, do: "tasks"

  @impl true
  def description, do: "Hand a focused piece of work to a sub-task chat with a fresh context."

  @impl true
  def instructions do
    """
    `spawn_task` starts a separate chat (a sub-task) with a fresh context and \
    returns as soon as it has started, as `{"task_id", "title", "status": \
    "running"}`. Use it for a self-contained step of a long job (for example: \
    implement one spec, then test it) so this chat's context isn't filled with \
    the details. The sub-task does not see this chat, so the `brief` is its \
    whole input: give the goal, the files and specs to read first, the \
    constraints, and what "done" means (including that it should commit). \
    Commit your own work before spawning: in Elia's own project the sub-task \
    forks from your branch's last commit, so it never sees uncommitted changes. \
    A sub-task can't start sub-tasks of its own. The user approves each spawn, \
    and approves the sub-task's own tool calls in its chat.

    The sub-task runs on its own, so carry on with your own work: `list_tasks` \
    shows the sub-tasks this chat started and how each is doing, and \
    `await_task` with a `task_id` waits for one to finish and returns its \
    result (and returns it at once for one that has already finished). Waiting \
    for two sub-tasks in the order that suits means one `await_task` per spawn. \
    Sub-tasks that share a workspace (outside Elia's own project, where they \
    have no worktree) run one at a time.

    The result is JSON: `status` (`done`, `blocked`, `failed`, `unfinished` or \
    `cancelled`), `reason` (`budget`, `cancelled`, `crashed`, `error` or null), \
    `summary`, `task_id`, `commit` (new HEAD, or null), `files` (changed paths) \
    and `questions`. Check it before relying on it, for example by reading the \
    changed files, and tell the user what happened.

    A sub-task in Elia's own project works in its own worktree, so its \
    committed work stays on branch `chat/<task_id>` and is NOT merged into this \
    chat's branch. Bring it in yourself when you want it: \
    `git merge --ff-only chat/<task_id>`, rebasing on your branch first and \
    resolving conflicts if it has moved since the spawn. Several sub-tasks can \
    be merged in whatever order suits. In another project the sub-task commits \
    in this chat's workspace, so there is nothing to merge.

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
          "Start a sub-task in a new chat and return as soon as it has started " <>
            "(`{\"task_id\", \"title\", \"status\": \"running\"}`). The brief must be " <>
            "self-contained. Collect the result later with `await_task` (or check on it " <>
            "with `list_tasks`). In Elia's own project the sub-task's work is left on " <>
            "branch `chat/<task_id>` for you to merge yourself; it is not merged for you.",
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
        name: "list_tasks",
        description:
          "List the sub-tasks this chat started, newest first, with the status each one has " <>
            "now (`running`, or its final status) and, for a finished one, its reason. With " <>
            "`task_id`, list just that one and include its result.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "task_id" => %{
              "type" => "string",
              "description" => "Optional: one sub-task's id, to see just that one"
            }
          },
          "required" => []
        },
        approval: :never,
        run: fn input, ctx -> Elia.Tasks.list_tasks(input, ctx) end
      },
      %Elia.Tool{
        name: "await_task",
        description:
          "Wait until a sub-task this chat started is no longer running and return its " <>
            "result as JSON. A sub-task that has already finished returns at once.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "task_id" => %{
              "type" => "string",
              "description" => "The `task_id` from the sub-task's start"
            }
          },
          "required" => ["task_id"]
        },
        approval: :never,
        run: fn input, ctx -> Elia.Tasks.await_task(input, ctx) end
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
