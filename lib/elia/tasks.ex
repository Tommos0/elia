defmodule Elia.Tasks do
  @moduledoc """
  Sub-tasks: a parent chat hands a brief to a child chat and collects its result
  (spec: `specs/subtasks.md`).

  `spawn_task/2` runs in the parent's tool call and returns as soon as the child
  has started (SUBTASK-2), so the parent goes on working and collects results
  with `list_tasks/2` and `await_task/2` (SUBTASK-26, SUBTASK-27). This module
  is the registry of the children whose chats aren't marked done (SUBTASK-11): a
  `GenServer` holding every running child with its parent, its workspace root,
  the commit it started from and the call that started it — since a tree has at
  most one writer. A child works in its own worktree in Elia's own project
  (SUBTASK-23). Nothing owns the wait for a child: what ends its task is its own
  chat being marked done (SUBTASK-33), and its own session builds the result it
  ends with (SUBTASK-9, SUBTASK-13). It is started on first use under
  `Elia.Agent.Supervisor`, so a dev server that hot-reloaded this code works
  without a restart.
  """

  use GenServer

  alias Elia.{Deploy, Store, Workspace}
  alias EliaWeb.ChatStatus

  @default_steps 100
  @max_steps 100
  @default_minutes 30
  @max_minutes 120

  # SUBTASK-9: what a child says about itself when it marked its chat done
  # without a last message to say it with.
  @no_summary "The task ended without a summary."

  # SUBTASK-27, SUBTASK-35: how often a wait looks the child's chat up again, so
  # one deleted while it waits is an error rather than a wait for a chat that no
  # longer exists. The child's own end needs no polling: its session announces it
  # (SESS-35).
  @recheck_ms 1_000

  @preamble """
  You are a sub-task agent started by another chat. Work only from the brief \
  below: you don't see that chat. Do the work in the workspace and commit it \
  with git on this branch; this chat's work is not landed on `master` for you \
  (DEPLOY-13). Say what you did in your last message, and put anything you need \
  the user to settle there too — don't wait for an answer and don't ask. Then \
  call `mark_done` to finish: that is what ends this task and reports the result \
  to the chat that started it.
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
  Called by a child's session when its chat has been marked done (SUBTASK-33):
  the harness builds the result of the task (SUBTASK-9) against `root`, the
  workspace the child worked in, and releases the child's entry (SUBTASK-13,
  SUBTASK-11), and the caller saves the result with the child's own task
  metadata (SESS-18).

  `{:ok, result}` is the result to save, and `:ok` means there is nothing to
  save: a chat that isn't a sub-task's, and one that already has a result —
  which is kept, since a result is saved once (SUBTASK-13, DONE-9). The entry is
  released either way. `summary` is the child's last words before it marked the
  chat done, or `nil` when it said nothing.
  """
  @spec end_task(binary(), binary() | nil, binary()) :: {:ok, map()} | :ok
  def end_task(child_id, summary, root) do
    case Store.load_task(child_id) do
      %{parent_id: _parent_id} = task ->
        result =
          case result_of(task) do
            %{} = _saved -> :ok
            _none -> {:ok, build_result(child_id, task[:start_commit], summary, root)}
          end

        release(child_id)
        result

      _not_a_task ->
        :ok
    end
  end

  @doc """
  Takes a child's entry in the registry (SUBTASK-11): `:ok`, or
  `{:error, message}` when another running child already writes in `root`, so a
  tree has one writer at a time. The caller takes it before the child's brief
  goes out — while it is the only one who can send it — and marks it as sent
  afterwards (SUBTASK-5, SUBTASK-36).
  """
  @spec acquire(binary(), binary(), binary(), map()) :: :ok | {:error, binary()}
  def acquire(parent_id, child_id, root, meta \\ %{}),
    do: call({:acquire, parent_id, child_id, root, self(), meta})

  @doc """
  Releases a child's entry, if it holds one (SUBTASK-11, SUBTASK-13,
  SUBTASK-35).
  """
  @spec release(binary()) :: :ok
  def release(child_id), do: call({:release, child_id})

  @doc """
  Records that the child's brief has gone out (SUBTASK-5), so its entry is one
  for a child that has run rather than one a spawn never got to (SUBTASK-36).
  Called by the spawn once `send_message/2` has delivered it.
  """
  @spec brief_sent(binary()) :: :ok
  def brief_sent(child_id), do: call({:brief_sent, child_id})

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
  and returns as soon as it has started, as JSON. Nothing here waits for the
  child — the parent asks for its result with `await_task` when it wants it, and
  what ends the task is the child's chat being marked done (SUBTASK-27,
  SUBTASK-33). `ctx` is the tool context (LOOP-18).
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

  # The repository the sub-task machinery works in — the root of its git calls,
  # of its writer lock and of the child's own workspace: the parent chat's own
  # workspace, which is its git worktree for a chat in Elia's own project
  # (DEPLOY-1) and its project's folder for a chat in another one (PROJ-12). A
  # chat whose tools run in Elia's own root passes that root, and one that works
  # in another project passes that project (SUBTASK-23, PROJ-9).
  defp repo_root(ctx), do: ctx[:workspace] || Workspace.root()

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

  # SUBTASK-18: the child's wall-clock budget, in minutes. It becomes the
  # child's own time limit (LIMIT-5).
  defp minutes(input) do
    given = input["max_minutes"] || Application.get_env(:elia, :task_minutes, @default_minutes)
    min(given, @max_minutes)
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
      start_commit: start_commit
    }

    llm = Keyword.get(parent_opts, :llm, %{})
    llm = if is_binary(model), do: Map.put(llm, :model, model), else: llm

    loop_opts =
      parent_opts
      |> Keyword.drop([
        :skills,
        :max_steps,
        :budget_ms,
        :token_budget,
        :pause_on_limit,
        :session_id,
        :turn_id,
        :workspace
      ])
      |> Keyword.merge(
        # SUBTASK-1: the child's skills are the ordinary registry minus `tasks`,
        # so it has no `spawn_task` and can't start sub-tasks of its own.
        skills: fn -> Elia.Skills.for_child(project) end,
        llm: llm,
        workspace: child_root
      )

    # LIMIT-5: the child's budget becomes its own turn limits, so its settings
    # page shows the budget it runs with and the user can give it more of it
    # while it is paused. The parent's own limits are not inherited, and the
    # spawn sets no token budget: the child's token spend is unlimited
    # (LIMIT-12) until the user sets one on its own settings page.
    limits = %{max_steps: steps, max_minutes: minutes(input), pause_on_limit: true}

    # SUBTASK-5, SUBTASK-11: the entry is taken before the child exists, so no
    # other child starts writing in the same tree while this one is being set
    # up, and it stays taken until this chat is marked done (SUBTASK-33) or its
    # chat is deleted (SUBTASK-35). It is taken by this process, so a spawn that
    # dies before its brief went out leaves an entry for a child that never ran
    # (SUBTASK-36).
    case acquire(parent_id, child_id, child_root, %{
           owner: self(),
           call_id: ctx[:call_id],
           start_commit: start_commit
         }) do
      :ok ->
        start_briefed_child(input, ctx, child_id, task, loop_opts, limits, project)

      {:error, message} ->
        {:error, message}
    end
  end

  defp start_briefed_child(input, ctx, child_id, task, loop_opts, limits, project) do
    parent_snapshot = Elia.Agent.snapshot(ctx[:session_id])

    # SUBTASK-5, SUBTASK-36: the child's chat exists with the metadata of a
    # child from here on, so a spawn that never gets to send its brief leaves
    # the chat it was given saved and unmarked, for the user to open, use or
    # delete like any chat.
    :ok = Elia.Store.save(child_id, [], task: task, project: project && project.id)

    with {:ok, _pid} <-
           Elia.Agent.ensure_started(child_id,
             loop_opts: loop_opts,
             task: task,
             limits: limits,
             selection: child_selection(parent_snapshot, input["model"]),
             # SUBTASK-6: the child inherits a copy of the parent's auto-approved
             # tools so the user doesn't approve them all over again.
             auto_approve: parent_snapshot.settings.auto_approve,
             # SUBTASK-30: and a copy of the parent's jail setting (ISOL-18),
             # which is the child's own from then on.
             jail: parent_snapshot.settings.jail,
             project: project
           ) do
      # SUBTASK-5: the brief is the child's first user message, and the entry
      # stops being one a spawn might never get to send.
      :ok =
        Elia.Agent.send_message(
          child_id,
          @preamble <> "\n# Task: #{task.title}\n\n" <> task.brief
        )

      :ok = brief_sent(child_id)

      # SUBTASK-2: the start, not the result: the parent goes on working and
      # asks for the result with `await_task` when it wants it. `status` is the
      # child chat's own status (UI-59), which is `working` while the turn this
      # spawn started runs.
      {:ok, Jason.encode!(%{"task_id" => child_id, "title" => task.title, "status" => "working"})}
    else
      {:error, message} ->
        release(child_id)
        {:error, message}
    end
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

  ## Building the result (SUBTASK-9)

  # `root` is the child's own workspace: its worktree in Elia's own project
  # (SUBTASK-23), its project's folder otherwise. `summary` is what the child
  # said last before it marked its chat done, or nil when it said nothing.
  defp build_result(child_id, start_commit, summary, root) do
    head = git_out(["rev-parse", "HEAD"], root)
    commit = if is_binary(start_commit) and head == start_commit, do: nil, else: head

    %{
      "task_id" => child_id,
      "summary" => summary || @no_summary,
      "commit" => commit,
      "files" => changed_files(start_commit, root)
    }
  end

  defp changed_files(start_commit, root) do
    # SUBTASK-9: the paths changed since the commit the spawn recorded, against
    # the child's tree — so its committed work and anything it left uncommitted.
    # A task saved without a start commit (an older version's, SUBTASK-9) has
    # nothing to compare against, and only its untracked files are reported.
    diff =
      if is_binary(start_commit),
        do: git_out(["diff", "--name-only", "-z", start_commit], root, false),
        else: nil

    untracked =
      git_out(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"], root, false)

    (String.split(diff || "", <<0>>, trim: true) ++
       String.split(untracked || "", <<0>>, trim: true))
    |> Enum.uniq()
    |> Enum.sort()
  end

  ## Listing and awaiting (SUBTASK-26, SUBTASK-27)

  @doc """
  The `list_tasks` tool (SUBTASK-26): the sub-tasks this chat started, newest
  first, as JSON. With `task_id` it reports just that one, as an object, and
  adds its `result` once its chat is marked done.
  """
  @spec list_tasks(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def list_tasks(input, ctx) do
    parent_id = ctx[:session_id]

    case input["task_id"] do
      nil ->
        children = Store.children(parent_id)
        marks = status_marks(children)

        tasks =
          children
          |> Enum.reverse()
          |> Enum.map(&task_json(&1.id, marks))

        {:ok, Jason.encode!(tasks)}

      task_id ->
        with {:ok, _task} <- task_of(parent_id, task_id) do
          marks = status_marks(Store.children(parent_id))
          {:ok, Jason.encode!(task_json(task_id, marks, true))}
        end
    end
  end

  @doc """
  The `await_task` tool (SUBTASK-27): waits until the child's chat is marked
  done (SUBTASK-33) and returns its `result` (SUBTASK-9) as JSON. A task whose
  chat is already marked done returns at once, from its saved metadata. A task
  whose chat is deleted while it waits is a tool error (SUBTASK-35).
  """
  @spec await_task(map(), map()) :: {:ok, binary()} | {:error, binary()}
  def await_task(input, ctx) do
    task_id = input["task_id"]

    if blank?(task_id) do
      {:error, "task_id must be the id of a sub-task of this chat (see `list_tasks`)."}
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

  # SUBTASK-26: `result` is added only in the single-task form, and only once the
  # task's chat is marked done. `status` is the child chat's own status (UI-59,
  # UI-72) — the same one its row in the chat list shows (UI-45, UI-46).
  defp task_json(child_id, marks, with_result? \\ false) do
    task = Store.load_task(child_id) || %{}

    json = %{
      "task_id" => child_id,
      "title" => task[:title],
      "status" => chat_status(child_id, marks),
      "started_at" => iso8601(task[:started_at])
    }

    case if(with_result?, do: result_of(task)) do
      %{} = result -> Map.put(json, "result", result)
      _ -> json
    end
  end

  # SUBTASK-9, SUBTASK-21: a result is these four keys. One saved by an earlier
  # version is read for the four it has and for nothing else.
  defp result_of(%{result: %{} = result}), do: Map.take(result, ~w(task_id summary commit files))
  defp result_of(_task), do: nil

  # UI-44, UI-59, UI-72: the markers a child's own status is read from
  # (`EliaWeb.ChatStatus.for_chat/2`): what the registry says about every chat
  # with a session (SESS-19, SESS-28) and the children whose saved turn a
  # restart cut short (STORE-31), which is what the chat list carries too
  # (UI-46).
  defp status_marks(children) do
    %{
      awaiting: Elia.Agent.awaiting_approval(),
      input: Elia.Agent.awaiting_input(),
      paused: Elia.Agent.paused(),
      running: Elia.Agent.running(),
      interrupted: for(%{interrupted: true} = child <- children, do: child.id)
    }
  end

  # UI-59, UI-72: the child's own status, from its listed entry (STORE-36) and
  # those markers — the one derivation the chat list reads (`EliaWeb.ChatStatus`),
  # so a parent sees what it would see in the list (SUBTASK-26).
  defp chat_status(child_id, marks) do
    case Store.entry(child_id) do
      %{} = entry -> ChatStatus.for_chat(entry, marks)
      _none -> nil
    end
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(_at), do: nil

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

  @doc """
  Called by a session whose running turn is being stopped (SESS-8): the turns of
  the children of that chat are stopped too (SESS-22, SUBTASK-17). A child's own
  stop is not recorded — a stop ends a turn and nothing more, so the child keeps
  its entry and its task goes on (SUBTASK-16) — and a chat with no running
  children does nothing.
  """
  @spec stop_children(binary()) :: :ok
  def stop_children(parent_id) do
    for %{child_id: child_id, parent_id: ^parent_id} <- active(), do: stop_session(child_id)
    :ok
  end

  defp stop_session(id) do
    if Elia.Agent.live?(id), do: Elia.Agent.stop(id)
  catch
    :exit, _ -> :ok
  end

  # ISOL-1: the harness's own git calls go through the jail like every other
  # process it spawns. They run in a chat's workspace — a worktree for a chat in
  # Elia's own project — so the `:worktree` profile binds the tree, the
  # repository's git directory, which a worktree's `.git` pointer file leads to
  # (ISOL-13), and the shared dependencies read-only. They are local calls, so
  # nothing needs the network (ISOL-11).
  defp git(args, root), do: git_cmd(args, root)

  # The output of a git call in `root`, or `nil` when it fails (public for the
  # tests that cover the jail these calls run in).
  @doc false
  def git_out(args, root, trim? \\ true) do
    case git_cmd(args, root) do
      {out, 0} -> if trim?, do: String.trim(out), else: out
      _ -> nil
    end
  end

  # `Elia.Shell.run/2` runs a script, so the arguments are quoted for the shell
  # on the other side of it. The result is the `{output, status}` pair
  # `System.cmd/3` gave, with a timeout counting as a failure (SHELL-3), which
  # no caller of these calls has to tell apart from git exiting non-zero.
  defp git_cmd(args, root) do
    # ISOL-30: the harness's own git runs no hook and no monitor.
    command = Enum.map_join(["git" | Elia.Shell.harness_git_flags() ++ args], " ", &quote_arg/1)

    # A run whose jail was skipped says so in its output (ISOL-12), and one whose
    # layer couldn't be mounted says the tree was read-only (ISOL-27), but these
    # callers read the output as a value — a ref, a path, a NUL-separated list —
    # so the notices come off before it gets to them.
    case Elia.Shell.run(command, cd: root) do
      {:ok, out, status} -> {Elia.Shell.strip_notices(out), status}
      {:timeout, out} -> {Elia.Shell.strip_notices(out), 1}
    end
  end

  # POSIX single-quoting, which bash and `sh` both read as one word.
  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

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

  # SUBTASK-11: an entry is taken before the child exists. The caller that takes
  # it is the one that can send the brief, and it is monitored only until the
  # brief has gone out: a spawner that dies first leaves a child that never ran
  # (SUBTASK-36). A child whose brief is out holds its entry however its spawner
  # goes (SUBTASK-16, SUBTASK-34), and an entry a resumed child takes again is
  # one whose brief went out long ago (`sent: true`, RESUME-7).
  def handle_call({:acquire, parent_id, child_id, root, owner, meta}, _from, state) do
    case writing_in(state, root) do
      nil ->
        sent = meta[:sent] == true

        entry = %{
          child_id: child_id,
          parent_id: parent_id,
          root: root,
          call_id: meta[:call_id],
          start_commit: meta[:start_commit],
          sent: sent,
          owner: if(sent, do: nil, else: owner),
          owner_ref: if(sent, do: nil, else: monitor(owner))
        }

        {:reply, :ok, put_entry(state, entry)}

      id ->
        {:reply, {:error, "Not started: sub-task #{id} is already writing in that workspace."},
         state}
    end
  end

  def handle_call({:brief_sent, child_id}, _from, state) do
    case state.active do
      %{^child_id => entry} ->
        demonitor(entry[:owner_ref])
        {:reply, :ok, put_entry(state, %{entry | sent: true, owner: nil, owner_ref: nil})}

      _none ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:release, child_id}, _from, state),
    do: {:reply, :ok, drop_entry(state, child_id)}

  @impl true
  # SUBTASK-36: the process that took the entry died before the child's brief
  # went out — the spawner is the `spawn_task` call, which the user stopping the
  # parent's turn kills (SUBTASK-17) — so the child never ran: its entry is
  # released and nothing is announced for it. Nothing else a child's death could
  # mean is the entry's business: its session dying, its turn ending, a turn the
  # user stops and a pause at a limit all leave the entry held (SUBTASK-16,
  # SUBTASK-24, SUBTASK-34).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case find_by_ref(state, ref) do
      %{sent: false} = entry -> {:noreply, drop_entry(state, entry.child_id)}
      _none -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp writing_in(state, root) do
    Enum.find_value(state.active, fn {child_id, entry} ->
      if entry.root == root, do: child_id
    end)
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
