defmodule Elia.Tasks do
  @moduledoc """
  Sub-tasks: a parent chat hands a brief to a child chat and waits for its
  result (spec: `specs/subtasks.md`).

  `spawn_task/2` runs in the parent's tool call and blocks until the child's
  turn ends. This module is also the lock: a `GenServer` holding the one active
  child (and its parent) for the whole app, since the workspace, checkpoints
  and git index are shared. It is started on first use under
  `Elia.Agent.Supervisor`, so a dev server that hot-reloaded this code works
  without a restart.
  """

  use GenServer

  alias Elia.{Checkpoint, Harness, Store, Workspace}
  alias Elia.LLM.Message

  @default_steps 50
  @max_steps 100
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
  either dies.
  """
  @spec acquire(binary(), pid() | nil, binary(), pid() | nil) :: :ok | :busy
  def acquire(parent_id, parent_pid, child_id, child_pid),
    do: call({:acquire, parent_id, parent_pid, child_id, child_pid})

  @doc "Releases the lock if `child_id` holds it."
  @spec release(binary()) :: :ok
  def release(child_id), do: call({:release, child_id})

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

    with :ok <- check_input(input),
         :ok <- check_not_child(parent_id),
         :ok <- check_free(),
         :ok <- check_ignored(),
         :ok <- check_clean(),
         {:ok, start_commit} <- head(),
         :ok <- check_parent_verified(ctx[:turn_id]) do
      run_child(input, ctx, start_commit)
    end
  end

  defp check_input(input) do
    cond do
      blank?(input["title"]) -> {:error, "title must not be blank"}
      blank?(input["brief"]) -> {:error, "brief must not be blank"}
      true -> :ok
    end
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

  defp check_ignored do
    dir = Path.relative_to(Path.join(Workspace.data_dir(), "sessions/x.term"), Workspace.root())

    case git(["check-ignore", "-q", dir]) do
      {_, 0} ->
        :ok

      _ ->
        {:error,
         "Not started: `.elia/` is not git-ignored, so chat files would count as changes. " <>
           "Add it to .gitignore and commit."}
    end
  end

  defp check_clean do
    case git(["status", "--porcelain"]) do
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

  defp head do
    case git(["rev-parse", "HEAD"]) do
      {out, 0} ->
        {:ok, String.trim(out)}

      {out, _} ->
        {:error, "Not started: the repository has no commit to start from: #{String.trim(out)}"}
    end
  end

  # Changes the parent made before the spawn must already pass the tests: the
  # parent's checkpoint is replaced when the child ends (SUBTASK-14).
  defp check_parent_verified(turn_id) do
    case Harness.core_elixir_changed?(turn_id) do
      false ->
        :ok

      true ->
        case Harness.run_tests() do
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

    steps = input["max_steps"] |> Kernel.||(@default_steps) |> min(@max_steps) |> max(1)

    task = %{
      parent_id: parent_id,
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
      |> Keyword.drop([:skills, :max_steps, :session_id, :turn_id])
      |> Keyword.merge(
        skills: &Elia.Skills.Tasks.child_skills/0,
        max_steps: steps,
        llm: llm
      )

    {:ok, child_pid} =
      Elia.Agent.ensure_started(child_id,
        loop_opts: loop_opts,
        task: task,
        selection: child_selection(parent_id, model)
      )

    with :ok <- lock(parent_id, child_id, child_pid) do
      Elia.Agent.subscribe(child_id)
      monitor = Process.monitor(child_pid)

      try do
        broadcast(parent_id, ctx[:call_id], child_id, "running")

        :ok =
          Elia.Agent.send_message(
            child_id,
            @preamble <> "\n# Task: #{task.title}\n\n" <> task.brief
          )

        outcome = await(child_id, monitor, nil)
        result = build_result(child_id, start_commit, outcome)

        update_saved(child_id, task, %{status: result["status"], result: result})
        Checkpoint.rebase(ctx[:turn_id])
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

  # The child's selection: the parent's, or `model` on the parent's provider (SUBTASK-6).
  defp child_selection(parent_id, model) do
    parent = Elia.Agent.snapshot(parent_id).selection

    if is_binary(model),
      do: %{provider: Elia.LLM.selection(parent).provider, model: model, name: model},
      else: parent
  end

  defp lock(parent_id, child_id, child_pid) do
    parent_pid =
      case Registry.lookup(Elia.Agent.Registry, parent_id) do
        [{pid, _}] -> pid
        [] -> nil
      end

    acquire(parent_id, parent_pid, child_id, child_pid)
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

  # Waits for the child's turn to end: its session goes idle (SUBTASK-8).
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

  defp build_result(child_id, start_commit, outcome) do
    finish = take_finish(child_id)

    {status, summary} =
      case outcome do
        {:crashed, text} ->
          {"failed", text}

        {:ended, error} when is_binary(error) ->
          {"failed", error}

        {:ended, nil} when finish != nil ->
          {finish.status, finish.summary}

        {:ended, nil} ->
          {"unfinished", last_text(child_id) || "The task ended without a summary."}
      end

    head = git_out(["rev-parse", "HEAD"])

    %{
      "status" => status,
      "summary" => summary,
      "commit" => if(head != start_commit, do: head),
      "files" => changed_files(start_commit),
      "questions" => if(finish, do: finish.questions, else: [])
    }
  end

  defp take_finish(child_id), do: call({:take_finish, child_id})

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

  defp changed_files(start_commit) do
    diff = git_out(["diff", "--name-only", "-z", start_commit], false)

    untracked =
      git_out(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"], false)

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
        task: Map.merge(task, changes)
      )
  end

  defp git(args), do: System.cmd("git", args, cd: Workspace.root(), stderr_to_stdout: true)

  defp git_out(args, trim? \\ true) do
    case System.cmd("git", args, cd: Workspace.root(), stderr_to_stdout: true) do
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

  def handle_call({:acquire, parent_id, parent_pid, child_id, child_pid}, _from, %{active: nil}) do
    refs = for pid <- [parent_pid, child_pid], is_pid(pid), do: Process.monitor(pid)

    active = %{child_id: child_id, parent_id: parent_id, refs: refs, finish: nil}
    {:reply, :ok, %{active: active}}
  end

  def handle_call({:acquire, _, _, _, _}, _from, state), do: {:reply, :busy, state}

  def handle_call({:release, child_id}, _from, %{active: %{child_id: child_id}} = state),
    do: {:reply, :ok, clear(state)}

  def handle_call({:release, _child_id}, _from, state), do: {:reply, :ok, state}

  def handle_call({:finish, child_id, record}, _from, %{active: %{child_id: child_id} = active}) do
    {:reply, :ok, %{active: %{active | finish: record}}}
  end

  def handle_call({:finish, _child_id, _record}, _from, state), do: {:reply, :not_active, state}

  def handle_call(
        {:take_finish, child_id},
        _from,
        %{active: %{child_id: child_id} = active} = state
      ),
      do: {:reply, active.finish, state}

  def handle_call({:take_finish, _child_id}, _from, state), do: {:reply, nil, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{active: %{refs: refs}} = state) do
    if ref in refs, do: {:noreply, clear(state)}, else: {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp clear(%{active: %{refs: refs}}) do
    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    %{active: nil}
  end

  defp clear(state), do: state
end
