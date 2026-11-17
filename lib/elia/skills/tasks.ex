defmodule Elia.Skills.Tasks do
  @moduledoc """
  Sub-tasks (spec: `specs/subtasks.md`). The built-in skill `tasks` gives a
  chat `spawn_task`, `list_tasks` and `await_task`; a sub-task's session is the
  ordinary registry minus this skill (SUBTASK-1, `Elia.Skills.for_child/1`), so
  a child can't start a sub-task of its own.
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
    returns as soon as it has started, as `{"task_id", "title", "status"}` — \
    the status of the sub-task's own chat, as the chat list shows it (`working` \
    while its first turn runs). Use it for a self-contained step of a long job \
    (for example: implement one spec, then test it) so this chat's context \
    isn't filled with the details. The sub-task does not see this chat, so the \
    `brief` is its whole input: give the goal, the files and specs to read \
    first, the constraints, and what "done" means (including that it should \
    commit). Commit your own work before spawning: in Elia's own project the \
    sub-task forks from your branch's last commit, so it never sees uncommitted \
    changes. A sub-task can't start sub-tasks of its own. The user approves \
    each spawn, and approves the sub-task's own tool calls in its chat.

    A sub-task ends when its own chat is marked done: its preamble tells it to \
    call `mark_done` as its last act, and the user can mark its chat done from \
    its own chat too. Nothing else ends one: not the end of a turn, not a turn \
    the user stops, not a limit it hits, not a session that dies — all of those \
    leave it running and your wait going.

    The sub-task runs on its own, so carry on with your own work: `list_tasks` \
    shows the sub-tasks this chat started, each with its own chat's status \
    (`working`, `awaiting_approval`, `awaiting_input`, `paused`, `interrupted`, \
    `done`, `idle`), and `await_task` with a `task_id` waits until that chat is \
    marked done and returns its result — at once for one already marked done. \
    Waiting for two sub-tasks in the order that suits means one `await_task` \
    per spawn. Sub-tasks that share a workspace (outside Elia's own project, \
    where they have no worktree) run one at a time. A child that is only idle — \
    its turn ended without it marking the chat done — needs the user: open its \
    chat, or tell them about it.

    The result is JSON: `task_id`, `summary` (the sub-task's last message before \
    it marked its chat done), `commit` (its new HEAD, or null when it committed \
    nothing), `files` (the paths it changed since the spawn, untracked included) \
    and nothing else — no status. Check it before relying on it, for example by \
    reading the changed files, and tell the user what happened.

    A sub-task in Elia's own project works in its own worktree, so its \
    committed work stays on branch `chat/<task_id>` and is NOT merged into this \
    chat's branch. Bring it in yourself when you want it: \
    `git merge --ff-only chat/<task_id>`, rebasing on your branch first and \
    resolving conflicts if it has moved since the spawn. Several sub-tasks can \
    be merged in whatever order suits. In another project the sub-task commits \
    in this chat's workspace, so there is nothing to merge.

    The harness never undoes a sub-task's work by itself. To discard it, don't \
    merge its branch; when the user wants the worktree and branch gone as well, \
    deleting the sub-task's chat removes them. Offer that rather than doing it \
    by default, since the sub-task's partial work may be worth keeping or \
    finishing.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "spawn_task",
        description:
          "Start a sub-task in a new chat and return as soon as it has started " <>
            "(`{\"task_id\", \"title\", \"status\"}` — the sub-task's own chat status). " <>
            "The brief must be self-contained. Collect the result later with `await_task` " <>
            "(or check on it with `list_tasks`). In Elia's own project the sub-task's work " <>
            "is left on branch `chat/<task_id>` for you to merge yourself; it is not " <>
            "merged for you.",
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
          "List the sub-tasks this chat started, newest first, with the status each one's " <>
            "own chat has now (`working`, `awaiting_approval`, `awaiting_input`, `paused`, " <>
            "`interrupted`, `done` or `idle` — what the chat list shows). With `task_id`, " <>
            "list just that one and include its saved result once its chat is marked done.",
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
          "Wait until a sub-task this chat started has its chat marked done and return its " <>
            "result as JSON (`{\"task_id\", \"summary\", \"commit\", \"files\"}`). A " <>
            "sub-task whose chat is already marked done returns at once. The wait goes on " <>
            "through a turn ending, a turn the user stops, a pause at a limit and a session " <>
            "that dies; it is an error for a chat deleted while waiting.",
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
      }
    ]
  end
end
