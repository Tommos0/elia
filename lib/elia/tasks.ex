defmodule Elia.Tasks do
  @moduledoc """
  Sub-tasks: a parent chat hands a brief to a child chat and waits for its
  result (spec: `specs/subtasks.md`).

  `spawn_task/2` runs in the parent's tool call and blocks until the child's
  turn ends. This module is also the lock: a `GenServer` holding the one active
  child (and its parent) for the whole app, since the checkpoints, git index and
  approvals are shared. In Elia's own project the child works in its own
  worktree (SUBTASK-23). It is started on first use under
  `Elia.Agent.Supervisor`, so a dev server that hot-reloaded this code works
  without a restart.
  """

  use GenServer

  require Logger

  alias Elia.{Checkpoint, Deploy, Harness, Store, Workspace}
  alias Elia.LLM.Message

  @default_steps 100
  @max_steps 100
  @default_minutes 30
  @max_minutes 120
  @statuses ~w(done blocked failed)

  @preamble """
  You are a sub-task agent started by another chat. Work only from the brief \
  below: you don't see that chat. Do the work in the workspace, commit it with \
  git when it is done, and finish by calling `finish_task` with a status \
  (`done`, `blocked` or `failed`) and a short summary. Don't wait for the \
  user or ask them questions; list anything unresolved in `questions` instead.
  """

  ## Lock

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The active child as `%{child_id, parent_id}`, or `nil` (SUBTASK-11)."
  @spec active() :: %{child_id: binary(), parent_id: binary()} | nil
  def active do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :active)
  end

  @doc "Whether `child_id` is the active child."
  @spec running?(binary()) :: boolean()
  def running?(child_id), do: match?(%{child_id: ^child_id}, active())

  @doc """
  Records what the active child (`child_id`) reports with `finish_task`
  (SUBTASK-3). `status` must be `done`, `blocked` or `failed`.
  """
  @spec finish(binary(), map()) :: :ok | {:error, binary()}
  def finish(child_id, input) do
    status = input["status"]
    summary = input["summary"]
    questions = Map.get(input, "questions", [])

    cond do
      status not in @statuses ->
        {:error, "status must be one of: #{Enum.join(@statuses, ", ")}"}

      not is_binary(summary) or String.trim(summary) == "" ->
        {:error, "summary must not be blank"}

      not is_list(questions) or not Enum.all?(questions, &is_binary/1) ->
        {:error, "questions must be an array of strings"}

      true ->
        record = %{status: status, summary: summary, questions: questions}

        case call({:finish, child_id, record}) do
          :ok ->
            :ok

          :not_active ->
            {:error, "This chat is not an active sub-task, so there is no one to report to."}
        end
    end
  end

  @doc """
  Takes the lock for a child (SUBTASK-11): `:ok`, or `:busy` when a child is
  already active. Both sessions are monitored; the lock is released when
  either dies. `meta` may hold `:owner` (the process running `spawn_task`,
  also monitored, SUBTASK-19), `:call_id` and `:start_commit`, which the lock
  needs to finish the job itself when that process dies.
  """
  @spec acquire(binary(), pid() | nil, binary(), pid() | nil, map()) :: :ok | :busy
  def acquire(parent_id, parent_pid, child_id, child_pid, meta \\ %{}),
    do: call({:acquire, parent_id, parent_pid, child_id, child_pid, meta})

  @doc "Releases the lock if `child_id` holds it."
  @spec release(binary()) :: :ok
  def release(child_id), do: call({:release, child_id})

  @doc """
  Called by a session when its running turn is stopped (SESS-22). If it is the
  active child, the child is marked cancelled (SUBTASK-16). If it is the
  parent of the active child, the child is marked cancelled and its turn is
  stopped too (SUBTASK-17). Does nothing when no sub-task is active.
  """
  @spec note_stop(binary()) :: :ok
  def note_stop(session_id) do
    if Process.whereis(__MODULE__) do
      case GenServer.call(__MODULE__, {:note_stop, session_id}) do
        {:stop_child, child_id} -> stop_session(child_id)
        _ -> :ok
      end
    end

    :ok
  end

  defp stop_session(id) do
    Elia.Agent.stop(id)
  catch
    :exit, _ -> :ok
  end

  defp call(msg) do
    ensure_started()
    GenServer.call(__MODULE__, msg)
  end

  defp ensure_started do
    if Process.whereis(__MODULE__) == nil do
      case DynamicSupervisor.start_child(Elia.Agent.Supervisor, {__MODULE__, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  ## Spawning

  @doc """
  The `spawn_task` tool (SUBTASK-2): checks the preconditions, runs the child
  and returns its result as JSON. `ctx` is the tool context (LOOP-18).
  """
  @spec spawn_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def spawn_task(input, ctx) do
    parent_id = ctx[:session_id]
    root = repo_root(ctx)

    with :ok <- check_input(input),
         :ok <- check_not_child(parent_id),
         :ok <- check_free(),
         :ok <- check_ignored(),
         :ok <- check_clean(root),
         {:ok, start_commit} <- head(root),
         :ok <- check_parent_verified(ctx[:turn_id], root) do
      run_child(input, ctx, start_commit)
    end
  end

  # The repository the sub-task machinery works in: the chat's own workspace,
  # which for a chat in Elia's own project is its git worktree (DEPLOY-1), and
  # Elia's own root for any other project, as before.
  defp repo_root(ctx) do
    if Elia.Projects.harness_ctx?(ctx),
      do: ctx[:workspace] || Workspace.root(),
      else: Workspace.root()
  end

  defp check_input(input) do
    minutes = input["max_minutes"]

    cond do
      blank?(input["title"]) ->
        {:error, "title must not be blank"}

      blank?(input["brief"]) ->
        {:error, "brief must not be blank"}

      minutes != nil and not (is_number(minutes) and minutes > 0) ->
        {:error, "max_minutes must be a positive number"}

      true ->
        :ok
    end
  end

  # SUBTASK-18: wall-clock budget in milliseconds.
  defp budget_ms(input) do
    minutes = input["max_minutes"] || Application.get_env(:elia, :task_minutes, @default_minutes)
    trunc(min(minutes, @max_minutes) * 60_000)
  end

  defp blank?(text), do: not is_binary(text) or String.trim(text) == ""

  defp check_not_child(parent_id) do
    if Store.load_task(parent_id) != nil or running?(parent_id),
      do: {:error, "Not started: a sub-task can't start another sub-task."},
      else: :ok
  end

  defp check_free do
    case active() do
      nil -> :ok
      %{child_id: id} -> {:error, "Not started: sub-task #{id} is still active."}
    end
  end

  # The chats' files live in Elia's data dir, which sits under the live tree, not
  # in the worktree a chat works in (DEPLOY-2). It must be git-ignored there, or
  # chat files would make the live tree dirty (SUBTASK-4).
  defp check_ignored do
    data =
      Path.relative_to(
        Path.join(Workspace.data_dir(), "sessions/x.term"),
        Workspace.runtime_root()
      )

    case git(["check-ignore", "-q", data], Workspace.runtime_root()) do
      {_, 0} ->
        :ok

      _ ->
        {:error,
         "Not started: `.elia/` is not git-ignored, so chat files would count as changes. " <>
           "Add it to .gitignore and commit."}
    end
  end

  defp check_clean(root) do
    case git(["status", "--porcelain"], root) do
      {"", 0} ->
        :ok

      {out, 0} ->
        {:error,
         "Not started: the git working tree isn't clean. Commit or discard these changes " <>
           "first so the sub-task starts from a known point:\n" <>
           Elia.Shell.truncate(out, 4_000)}

      {out, _} ->
        {:error, "Not started: could not check the git working tree: #{String.trim(out)}"}
    end
  end

  defp head(root) do
    case git(["rev-parse", "HEAD"], root) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _} ->
        {:error, "Not started: the repository has no commit to start from: #{String.trim(out)}"}
    end
  end

  # Changes the parent made before the spawn must already pass the tests: the
  # parent's checkpoint is replaced when the child ends (SUBTASK-14).
  defp check_parent_verified(turn_id, root) do
    case Harness.core_elixir_changed?(turn_id, root) do
      false ->
        :ok

      true ->
        case Harness.run_tests([], root) do
          {:ok, _output} ->
            :ok

          {:error, output} ->
            {:error,
             "Not started: your changes to Elixir files in this turn fail the tests. Fix " <>
               "them first.\n\n" <> Elia.Shell.truncate(output, 20_000)}
        end

      {:error, reason} ->
        {:error, "Not started: " <> reason}
    end
  end

  defp run_child(input, ctx, start_commit) do
    parent_id = ctx[:session_id]
    child_id = Elia.Agent.new_id()
    model = input["model"]
    parent_opts = ctx[:loop_opts] || []
    project = ctx[:project]
    parent_root = repo_root(ctx)

    # SUBTASK-23, DEPLOY-9: when the parent works in its own worktree — a chat
    # in Elia's own project — the child gets its own, forked from the parent's
    # branch, so its in-progress work never touches the parent's tree. Anywhere
    # else it shares the parent's workspace, as before.
    child_root = child_workspace(child_id, parent_id, parent_root)

    # SUBTASK-12: the child's step limit defaults to the loop's own default. It
    # isn't in `spawn_task`'s schema, so the model doesn't choose it; a caller
    # (tests) may still pass `max_steps`.
    steps = input["max_steps"] |> Kernel.||(@default_steps) |> min(@max_steps) |> max(1)

    task = %{
      parent_id: parent_id,
      parent_call_id: ctx[:call_id],
      title: String.trim(input["title"]),
      brief: input["brief"],
      started_at: DateTime.utc_now(),
      status: "running",
      start_commit: start_commit
    }

    llm = Keyword.get(parent_opts, :llm, %{})
    llm = if is_binary(model), do: Map.put(llm, :model, model), else: llm

    loop_opts =
      parent_opts
      |> Keyword.drop([:skills, :max_steps, :session_id, :turn_id, :workspace])
      |> Keyword.merge(
        skills: fn -> Elia.Skills.Tasks.child_skills(project) end,
        max_steps: steps,
        # SUBTASK-24: a limit pauses the child's turn (LOOP-19, LOOP-20) instead
        # of ending it, so the user can continue it or fail it.
        pause_on_limit: true,
        budget_ms: budget_ms(input),
        llm: llm,
        workspace: child_root
      )

    parent_snapshot = Elia.Agent.snapshot(parent_id)

    {:ok, child_pid} =
      Elia.Agent.ensure_started(child_id,
        loop_opts: loop_opts,
        task: task,
        selection: child_selection(parent_snapshot, model),
        # SUBTASK-6: the child inherits a copy of the parent's auto-approved
        # tools so the user doesn't approve them all over again.
        auto_approve: parent_snapshot.auto_approve,
        project: project
      )

    with :ok <-
           lock(parent_id, child_id, child_pid, %{
             owner: self(),
             call_id: ctx[:call_id],
             start_commit: start_commit,
             root: child_root,
             parent_root: parent_root
           }) do
      Elia.Agent.subscribe(child_id)
      monitor = Process.monitor(child_pid)

      try do
        broadcast(parent_id, ctx[:call_id], child_id, "running")

        :ok =
          Elia.Agent.send_message(
            child_id,
            @preamble <> "\n# Task: #{task.title}\n\n" <> task.brief
          )

        # SUBTASK-24: the child enforces its own limits and pauses at them, so
        # this wait has no deadline of its own.
        outcome = await(child_id, monitor, nil)

        result = build_result(child_id, start_commit, outcome, take_state(child_id), child_root)
        hand_back(result, child_id, child_root, parent_root)

        update_saved(child_id, task, %{status: result["status"], result: result})
        Checkpoint.rebase(ctx[:turn_id], parent_root)
        {:ok, Jason.encode!(result)}
      after
        Process.demonitor(monitor, [:flush])
        Elia.Agent.unsubscribe(child_id)
        release(child_id)
        # The result's status is read back from the saved task (SUBTASK-7).
        broadcast(parent_id, ctx[:call_id], child_id, saved_status(child_id))
      end
    else
      :busy ->
        DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, child_pid)
        {:error, "Not started: another sub-task is active."}
    end
  end

  # SUBTASK-23: the child's own worktree when the parent has one (Elia's own
  # project, DEPLOY-1), the parent's workspace otherwise. A worktree that can't
  # be made falls back to the parent's workspace, so the child always has
  # somewhere to work.
  defp child_workspace(child_id, parent_id, parent_root) do
    with true <- Deploy.worktree_chat(parent_root) == parent_id,
         {:ok, path} <- Deploy.ensure_child_worktree(child_id, parent_id) do
      path
    else
      _ -> parent_root
    end
  end

  # SUBTASK-25: a sub-task that ends as `done` hands its committed work back to
  # the parent's branch. Anything else keeps its work on its own branch, where
  # `reset_task` can discard it (SUBTASK-22); when the child shares the parent's
  # workspace there is nothing to hand back.
  defp hand_back(%{"status" => "done"}, child_id, child_root, parent_root)
       when child_root != parent_root do
    case Deploy.merge_child(child_id, parent_root) do
      {:ok, _message} -> :ok
      {:error, reason} -> Logger.warning("could not hand a sub-task's work back: #{reason}")
    end

    :ok
  end

  defp hand_back(_result, _child_id, _child_root, _parent_root), do: :ok

  # The child's selection: the parent's, or `model` on the parent's provider (SUBTASK-6).
  defp child_selection(parent, model) do
    if is_binary(model),
      do: %{provider: Elia.LLM.selection(parent.selection).provider, model: model, name: model},
      else: parent.selection
  end

  defp lock(parent_id, child_id, child_pid, meta) do
    parent_pid =
      case Registry.lookup(Elia.Agent.Registry, parent_id) do
        [{pid, _}] -> pid
        [] -> nil
      end

    acquire(parent_id, parent_pid, child_id, child_pid, meta)
  end

  defp saved_status(child_id) do
    case Store.load_task(child_id) do
      %{status: status} -> status
      _ -> "failed"
    end
  end

  defp broadcast(parent_id, call_id, child_id, status) do
    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.topic(parent_id),
      {:agent, parent_id, {:subtask, call_id, child_id, status}}
    )
  end

  # Waits for the child's turn to end: its session goes idle (SUBTASK-8). A
  # child paused at a limit (SUBTASK-24) keeps this waiting, with no deadline of
  # its own; the child's own loop enforces the budget (LOOP-20).
  defp await(child_id, monitor, error) do
    receive do
      {:agent, ^child_id, {:status, :idle}} ->
        {:ended, error}

      {:agent, ^child_id, {:error, text}} ->
        await(child_id, monitor, text)

      {:agent, ^child_id, _event} ->
        await(child_id, monitor, error)

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {:crashed, "The sub-task session stopped: #{Exception.format_exit(reason)}"}
    end
  end

  # `state` is what the lock holds about the child: `finish` (SUBTASK-3) and
  # `cancelled` (SUBTASK-16). `root` is the child's own workspace: its worktree
  # in Elia's own project (SUBTASK-23), the parent's workspace otherwise.
  defp build_result(child_id, start_commit, outcome, state, root) do
    finish = state.finish

    {status, reason, summary} =
      case outcome do
        {:crashed, text} ->
          {"failed", "crashed", text}

        {:ended, _error} when state.cancelled ->
          {"cancelled", "cancelled", "The sub-task was stopped by the user."}

        {:ended, error} when is_binary(error) ->
          reason = if String.starts_with?(error, "Stopped after "), do: "budget", else: "error"
          {"failed", reason, error}

        {:ended, nil} when finish != nil ->
          {finish.status, nil, finish.summary}

        {:ended, nil} ->
          {"unfinished", nil, last_text(child_id) || "The task ended without a summary."}
      end

    head = git_out(["rev-parse", "HEAD"], root)

    result = %{
      "task_id" => child_id,
      "status" => status,
      "reason" => reason,
      "summary" => summary,
      "commit" => if(head != start_commit, do: head),
      "files" => changed_files(start_commit, root),
      "questions" => if(finish, do: finish.questions, else: [])
    }

    if status == "done",
      do: result,
      else:
        Map.merge(result, %{
          "start_commit" => start_commit,
          "tree_clean" => git_out(["status", "--porcelain"], root) == ""
        })
  end

  defp take_state(child_id), do: call({:take_state, child_id}) || %{finish: nil, cancelled: false}

  defp last_text(child_id) do
    Elia.Agent.snapshot(child_id).messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = message ->
        case String.trim(Message.text_content(message)) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end)
  catch
    :exit, _ -> nil
  end

  defp changed_files(start_commit, root) do
    diff = git_out(["diff", "--name-only", "-z", start_commit], root, false)

    untracked =
      git_out(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"], root, false)

    (String.split(diff || "", <<0>>, trim: true) ++
       String.split(untracked || "", <<0>>, trim: true))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Saves the final metadata through the session, or straight to disk when the
  # session is gone (SUBTASK-13).
  defp update_saved(child_id, task, changes) do
    Elia.Agent.update_task(child_id, changes)
  catch
    :exit, _ ->
      Store.save(child_id, Store.load(child_id),
        model: Store.load_model(child_id),
        auto_approve: Store.load_auto_approve(child_id),
        task: Map.merge(task, changes),
        project: Store.load_project(child_id)
      )
  end

  ## Reset

  @doc """
  The `reset_task` tool (SUBTASK-22): resets the workspace to the start commit
  of a task of the caller that didn't finish as `done`. For a sub-task in
  Elia's own project that is the sub-task's own worktree (SUBTASK-23), since a
  non-`done` sub-task is never merged (SUBTASK-25); the parent's workspace has
  nothing to undo. `ctx` is the tool context (LOOP-18).
  """
  @spec reset_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def reset_task(input, ctx) do
    parent_root = repo_root(ctx)
    root = reset_root(input["task_id"], parent_root)

    with {:ok, task} <- reset_target(ctx[:session_id], input["task_id"]),
         :ok <- check_none_active(),
         {:ok, head} <- head(root),
         :ok <- check_ancestor(task.start_commit, head, root) do
      commits = git_out(["log", "--oneline", "#{task.start_commit}..HEAD"], root) || ""
      files = changed_files(task.start_commit, root)

      with {_, 0} <- git(["reset", "--hard", "--quiet", task.start_commit], root),
           {_, 0} <- git(["clean", "-fdq"], root) do
        Checkpoint.rebase(ctx[:turn_id], parent_root)

        {:ok,
         "Workspace reset to #{String.slice(task.start_commit, 0, 8)}.\n" <>
           "Discarded commits:\n#{if commits == "", do: "(none)", else: commits}\n" <>
           "Files that differed:\n#{if files == [], do: "(none)", else: Enum.join(files, "\n")}"}
      else
        {out, _} -> {:error, "git could not reset the workspace: #{String.trim(out)}"}
      end
    end
  end

  # SUBTASK-22, SUBTASK-23: the sub-task's own worktree when it has one (Elia's
  # own project), the caller's workspace otherwise, as before.
  defp reset_root(task_id, parent_root) do
    path = if is_binary(task_id), do: Deploy.worktree_path(task_id)

    if path != nil and File.dir?(path) and Deploy.worktree_chat(path) == task_id,
      do: path,
      else: parent_root
  end

  defp reset_target(parent_id, task_id) do
    task = if is_binary(task_id), do: Store.load_task(task_id)

    cond do
      task == nil or task.parent_id != parent_id ->
        {:error, "Not reset: #{inspect(task_id)} is not a sub-task started from this chat."}

      task.status == "done" ->
        {:error, "Not reset: that sub-task finished as done; there is nothing to undo."}

      not (is_binary(task[:start_commit]) and task.start_commit != "") ->
        {:error, "Not reset: that sub-task has no start commit."}

      true ->
        {:ok, task}
    end
  end

  defp check_none_active do
    case active() do
      nil -> :ok
      %{child_id: id} -> {:error, "Not reset: sub-task #{id} is still active."}
    end
  end

  defp check_ancestor(start_commit, head, root) do
    case git(["merge-base", "--is-ancestor", start_commit, head], root) do
      {_, 0} ->
        :ok

      _ ->
        {:error,
         "Not reset: the task's start commit is not an ancestor of HEAD, so the history " <>
           "was changed since. Reset by hand if you are sure."}
    end
  end

  ## Cleanup when the process running spawn_task dies

  # SUBTASK-19. Runs in its own process, never in the lock server.
  defp finalize(active) do
    child_id = active.child_id
    root = active[:root] || Workspace.root()
    stop_session(child_id)

    case Store.load_task(child_id) do
      %{status: "running"} = task ->
        outcome =
          if active.cancelled,
            do: {:ended, nil},
            else: {:crashed, "The process waiting for this sub-task stopped."}

        state = %{finish: active.finish, cancelled: active.cancelled}
        start_commit = task[:start_commit] || active[:start_commit]
        result = build_result(child_id, start_commit, outcome, state, root)
        update_saved(child_id, task, %{status: result["status"], result: result})

      _ ->
        :ok
    end

    release(child_id)
    broadcast(active.parent_id, active[:call_id], child_id, saved_status(child_id))
  end

  defp git(args, root), do: System.cmd("git", args, cd: root, stderr_to_stdout: true)

  defp git_out(args, root, trim? \\ true) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> if trim?, do: String.trim(out), else: out
      _ -> nil
    end
  end

  ## Server

  @impl true
  def init(nil), do: {:ok, %{active: nil}}

  @impl true
  def handle_call(:active, _from, %{active: nil} = state), do: {:reply, nil, state}

  def handle_call(:active, _from, %{active: active} = state),
    do: {:reply, Map.take(active, [:child_id, :parent_id]), state}

  def handle_call({:acquire, parent_id, parent_pid, child_id, child_pid, meta}, _from, %{
        active: nil
      }) do
    refs = for pid <- [parent_pid, child_pid], is_pid(pid), do: Process.monitor(pid)
    owner = meta[:owner]

    active = %{
      child_id: child_id,
      parent_id: parent_id,
      refs: refs,
      owner_ref: if(is_pid(owner), do: Process.monitor(owner)),
      owner: owner,
      call_id: meta[:call_id],
      start_commit: meta[:start_commit],
      root: meta[:root],
      finish: nil,
      cancelled: false
    }

    {:reply, :ok, %{active: active}}
  end

  def handle_call({:acquire, _, _, _, _, _}, _from, state), do: {:reply, :busy, state}

  def handle_call({:release, child_id}, _from, %{active: %{child_id: child_id}} = state),
    do: {:reply, :ok, clear(state)}

  def handle_call({:release, _child_id}, _from, state), do: {:reply, :ok, state}

  def handle_call({:finish, child_id, record}, _from, %{active: %{child_id: child_id} = active}) do
    {:reply, :ok, %{active: %{active | finish: record}}}
  end

  def handle_call({:finish, _child_id, _record}, _from, state), do: {:reply, :not_active, state}

  def handle_call({:note_stop, id}, _from, %{active: %{child_id: id} = active}),
    do: {:reply, :ok, %{active: %{active | cancelled: true}}}

  def handle_call({:note_stop, id}, _from, %{active: %{parent_id: id} = active}),
    do: {:reply, {:stop_child, active.child_id}, %{active: %{active | cancelled: true}}}

  def handle_call({:note_stop, _id}, _from, state), do: {:reply, :ok, state}

  def handle_call(
        {:take_state, child_id},
        _from,
        %{active: %{child_id: child_id} = active} = state
      ),
      do: {:reply, Map.take(active, [:finish, :cancelled]), state}

  def handle_call({:take_state, _child_id}, _from, state), do: {:reply, nil, state}

  @impl true
  # SUBTASK-19: the process running spawn_task died with the lock held. Finish
  # the job in another process, keeping the lock until it is done.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{active: %{owner_ref: ref} = active} = state
      ) do
    active = %{active | owner_ref: nil}
    Task.Supervisor.start_child(Elia.Agent.TaskSupervisor, fn -> finalize(active) end)
    {:noreply, %{state | active: active}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{refs: refs}} = state) do
    if ref in refs, do: {:noreply, clear(state)}, else: {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp clear(%{active: %{refs: refs} = active}) do
    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    if active[:owner_ref], do: Process.demonitor(active.owner_ref, [:flush])
    %{active: nil}
  end

  defp clear(state), do: state
end
