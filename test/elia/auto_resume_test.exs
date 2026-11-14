defmodule Elia.AutoResumeTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store, Tasks}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  setup do
    root = Elia.Workspace.root()
    File.write!(Path.join(root, ".gitignore"), "/.elia/\n")
    {_, 0} = git(["add", "-A"])
    {_, 0} = git(["commit", "-q", "--allow-empty", "-m", "start"])
    {head, 0} = git(["rev-parse", "HEAD"])

    start_supervised!(FakeLLM)

    on_exit(fn ->
      File.rm(Path.join(root, ".gitignore"))
      git(["update-ref", "-d", "HEAD"])
      git(["rm", "-r", "--cached", "-q", "-f", "."])
    end)

    %{start_commit: String.trim(head)}
  end

  ## Helpers

  # RESUME-6: the suite's own boot resumes nothing, so a test that covers a
  # resume turns it on for itself.
  defp resume_on do
    Application.put_env(:elia, Elia.Agent.Resumer, enabled: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Agent.Resumer, enabled: false) end)
  end

  defp stop_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    :ok
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 20_000)

  defp await_task_status(id, status, tries \\ 250) do
    case Store.load_task(id) do
      %{status: ^status} ->
        :ok

      _ ->
        if tries == 0 do
          flunk("the task #{id} never became #{status}")
        else
          Process.sleep(20)
          await_task_status(id, status, tries - 1)
        end
    end
  end

  defp listed(id), do: Enum.find(Store.list(1000), &(&1.id == id)) || %{}

  # A chat that was running a turn when the app stopped: the record of the turn
  # is still saved with it (STORE-30, INTR-1).
  defp saved_turn(id, messages, opts \\ []) do
    turn = Keyword.get(opts, :turn, %{id: "turn-1", started_at: DateTime.utc_now()})
    :ok = Store.save(id, messages, Keyword.merge([turn: turn], Keyword.drop(opts, [:turn])))
    on_exit(fn -> Store.delete(id) end)
    :ok
  end

  defp git(args) do
    System.cmd("git", ["-c", "user.name=T", "-c", "user.email=t@example.com" | args],
      cd: Elia.Workspace.root(),
      stderr_to_stdout: true
    )
  end

  # Another running child holds the workspace root. A child of an earlier test
  # may have released it a moment ago, so the entry is taken when it is free.
  defp occupy_root(parent, other, tries \\ 100) do
    case Tasks.acquire(parent, other, Elia.Workspace.root(), %{}) do
      {:error, _message} when tries > 0 ->
        Process.sleep(20)
        occupy_root(parent, other, tries - 1)

      result ->
        result
    end
  end

  # RESUME-1
  test "the boot scan starts a session for every interrupted chat" do
    resume_on()

    parent = Agent.new_id()
    child = Agent.new_id()
    untouched = Agent.new_id()
    on_exit(fn -> for id <- [parent, child, untouched], do: stop_session(id) end)

    :ok = saved_turn(parent, [Message.user("run it")])

    :ok =
      saved_turn(child, [Message.user("do it")], task: %{parent_id: parent, status: "running"})

    # A chat whose last turn ended is not started: the record is what the scan
    # goes by (STORE-39).
    :ok = Store.save(untouched, [Message.user("hi")])

    # The parent's resumed turn, so the sessions the scan starts end their turns.
    FakeLLM.push(FakeLLM.assistant([Message.text("Carried on.")]))

    refute Agent.live?(parent)
    refute Agent.live?(child)

    assert :ok = Elia.Agent.Resumer.resume_interrupted()

    assert Agent.live?(parent)
    assert Agent.live?(child)
    refute Agent.live?(untouched)
  end

  # RESUME-1
  test "the scan leaves a chat whose session already runs to that session" do
    resume_on()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)
    :ok = saved_turn(id, [Message.user("run it")])
    FakeLLM.push(FakeLLM.assistant([Message.text("Carried on.")]))

    Agent.subscribe(id)
    {:ok, pid} = Agent.ensure_started(id)

    # Its own start already resumed the turn or said why not, so the scan has
    # nothing left to do for it — and must not start a second session.
    assert :ok = Elia.Agent.Resumer.resume_interrupted()
    assert Agent.live?(id)
    assert {:ok, ^pid} = Agent.ensure_started(id)
  end

  # RESUME-6
  test "with automatic resume switched off, nothing is resumed" do
    refute Elia.Agent.Resumer.enabled?()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)
    :ok = saved_turn(id, [Message.user("run it")])

    # The boot scan starts nothing at all.
    assert :ok = Elia.Agent.Resumer.resume_interrupted()
    refute Agent.live?(id)

    # RESUME-6, INTR-3: a session that starts for the chat says the app
    # restarted, with no turn carried on.
    Agent.subscribe(id)
    {:ok, _pid} = Agent.ensure_started(id)

    assert_receive {:agent, ^id, {:message, %Message{meta: %{interrupted: true}} = notice}}
    assert Message.text_content(notice) =~ "Send a message to carry on"
    assert %{status: :idle} = Agent.snapshot(id)
    assert Store.load_turn(id) == nil

    resume_on()
    assert Elia.Agent.Resumer.enabled?()
  end

  # RESUME-2, RESUME-3
  test "a session starting for an interrupted chat carries the turn on" do
    resume_on()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)

    # The turn had asked for a command and the app stopped before it had a result.
    call = FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})
    :ok = saved_turn(id, [Message.user("run it"), FakeLLM.assistant([call])])

    FakeLLM.push(FakeLLM.assistant([Message.text("Carried on.")]))

    Agent.subscribe(id)
    {:ok, _pid} = Agent.ensure_started(id)

    # RESUME-3, UI-73: the notice says the turn carries on, marked as INTR-3's is.
    assert_receive {:agent, ^id,
                    {:message, %Message{meta: %{harness: true, interrupted: true}} = notice}}

    assert Message.text_content(notice) =~ "Carrying on with it"

    await_status(id, :running)
    await_status(id, :idle)

    # The call the restart cut off got its error result first, and the turn then
    # ran on over the history the chat already held.
    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool, content: [result]},
             notice,
             %Message{role: :assistant} = reply
           ] = Agent.snapshot(id).messages

    assert %{tool_call_id: "c1", is_error: true, content: text} = result
    assert text =~ "The app restarted while this tool was running"
    assert Message.text_content(reply) == "Carried on."

    # RESUME-3: the model was sent the notice and the closed call, so it knows
    # what happened to its last turn (STOP-3).
    assert [request] = FakeLLM.requests()

    assert Enum.any?(request.messages, fn message ->
             message.role == :user and Message.text_content(message) =~ "Carrying on with it"
           end)

    # RESUME-4: the resumed turn is an ordinary turn, recorded while it ran and
    # cleared when it ended (INTR-1), and its chat is no longer interrupted.
    assert Store.load_turn(id) == nil
    assert %{interrupted: false} = listed(id)
  end

  # RESUME-4, RESUME-5
  test "a resumed turn is a turn like any other, and its record says it was resumed" do
    resume_on()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)
    :ok = saved_turn(id, [Message.user("run it")])

    # The resumed turn asks for a command, so it waits for the user (APPR-2).
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    Agent.subscribe(id)
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    await_status(id, :running)
    await_status(id, :awaiting_approval)

    # RESUME-4: the chat is running, and its tool call is put to the user, so
    # every page lists it as that rather than as interrupted (APPR-2, UI-47,
    # UI-59, UI-72, STORE-31).
    assert id in Agent.awaiting_approval()
    assert %{interrupted: false} = listed(id)

    # RESUME-5: the record of the turn says an automatic resume started it.
    assert %{id: turn_id, resumed: true} = Store.load_turn(id)
    assert turn_id =~ id

    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)

    assert Store.load_turn(id) == nil
  end

  # RESUME-5
  test "a turn that was itself resumed is not resumed again" do
    resume_on()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)
    turn = %{id: "turn-1", started_at: DateTime.utc_now(), resumed: true}
    :ok = saved_turn(id, [Message.user("run it")], turn: turn)

    Agent.subscribe(id)
    {:ok, _pid} = Agent.ensure_started(id)

    # One automatic resume never follows another, so the chat says the app
    # restarted and the user carries on with a message (INTR-3).
    assert_receive {:agent, ^id, {:message, %Message{meta: %{interrupted: true}} = notice}}
    assert Message.text_content(notice) =~ "Send a message to carry on"
    assert %{status: :idle} = Agent.snapshot(id)
    assert Store.load_turn(id) == nil
  end

  # RESUME-8
  test "a chat whose turn was paused at a limit is not resumed" do
    resume_on()

    id = Agent.new_id()
    on_exit(fn -> stop_session(id) end)

    # LIMIT-10: the pause wrote its own message and nothing followed it — the
    # turn was waiting for the user's decision (SESS-27).
    pause = %{
      Message.harness("Step limit reached (100 steps).")
      | meta: %{harness: true, limit: {:steps, 100}}
    }

    :ok = saved_turn(id, [Message.user("run it"), pause])

    Agent.subscribe(id)
    {:ok, _pid} = Agent.ensure_started(id)

    # RESUME-8: the decision stays the user's, so the chat says the app restarted
    # instead of carrying the turn on.
    assert [_, _, %Message{meta: %{interrupted: true}} = notice] = Agent.snapshot(id).messages
    assert Message.text_content(notice) =~ "Send a message to carry on"
    assert %{status: :idle} = Agent.snapshot(id)
    assert Store.load_turn(id) == nil
  end

  # RESUME-7
  test "a resumed sub-task chat gets its watcher back and its result reaches its parent", %{
    start_commit: start_commit
  } do
    resume_on()

    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> stop_session(child) end)

    task = %{
      parent_id: parent,
      parent_call_id: "call-1",
      title: "T",
      brief: "B",
      status: "running",
      start_commit: start_commit
    }

    :ok = saved_turn(child, [Message.user("do it")], task: task)

    # The child's resumed turn: a command the user approves, then its result.
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c2", "finish_task", %{"status" => "done", "summary" => "did it"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    Agent.subscribe(child)
    {:ok, _pid} = Agent.ensure_started(child)

    assert_receive {:agent, ^child, {:message, %Message{meta: %{interrupted: true}}}}
    await_status(child, :awaiting_approval)

    # RESUME-7: the entry was taken again before the turn started, so the child
    # is a running child (SUBTASK-11) and its task is listed as running rather
    # than interrupted (STORE-17).
    assert Tasks.running?(child)
    assert %{task_status: "running"} = listed(child)

    # The entry that was put back is the one `finish_task` records through
    # (SUBTASK-3), and the watcher ends the task when the turn does (SUBTASK-8).
    :ok = Agent.approve(child, "c1")

    await_task_status(child, "done")

    # So the parent's wait gets the result rather than SUBTASK-20's "interrupted
    # by a restart" (SUBTASK-27).
    assert {:ok, json} = Tasks.await_task(%{"task_id" => child}, %{session_id: parent})
    assert %{"task_id" => ^child, "status" => "done", "summary" => "did it"} = Jason.decode!(json)
    assert %{task_status: "done"} = listed(child)
  end

  # RESUME-7
  test "a child whose workspace another child is writing in is not resumed" do
    resume_on()

    parent = Agent.new_id()
    other = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> stop_session(child) end)

    task = %{parent_id: parent, parent_call_id: "call-1", title: "T", status: "running"}
    :ok = saved_turn(child, [Message.user("do it")], task: task)

    # SUBTASK-4, SUBTASK-11: the tree has one writer, and it is another child.
    :ok = occupy_root(parent, other)

    Agent.subscribe(child)
    {:ok, _pid} = Agent.ensure_started(child)

    # RESUME-7: nothing is resumed, and the chat says the app restarted (INTR-3).
    assert_receive {:agent, ^child, {:message, %Message{meta: %{interrupted: true}} = notice}}
    assert Message.text_content(notice) =~ "Send a message to carry on"
    assert %{status: :idle} = Agent.snapshot(child)
    assert Store.load_turn(child) == nil
    refute Tasks.running?(child)
  end
end
