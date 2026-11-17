defmodule Elia.Skills.Tasks do
  @moduledoc """
  Sub-tasks (spec: `specs/subtasks.md`). The built-in skill `tasks` gives a chat
  two tools: `spawn_task`, which starts a child chat (SUBTASK-2), and `await_task`,
  which waits for its result (SUBTASK-27). A sub-task's session is the ordinary
  registry minus this skill (SUBTASK-1, `Elia.Skills.for_child/1`), so a child
  can't start a sub-task of its own.

  A sub-task is an ordinary chat: the spawn creates it with the metadata of a
  child and sends its brief as its first message (SUBTASK-5), and from then on it
  is listed, opened, continued and marked done like any chat (STORE-17, UI-45,
  UI-48). What ends it is its own chat being marked done, and the result it ends
  with is built and saved there, by its own session (SUBTASK-9, SUBTASK-13,
  `Elia.Agent.Session`). Nothing here holds a lock or keeps a registry of running
  children: waiting is what this module adds to an ordinary chat.
  """

  @behaviour Elia.Skill

  alias Elia.{Store, Workspace}

  # SUBTASK-27, SUBTASK-35: how often a wait looks the child's chat up again, so
  # one deleted while it waits is an error rather than a wait for a chat that no
  # longer exists. The child's own end needs no polling: its session announces it
  # (SESS-35).
  @recheck_ms 1_000

  @preamble """
  You are a sub-task agent started by another chat. Work only from the brief \
  below: you don't see that chat. Where that brief names a file to read, the \
  file is the brief — read it and follow it. Where it names a report file, write \
  your report as `report.md` beside the brief file it points at, before you \
  finish: what you did, what you changed and anything the user must settle. Do \
  the work in the workspace and commit it with git on this branch; this chat's \
  work is not landed on `master` for you (DEPLOY-13). Say what you did in your \
  last message too, and put anything you need the user to settle there — don't \
  wait for an answer and don't ask. Then call `mark_done` to finish: that is what \
  ends this task and reports the result to the chat that started it.
  """

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
    isn't filled with the details. The sub-task does not see this chat, so hand \
    its brief over as a file rather than in the call: number the sub-tasks you \
    start — `001`, `002`, … in the order you spawn them — and write the brief \
    to `.tasks/001/brief.md` inside your workspace. Hold the title, the goal, \
    the specs and requirement IDs to satisfy, the files, the constraints and \
    what "done" means (including that it should commit), and add the child's \
    own `task_id` to it once the spawn has returned it. Then let the `brief` \
    here be little more than the absolute path of that file and of the report \
    beside it: "Read /your/workspace/.tasks/001/brief.md and follow the \
    instructions. Write your report to /your/workspace/.tasks/001/report.md." \
    The path is absolute because the child works in your workspace but may \
    change directory within it. The child answers in that `report.md` before it \
    marks its chat done, so read it as well as the result `await_task` returns. \
    Neither file is work: don't commit them (`.tasks/` is ignored in Elia's own \
    tree, as `tmp/` is). Commit your own work before spawning: in Elia's own \
    project the sub-task forks from your branch's last commit, so it never sees \
    uncommitted changes. A sub-task can't start sub-tasks of its own. The user \
    approves each spawn, and approves the sub-task's own tool calls in its own \
    chat.

    A sub-task ends when its own chat is marked done: its preamble tells it to \
    call `mark_done` as its last act, and the user can mark its chat done from \
    its own chat too. Nothing else ends one: not the end of a turn, not a turn \
    the user stops, not a limit it hits, not a session that dies — all of those \
    leave it running and your wait going.

    The sub-task runs on its own, so carry on with your own work. It is an \
    ordinary chat, so it is in the chat list with its own status (`working`, \
    `awaiting_approval`, `awaiting_input`, `paused`, `interrupted`, `done`, \
    `idle`), and you can open and read it like any chat. `await_task` with a \
    `task_id` waits until that chat is marked done and returns its result — at \
    once for one already marked done. Waiting for two sub-tasks in the order \
    that suits means one `await_task` per spawn. A child that is only idle — its \
    turn ended without it marking the chat done — needs the user: open its chat, \
    or tell them about it.

    The result is JSON: `task_id` and `summary` (the sub-task's last message \
    before it marked its chat done), and nothing else — no status and no record \
    of what it changed. Check it before relying on it, for example by reading \
    the sub-task's own chat, which you can read like any chat, or the files it \
    says it changed, and tell the user what happened.

    A sub-task works in your workspace — the same folder you do — and, like \
    you, makes itself a worktree of its own when it changes code, on branch \
    `chat/<task_id>` forked from your branch. Its committed work stays there \
    and is NOT merged into your branch. Bring it in yourself when you want it: \
    `git merge --ff-only chat/<task_id>`, rebasing on your branch first and \
    resolving conflicts if it has moved since the spawn. Several sub-tasks can \
    be merged in whatever order suits, and one that committed nothing leaves \
    nothing to merge.

    The harness never undoes a sub-task's work by itself. To discard it, don't \
    merge its branch; deleting the sub-task's chat leaves its worktree and \
    branch where they are, so removing them is a step of its own when the user \
    wants that too. Offer it rather than doing it by default, since the \
    sub-task's partial work may be worth keeping or finishing.
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
            "Hand its brief over as a numbered file — `.tasks/<n>/brief.md` in this " <>
            "chat's workspace — and pass that file's absolute path as the brief. " <>
            "Collect the result later with `await_task`, and read the `report.md` " <>
            "the sub-task writes beside it. " <>
            "In Elia's own project the sub-task's work is left on branch " <>
            "`chat/<task_id>` for you to merge yourself; it is not merged for you.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "title" => %{"type" => "string", "description" => "Short title for the chat list"},
            "brief" => %{
              "type" => "string",
              "description" =>
                "The work the sub-task is given, by convention the absolute path of " <>
                  "`.tasks/<n>/brief.md` to read, with the report's path beside it"
            },
            "model" => %{
              "type" => "string",
              "description" => "Model id on the current provider (default: this chat's model)"
            }
          },
          "required" => ["title", "brief"]
        },
        approval: :required,
        run: fn input, ctx -> spawn_task(input, ctx) end
      },
      %Elia.Tool{
        name: "await_task",
        description:
          "Wait until a sub-task this chat started has its chat marked done and return its " <>
            "result as JSON (`{\"task_id\", \"summary\"}`). A sub-task whose chat is " <>
            "already marked done returns at once. The wait goes on through a turn ending, " <>
            "a turn the user stops, a pause at a limit and a session that dies; it is an " <>
            "error for a chat deleted while waiting.",
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
        run: fn input, ctx -> await_task(input, ctx) end
      }
    ]
  end

  ## Spawning (SUBTASK-2, SUBTASK-5)

  @doc """
  The `spawn_task` tool (SUBTASK-2): checks what it was given, creates the child
  chat with the metadata of a child and its title (SUBTASK-5, STORE-16, TITLE-3),
  starts its session with the parent's loop options and sends the brief as its
  first message, then returns as soon as the child has started. `ctx` is the tool
  context (LOOP-18). Waiting for the child is `await_task/2` (SUBTASK-27).
  """
  @spec spawn_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def spawn_task(input, ctx) do
    with :ok <- check_input(input),
         :ok <- check_not_child(ctx[:session_id]) do
      start_child(input, ctx)
    end
  end

  defp check_input(input) do
    cond do
      blank?(input["title"]) -> {:error, "title must not be blank"}
      blank?(input["brief"]) -> {:error, "brief must not be blank"}
      true -> :ok
    end
  end

  # SUBTASK-1: a child has no `tasks` skill, so it has no `spawn_task` — and the
  # check keeps a spawn from a child refused even if it were.
  defp check_not_child(parent_id) do
    if Store.load_task(parent_id) != nil,
      do: {:error, "Not started: a sub-task can't start another sub-task."},
      else: :ok
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  # The repository the spawn works in: the parent chat's own workspace, which is
  # its project's folder — the live tree for a chat in Elia's own project
  # (DEPLOY-1) and that project's folder for a chat in another one (PROJ-12).
  defp parent_root(ctx), do: ctx[:workspace] || Workspace.root()

  defp start_child(input, ctx) do
    parent_id = ctx[:session_id]
    child_id = Elia.Agent.new_id()
    project = ctx[:project]
    title = String.trim(input["title"])
    parent = Elia.Agent.snapshot(parent_id)
    # SUBTASK-23, SUBTASK-30: the child works in its parent's workspace — no
    # worktree is forked for it and no branch is made — and it makes itself a
    # worktree of its own there if the work needs one (DEPLOY-28).
    workspace = parent_root(ctx)

    # STORE-16, SUBTASK-15: the metadata of a child from here on — the chat that
    # started it and when — is all a child saves of its task; its result is added
    # when its chat is marked done (SUBTASK-13).
    task = %{parent_id: parent_id, started_at: DateTime.utc_now()}

    # SUBTASK-5, TITLE-3: the child's chat exists before its session does, with
    # the task's title as its own, so a spawn that never gets to send its brief
    # leaves a chat the user can open, use or delete like any chat.
    :ok = Store.save(child_id, [], task: task, project: project && project.id, title: title)

    opts = [
      loop_opts: child_loop_opts(ctx, input["model"], workspace),
      task: task,
      # SUBTASK-6: the child's model is the spawn's, on the parent's provider, or
      # the parent's own.
      selection: child_selection(parent, input["model"]),
      # SUBTASK-6: the child inherits a copy of the parent's auto-approved tools
      # so the user doesn't approve them all over again.
      auto_approve: parent.settings.auto_approve,
      # SUBTASK-30: and a copy of the parent's jail setting (ISOL-18), which is
      # the child's own from then on.
      jail: parent.settings.jail,
      project: project
    ]

    with {:ok, _pid} <- Elia.Agent.ensure_started(child_id, opts) do
      # SUBTASK-5: the brief is the child's first user message, wrapped in the
      # preamble that tells it how to finish.
      :ok =
        Elia.Agent.send_message(child_id, @preamble <> "\n# Task: #{title}\n\n" <> input["brief"])

      # SUBTASK-2: the start, not the result: the parent goes on working and asks
      # for the result with `await_task` when it wants it. `status` is the child
      # chat's own status (UI-59), `working` while the turn this spawn started
      # runs.
      {:ok, Jason.encode!(%{"task_id" => child_id, "title" => title, "status" => "working"})}
    end
  end

  # SUBTASK-5, SUBTASK-1: the child's loop options are the parent's, minus what
  # belongs to the parent's own chat — its skills, its limits and its identity —
  # plus the child's own skill set (the ordinary registry minus `tasks`), its
  # model and its workspace.
  defp child_loop_opts(ctx, model, workspace) do
    parent_opts = ctx[:loop_opts] || []
    project = ctx[:project]
    llm = Keyword.get(parent_opts, :llm, %{})
    llm = if is_binary(model), do: Map.put(llm, :model, model), else: llm

    parent_opts
    |> Keyword.drop([
      :skills,
      :max_steps,
      :budget_ms,
      :token_budget,
      :pause_on_limit,
      :limits,
      :session_id,
      :turn_id,
      :workspace
    ])
    |> Keyword.merge(
      skills: fn -> Elia.Skills.for_child(project) end,
      llm: llm,
      workspace: workspace
    )
  end

  # The child's selection: the parent's, or `model` on the parent's provider (SUBTASK-6).
  defp child_selection(parent, model) do
    if is_binary(model),
      do: %{
        provider: Elia.LLM.selection(parent.settings.model).provider,
        model: model,
        name: model
      },
      else: parent.settings.model
  end

  ## Awaiting the result (SUBTASK-27)

  @doc """
  The `await_task` tool (SUBTASK-27): waits until the child's chat is marked done
  (SUBTASK-33) and returns its `result` (SUBTASK-9) as JSON. A task whose chat is
  already marked done returns at once, from its saved metadata (STORE-16). A task
  whose chat is deleted while it waits is a tool error (SUBTASK-35).
  """
  @spec await_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def await_task(input, ctx) do
    task_id = input["task_id"]

    if blank?(task_id) do
      {:error, "task_id must be the id of a sub-task of this chat."}
    else
      with {:ok, _task} <- task_of(ctx[:session_id], task_id) do
        # SUBTASK-27: the saved result is the end, and it is there whether the
        # child's session is still around or not.
        case saved_result(task_id) do
          {:ok, json} -> {:ok, json}
          {:error, _none} -> wait_for(task_id)
        end
      end
    end
  end

  # SUBTASK-9: a result is `task_id` and `summary`. One saved by an earlier
  # version is read for the two it has: its `commit` and `files` are ignored.
  defp result_of(%{result: %{} = result}), do: Map.take(result, ~w(task_id summary))
  defp result_of(_task), do: nil

  # SUBTASK-27: the wait ends when the child's chat is marked done, which the
  # child's own session announces (SESS-35) with the `{:done, true}` it
  # broadcasts. Nothing else ends it: a turn that ends, a turn the user stops, a
  # pause at a limit and a session that dies all leave it waiting. The result is
  # read again after subscribing, so an end in between can't be missed, and the
  # child's chat is looked up again every so often so one deleted while it waits
  # is an error rather than a wait for a chat that no longer exists
  # (SUBTASK-35).
  defp wait_for(task_id) do
    Elia.Agent.subscribe(task_id)
    check = Process.send_after(self(), {:recheck, task_id}, @recheck_ms)

    result =
      case saved_result(task_id) do
        {:ok, json} -> {:ok, json}
        {:error, _none} -> receive_end(task_id)
      end

    Process.cancel_timer(check)
    Elia.Agent.unsubscribe(task_id)
    result
  end

  defp receive_end(task_id) do
    receive do
      {:agent, ^task_id, {:done, true}} ->
        case saved_result(task_id) do
          {:ok, json} -> {:ok, json}
          {:error, _none} -> receive_end(task_id)
        end

      {:agent, ^task_id, _event} ->
        receive_end(task_id)

      {:recheck, ^task_id} ->
        if Store.load_task(task_id) != nil do
          Process.send_after(self(), {:recheck, task_id}, @recheck_ms)
          receive_end(task_id)
        else
          {:error,
           "That sub-task's chat was deleted while waiting for it, so there is no " <>
             "result to collect. The chat stays deleted."}
        end
    end
  end

  defp saved_result(task_id) do
    case result_of(Store.load_task(task_id) || %{}) do
      %{} = result -> {:ok, Jason.encode!(result)}
      _none -> {:error, :no_result}
    end
  end

  defp task_of(parent_id, task_id) do
    task = if is_binary(task_id), do: Store.load_task(task_id)

    if is_map(task) and task.parent_id == parent_id,
      do: {:ok, task},
      else: {:error, "#{inspect(task_id)} is not a sub-task started from this chat."}
  end
end
