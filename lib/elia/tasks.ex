defmodule Elia.Tasks do
  @moduledoc """
  Sub-tasks: a parent chat hands a brief to a child chat and collects its result
  (spec: `specs/subtasks.md`).

  `spawn_task/2` runs in the parent's tool call and returns as soon as the child
  has started (SUBTASK-2): the wait for the child belongs to a watcher process
  per child (SUBTASK-28), so the parent goes on working and the parent collects
  results with `list_tasks/2` and `await_task/2` (SUBTASK-26, SUBTASK-27). This
  module is also the registry of the running children (SUBTASK-11): a
  `GenServer` holding every active child with its parent and its workspace root,
  since a tree has at most one writer. Each child works in its own worktree in
  Elia's own project (SUBTASK-23). It is started on first use under
  `Elia.Agent.Supervisor`, so a dev server that hot-reloaded this code works
  without a restart.
  """

  use GenServer

  alias Elia.{Deploy, Store, Workspace}
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

  ## The registry of running children (SUBTASK-11)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  The running children, as `%{child_id, parent_id}` maps — empty when there are
  none (SUBTASK-11).
  """
  @spec active() :: [%{child_id: binary(), parent_id: binary()}]
  def active do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :active), else: []
  end

  @doc "Whether `child_id` is a running child (SUBTASK-11)."
  @spec running?(binary()) :: boolean()
  def running?(child_id) do
    is_binary(child_id) and Process.whereis(__MODULE__) != nil and
      GenServer.call(__MODULE__, {:running?, child_id})
  end

  @doc """
  The id of the child already writing in the workspace `root`, or `nil`
  (SUBTASK-11). A spawn into a tree another child is writing in is refused
  (SUBTASK-4).
  """
  @spec writing_in(binary()) :: binary() | nil
  def writing_in(root) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:writing_in, root})
  end

  @doc """
  The topic a child's end is announced on (SUBTASK-28), so `await_task` can wait
  for a child that is still running (SUBTASK-27).
  """
  @spec task_topic(binary()) :: binary()
  def task_topic(child_id), do: "elia:task:" <> child_id

  @doc """
  Records what a child reports with `finish_task` (SUBTASK-3). `status` must be
  `done`, `blocked` or `failed`.
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
            {:error, "This chat is not a running sub-task, so there is no one to report to."}
        end
    end
  end

  @doc """
  Takes a child's entry in the registry (SUBTASK-11): `:ok`, or
  `{:error, message}` when another running child already writes in `root`, so a
  tree has one writer at a time. The caller owns the entry (SUBTASK-28) and is
  monitored; the entry is released when it dies.
  """
  @spec acquire(binary(), binary(), binary(), map()) :: :ok | {:error, binary()}
  def acquire(parent_id, child_id, root, meta \\ %{}),
    do: call({:acquire, parent_id, child_id, root, self(), meta})

  @doc """
  Releases a child's entry, if it holds one.
  """
  @spec release(binary()) :: :ok
  def release(child_id), do: call({:release, child_id})

  @doc """
  What the entry holds about a child: its `finish` record (SUBTASK-3) and
  whether it was `cancelled` (SUBTASK-16), or `nil` when it doesn't hold an
  entry.
  """
  @spec take_state(binary()) :: %{finish: map() | nil, cancelled: boolean()} | nil
  def take_state(child_id), do: call({:take_state, child_id})

  @doc """
  Called by a session when its running turn is stopped (SESS-22). If it is a
  running child, that child is marked cancelled, so it ends as `"cancelled"`
  (SUBTASK-16). If it is the parent of running children, they are all marked
  cancelled and their turns are stopped too (SUBTASK-17). Does nothing when the
  chat isn't involved in a sub-task.
  """
  @spec note_stop(binary()) :: :ok
  def note_stop(session_id) do
    case call({:note_stop, session_id}) do
      {:stop_children, child_ids} -> Enum.each(child_ids, &stop_session/1)
      _ -> :ok
    end

    :ok
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
  The `spawn_task` tool (SUBTASK-2): checks the preconditions, starts the child
  and returns as soon as it has started, as JSON. The wait for the child belongs
  to the child's watcher (SUBTASK-28), so this doesn't block the parent's turn.
  `ctx` is the tool context (LOOP-18).
  """
  @spec spawn_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def spawn_task(input, ctx) do
    parent_id = ctx[:session_id]
    root = repo_root(ctx)

    with :ok <- check_input(input),
         :ok <- check_not_child(parent_id),
         {:ok, start_commit} <- head(root) do
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

  # SUBTASK-23: the root this child would work in — its own worktree when the
  # parent has one (Elia's own project, DEPLOY-1), the parent's workspace
  # otherwise.
  defp child_root(child_id, parent_id, parent_root) do
    if Deploy.worktree_chat(parent_root) == parent_id,
      do: Deploy.worktree_path(child_id),
      else: parent_root
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

  defp head(root) do
    case git(["rev-parse", "HEAD"], root) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _} ->
        {:error, "Not started: the repository has no commit to start from: #{String.trim(out)}"}
    end
  end

  defp run_child(input, ctx, start_commit) do
    parent_id = ctx[:session_id]
    child_id = Elia.Agent.new_id()
    parent_root = repo_root(ctx)

    # SUBTASK-4, SUBTASK-11: one writer per workspace. A child of a chat in
    # Elia's own project has a worktree of its own, so only children sharing a
    # tree (another project, or no worktree) are serialized.
    case writing_in(child_root(child_id, parent_id, parent_root)) do
      nil -> start_child(input, ctx, child_id, start_commit, parent_root)
      id -> {:error, "Not started: sub-task #{id} is already writing in that workspace."}
    end
  end

  defp start_child(input, ctx, child_id, start_commit, parent_root) do
    parent_id = ctx[:session_id]
    model = input["model"]
    parent_opts = ctx[:loop_opts] || []
    project = ctx[:project]
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
        # SUBTASK-30: and a copy of the parent's jail setting (ISOL-18), which is
        # the child's own from then on.
        jail: parent_snapshot.jail,
        project: project
      )

    meta = %{
      child_id: child_id,
      parent_id: parent_id,
      child_pid: child_pid,
      call_id: ctx[:call_id],
      start_commit: start_commit,
      root: child_root
    }

    case start_watcher(meta, task) do
      {:ok, watcher} ->
        # SUBTASK-7: the parent is told the child started.
        broadcast(parent_id, ctx[:call_id], child_id, "running")

        # SUBTASK-5: the brief is the child's first user message.
        :ok =
          Elia.Agent.send_message(
            child_id,
            @preamble <> "\n# Task: #{task.title}\n\n" <> task.brief
          )

        send(watcher, {:subtask_started, child_id})

        # SUBTASK-2: the start, not the result: the parent goes on working and
        # asks for the result with `await_task` when it wants it.
        {:ok,
         Jason.encode!(%{"task_id" => child_id, "title" => task.title, "status" => "running"})}

      {:error, message} ->
        terminate_child(child_pid)
        {:error, message}
    end
  end

  # The child's selection: the parent's, or `model` on the parent's provider (SUBTASK-6).
  defp child_selection(parent, model) do
    if is_binary(model),
      do: %{provider: Elia.LLM.selection(parent.selection).provider, model: model, name: model},
      else: parent.selection
  end

  ## The watcher (SUBTASK-28)

  # Starts the child's watcher and waits for it to take the child's entry, so a
  # spawn into a workspace another child writes in is refused (SUBTASK-4,
  # SUBTASK-11) and the entry is held before the child does anything.
  defp start_watcher(meta, task) do
    meta = Map.put(meta, :spawner, self())

    {:ok, watcher} =
      Task.Supervisor.start_child(Elia.Agent.TaskSupervisor, fn -> watch(meta, task) end)

    ref = Process.monitor(watcher)

    receive do
      {:subtask_acquired, ^watcher, :ok} ->
        Process.demonitor(ref, [:flush])
        {:ok, watcher}

      {:subtask_acquired, ^watcher, {:error, message}} ->
        Process.demonitor(ref, [:flush])
        {:error, message}

      {:DOWN, ^ref, :process, ^watcher, reason} ->
        {:error, "Not started: the sub-task's watcher stopped: #{Exception.format_exit(reason)}"}
    end
  end

  # SUBTASK-28: the watcher owns the wait for the child's turn to end (SUBTASK-8)
  # and is the child's entry owner (SUBTASK-11), so `Elia.Tasks` can finish the
  # job if it dies (SUBTASK-19). It subscribes before the brief is sent, so the
  # child's end can't be missed.
  defp watch(meta, task) do
    child_id = meta.child_id
    Elia.Agent.subscribe(child_id)
    monitor = Process.monitor(meta.child_pid)

    result =
      case acquire(meta.parent_id, child_id, meta.root, %{
             call_id: meta.call_id,
             start_commit: meta.start_commit
           }) do
        :ok ->
          send(meta.spawner, {:subtask_acquired, self(), :ok})

          if brief_sent?(meta.spawner) do
            finish(child_id, meta, task, monitor)
          else
            abandoned(child_id, meta)
            nil
          end

        {:error, message} ->
          send(meta.spawner, {:subtask_acquired, self(), {:error, message}})
          nil
      end

    Process.demonitor(monitor, [:flush])
    Elia.Agent.unsubscribe(child_id)

    # SUBTASK-27: the child's end is always announced per task, so a wait for it
    # never misses it.
    if is_map(result) do
      Phoenix.PubSub.broadcast(
        Elia.PubSub,
        task_topic(child_id),
        {:subtask_done, child_id, result}
      )
    end
  end

  # SUBTASK-17: a stopped turn kills the process running `spawn_task`, which may
  # not have sent the brief yet. The child then never ran: nothing is recorded,
  # and its entry is released.
  defp brief_sent?(spawner) do
    ref = Process.monitor(spawner)

    receive do
      {:subtask_started, _child_id} ->
        Process.demonitor(ref, [:flush])
        true

      {:DOWN, ^ref, :process, _pid, _reason} ->
        false
    end
  end

  defp abandoned(child_id, meta) do
    terminate_session(child_id)
    release(child_id)
    broadcast(meta.parent_id, meta.call_id, child_id, "cancelled")
  end

  # SUBTASK-8, SUBTASK-13: the child's turn is over when its session goes idle
  # (or it dies). The result is built and saved, the entry released and the
  # parent told.
  defp finish(child_id, meta, task, monitor) do
    outcome = await(child_id, monitor, nil)
    state = take_state(child_id) || %{finish: nil, cancelled: false}
    result = build_result(child_id, meta.start_commit, outcome, state, meta.root)

    update_saved(child_id, task, %{status: result["status"], result: result})
    release(child_id)
    broadcast(meta.parent_id, meta.call_id, child_id, saved_status(child_id))
    result
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

  # `state` is what the registry holds about the child: `finish` (SUBTASK-3) and
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
      # SUBTASK-29: a session that is gone can mean the user deleted the chat
      # (SESS-29), and writing the metadata to disk would recreate it. Save the
      # fallback only while the chat's file is still there.
      if Store.exists?(child_id) do
        Store.save(child_id, Store.load(child_id),
          model: Store.load_model(child_id),
          auto_approve: Store.load_auto_approve(child_id),
          task: Map.merge(task, changes),
          project: Store.load_project(child_id)
        )
      end
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

  ## Listing and awaiting (SUBTASK-26, SUBTASK-27)

  @doc """
  The `list_tasks` tool (SUBTASK-26): the sub-tasks this chat started, newest
  first, as JSON. With `task_id` it reports just that one, as an object, and
  adds its `result` once it has finished.
  """
  @spec list_tasks(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def list_tasks(input, ctx) do
    parent_id = ctx[:session_id]

    case input["task_id"] do
      nil ->
        tasks = parent_id |> Store.children() |> Enum.reverse() |> Enum.map(&task_json(&1.id))
        {:ok, Jason.encode!(tasks)}

      task_id ->
        with {:ok, _task} <- task_of(parent_id, task_id) do
          {:ok, Jason.encode!(task_json(task_id, true))}
        end
    end
  end

  @doc """
  The `await_task` tool (SUBTASK-27): waits until a sub-task of this chat is no
  longer running (SUBTASK-8) and returns its `result` (SUBTASK-9) as JSON. A
  task that has already finished returns at once, from its saved metadata.
  """
  @spec await_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def await_task(input, ctx) do
    task_id = input["task_id"]

    if blank?(task_id) do
      {:error, "task_id must be the id of a sub-task of this chat (see `list_tasks`)."}
    else
      with {:ok, _task} <- task_of(ctx[:session_id], task_id) do
        if reported_status(task_id) == "running",
          do: wait_for(task_id),
          else: saved_result(task_id)
      end
    end
  end

  # The task's status as the parent sees it: "running" while its entry is held
  # (SUBTASK-11), else its saved status — which reads as "interrupted" when a
  # restart left it running (SUBTASK-20, STORE-17).
  defp reported_status(child_id) do
    cond do
      running?(child_id) -> "running"
      saved_status(child_id) == "running" -> "interrupted"
      true -> saved_status(child_id)
    end
  end

  # SUBTASK-26: `result` is added only in the single-task form, and only once the
  # task has finished.
  defp task_json(child_id, with_result? \\ false) do
    task = Store.load_task(child_id) || %{}

    json = %{
      "task_id" => child_id,
      "title" => task[:title],
      "status" => reported_status(child_id),
      "reason" => reason(task),
      "started_at" => iso8601(task[:started_at])
    }

    case if(with_result?, do: Map.get(task, :result)) do
      %{} = result -> Map.put(json, "result", result)
      _ -> json
    end
  end

  defp reason(%{result: %{} = result}), do: result["reason"]
  defp reason(_task), do: nil

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_at), do: nil

  # SUBTASK-27: the wait wakes on the child's end, which its watcher always
  # announces per task (SUBTASK-28). The status is read again after subscribing,
  # so a child that ended in between can't be missed.
  defp wait_for(task_id) do
    Phoenix.PubSub.subscribe(Elia.PubSub, task_topic(task_id))

    if reported_status(task_id) == "running" do
      receive do
        {:subtask_done, ^task_id, result} -> {:ok, Jason.encode!(result)}
      end
    else
      saved_result(task_id)
    end
  end

  defp saved_result(task_id) do
    case Map.get(Store.load_task(task_id) || %{}, :result) do
      %{} = result ->
        {:ok, Jason.encode!(result)}

      _ ->
        {:error,
         "That sub-task has no result: it was interrupted by a restart (SUBTASK-20). " <>
           "`list_tasks` shows its status."}
    end
  end

  defp task_of(parent_id, task_id) do
    task = if is_binary(task_id), do: Store.load_task(task_id)

    if is_map(task) and task.parent_id == parent_id,
      do: {:ok, task},
      else: {:error, "#{inspect(task_id)} is not a sub-task started from this chat."}
  end

  ## Cleanup when a watcher dies (SUBTASK-19)

  # Runs in its own process, never in the server, which therefore never calls a
  # session and can't deadlock with one.
  defp finalize(entry) do
    child_id = entry.child_id
    root = entry[:root] || Workspace.root()
    stop_session(child_id)

    result =
      case Store.load_task(child_id) do
        %{status: "running"} = task ->
          outcome =
            if entry.cancelled,
              do: {:ended, nil},
              else: {:crashed, "The process waiting for this sub-task stopped."}

          result =
            build_result(
              child_id,
              task[:start_commit] || entry[:start_commit],
              outcome,
              Map.take(entry, [:finish, :cancelled]),
              root
            )

          update_saved(child_id, task, %{status: result["status"], result: result})
          result

        %{result: %{} = result} ->
          result

        _ ->
          nil
      end

    release(child_id)

    if result != nil do
      broadcast(entry.parent_id, entry[:call_id], child_id, saved_status(child_id))

      Phoenix.PubSub.broadcast(
        Elia.PubSub,
        task_topic(child_id),
        {:subtask_done, child_id, result}
      )
    end
  end

  defp stop_session(id) do
    Elia.Agent.stop(id)
  catch
    :exit, _ -> :ok
  end

  defp terminate_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id), do: terminate_child(pid)
    :ok
  end

  defp terminate_child(pid) do
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
  catch
    :exit, _ -> :ok
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
  def init(nil), do: {:ok, %{active: %{}}}

  @impl true
  def handle_call(:active, _from, state) do
    children =
      for {child_id, entry} <- state.active,
          do: %{child_id: child_id, parent_id: entry.parent_id}

    {:reply, children, state}
  end

  def handle_call({:running?, child_id}, _from, state),
    do: {:reply, Map.has_key?(state.active, child_id), state}

  def handle_call({:writing_in, root}, _from, state), do: {:reply, writing_in(state, root), state}

  def handle_call({:acquire, parent_id, child_id, root, owner, meta}, _from, state) do
    case writing_in(state, root) do
      nil ->
        entry = %{
          child_id: child_id,
          parent_id: parent_id,
          root: root,
          owner: owner,
          owner_ref: monitor(owner),
          call_id: meta[:call_id],
          start_commit: meta[:start_commit],
          finish: nil,
          cancelled: false
        }

        {:reply, :ok, put_entry(state, entry)}

      id ->
        {:reply, {:error, "Not started: sub-task #{id} is already writing in that workspace."},
         state}
    end
  end

  def handle_call({:release, child_id}, _from, state),
    do: {:reply, :ok, drop_entry(state, child_id)}

  def handle_call({:finish, child_id, record}, _from, state) do
    case state.active do
      %{^child_id => entry} -> {:reply, :ok, put_entry(state, %{entry | finish: record})}
      _ -> {:reply, :not_active, state}
    end
  end

  def handle_call({:note_stop, id}, _from, state) do
    case state.active do
      %{^id => entry} ->
        # SUBTASK-16: this chat's own turn is being stopped, so it is cancelled.
        {:reply, :ok, put_entry(state, %{entry | cancelled: true})}

      _ ->
        # SUBTASK-17: stop every child of this chat, so each is cancelled too.
        children = for {child_id, entry} <- state.active, entry.parent_id == id, do: child_id
        active = Map.new(state.active, &cancel(&1, children))
        {:reply, {:stop_children, children}, %{state | active: active}}
    end
  end

  def handle_call({:take_state, child_id}, _from, state) do
    case state.active do
      %{^child_id => entry} -> {:reply, Map.take(entry, [:finish, :cancelled]), state}
      _ -> {:reply, nil, state}
    end
  end

  @impl true
  # SUBTASK-19: the process watching a child died. Finish the job in another
  # process, keeping the entry, so the server never blocks and never calls a
  # session itself. A child whose session dies is finished by its watcher,
  # which releases the entry right after (SUBTASK-8, SUBTASK-11).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_by_ref(state, ref) do
      nil ->
        {:noreply, state}

      entry ->
        Task.Supervisor.start_child(Elia.Agent.TaskSupervisor, fn -> finalize(entry) end)
        {:noreply, put_entry(state, %{entry | owner_ref: nil})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp writing_in(state, root) do
    Enum.find_value(state.active, fn {child_id, entry} ->
      if entry.root == root, do: child_id
    end)
  end

  defp cancel({child_id, entry}, children) do
    if child_id in children, do: {child_id, %{entry | cancelled: true}}, else: {child_id, entry}
  end

  defp find_by_ref(state, ref) do
    Enum.find_value(state.active, fn {_child_id, entry} ->
      if entry[:owner_ref] == ref, do: entry
    end)
  end

  defp put_entry(state, %{child_id: child_id} = entry),
    do: %{state | active: Map.put(state.active, child_id, entry)}

  defp drop_entry(state, child_id) do
    case Map.pop(state.active, child_id) do
      {nil, _active} ->
        state

      {entry, active} ->
        demonitor(entry[:owner_ref])
        %{state | active: active}
    end
  end

  defp monitor(pid) when is_pid(pid), do: Process.monitor(pid)
  defp monitor(_pid), do: nil

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])
end
