defmodule Elia.AutoApproveTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  # APPR-13, APPR-14: every tool that can need approval in Elia's own project.
  # APPR: what can need approval — every tool whose work is a change to the
  # machine: the files, the shell, a sub-task, starting a terminal (TERM-25) and
  # typing into one (TERM-32).
  @approvable ~w(delete_file edit_file list_files read_file search_files shell spawn_task terminal_send terminal_start write_file)

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    # APPR-14: a new chat auto-approves everything, so this chat is started with
    # an empty set — it is the one that asks.
    {:ok, pid} = Agent.ensure_started(id, auto_approve: [])
    Agent.subscribe(id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
      Store.delete(id)
    end)

    %{id: id}
  end

  # APPR-14, APPR-8, APPR-10, STORE-14
  test "a new chat starts with every tool that can need approval auto-approved" do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
      Store.delete(id)
    end)

    Agent.subscribe(id)
    assert %{auto_approve: @approvable, messages: []} = Agent.snapshot(id)

    FakeLLM.push(FakeLLM.assistant([shell_call("c1", "echo default")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    assert_receive {:agent, ^id, {:tool_status, "c1", :approved}}, 5000
    await_status(id, :idle)

    refute_received {:agent, ^id, {:status, :awaiting_approval}}
    refute_received {:agent, ^id, {:tool_status, "c1", :awaiting_approval}}

    # The set the chat started with is saved with its first message (APPR-12).
    assert Store.load_auto_approve(id) == @approvable
  end

  # APPR-14, STORE-15: a chat that already has messages is not loosened.
  test "a chat that has messages keeps the set its file holds" do
    plain = Agent.new_id()
    :ok = Store.save(plain, [Message.user("hi")])
    {:ok, plain_pid} = Agent.ensure_started(plain)

    saved = Agent.new_id()
    :ok = Store.save(saved, [Message.user("hi")], auto_approve: ["shell"])
    {:ok, saved_pid} = Agent.ensure_started(saved)

    on_exit(fn ->
      for {pid, id} <- [{plain_pid, plain}, {saved_pid, saved}] do
        DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
        Store.delete(id)
      end
    end)

    assert %{auto_approve: []} = Agent.snapshot(plain)
    assert %{auto_approve: ["shell"]} = Agent.snapshot(saved)
  end

  # APPR-14, FOLDER-8: the default set is worked out from the project's skills,
  # so a folder skill's script tool — which always needs approval, because the
  # agent can write it without approval — is in it.
  test "the default set includes a folder skill's script tools" do
    dir = Path.join(Elia.Workspace.skills_dir(), "defaulter")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: defaulter\ndescription: Defaults\n---\nUse it.\n"
    )

    File.write!(
      Path.join(dir, "tools.json"),
      ~s([{"name": "default_greet", "description": "Say hi", "command": "echo hi",
      "input_schema": {"type": "object", "properties": {}}}])
    )

    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert "default_greet" in Agent.snapshot(id).auto_approve
  after
    File.rm_rf!(Path.join(Elia.Workspace.skills_dir(), "defaulter"))
    Elia.Skills.reload()
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 5000)

  defp shell_call(call_id, command),
    do: FakeLLM.tool_call(call_id, "shell", %{"command" => command})

  defp tool_result(request, call_id) do
    request.messages
    |> Enum.filter(&(&1.role == :tool))
    |> Enum.flat_map(& &1.content)
    |> Enum.find(&(&1.tool_call_id == call_id))
  end

  # APPR-8, APPR-10
  test "an auto-approved tool runs without asking", %{id: id} do
    :ok = Agent.set_auto_approve(id, "shell", true)

    FakeLLM.push(FakeLLM.assistant([shell_call("c1", "echo auto")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    assert_receive {:agent, ^id, {:tool_status, "c1", :approved}}, 5000
    await_status(id, :idle)

    refute_received {:agent, ^id, {:status, :awaiting_approval}}
    refute_received {:agent, ^id, {:tool_status, "c1", :awaiting_approval}}

    [_, second] = FakeLLM.requests()
    assert %{is_error: false, content: content} = tool_result(second, "c1")
    assert content =~ "auto\n"
  end

  # APPR-8
  test "a tool that is not auto-approved still asks", %{id: id} do
    :ok = Agent.set_auto_approve(id, "write_file", true)

    FakeLLM.push(FakeLLM.assistant([shell_call("c1", "echo ask")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)
    :ok = Agent.deny(id, "c1")
    await_status(id, :idle)
  end

  # APPR-9, STORE-8: `.elia` is a protected path, so the file tools can't write
  # the harness's own data even where auto-approval is on.
  test "auto-approval does not override a policy denial", %{id: id} do
    :ok = Agent.set_auto_approve(id, "write_file", true)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => ".elia/nope", "content" => "x"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Refused.")]))

    :ok = Agent.send_message(id, "write it")
    await_status(id, :idle)

    refute_received {:agent, ^id, {:tool_status, "w1", :approved}}
    [_, second] = FakeLLM.requests()
    assert %{is_error: true, content: content} = tool_result(second, "w1")
    assert content =~ "protected"
  end

  # APPR-10
  test "the remaining calls still wait when only some are auto-approved", %{id: id} do
    :ok = Agent.set_auto_approve(id, "shell", true)

    FakeLLM.push(
      FakeLLM.assistant([
        shell_call("c1", "echo one"),
        FakeLLM.tool_call("r1", "read_file", %{"path" => "/etc/hostname"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :awaiting_approval)

    assert %{tool_status: %{"c1" => :approved, "r1" => :awaiting_approval}} =
             Agent.snapshot(id)

    :ok = Agent.approve(id, "r1")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    assert %{is_error: false} = tool_result(second, "c1")
    assert %{is_error: false} = tool_result(second, "r1")
  end

  # APPR-11
  test "turning auto-approval on approves that tool's pending calls", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([
        shell_call("c1", "echo one"),
        shell_call("c2", "echo two"),
        FakeLLM.tool_call("r1", "read_file", %{"path" => "/etc/hostname"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :awaiting_approval)

    :ok = Agent.set_auto_approve(id, "shell", true)

    assert %{
             status: :awaiting_approval,
             tool_status: %{"c1" => :approved, "c2" => :approved, "r1" => :awaiting_approval}
           } = Agent.snapshot(id)

    :ok = Agent.approve(id, "r1")
    await_status(id, :idle)
  end

  # APPR-11
  test "switching a tool on for the last pending call releases the step", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([shell_call("c1", "echo only")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :awaiting_approval)
    :ok = Agent.set_auto_approve(id, "shell", true)
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    assert %{is_error: false, content: content} = tool_result(second, "c1")
    assert content =~ "only\n"
  end

  # APPR-11
  test "turning auto-approval off makes later calls ask again", %{id: id} do
    :ok = Agent.set_auto_approve(id, "shell", true)
    :ok = Agent.set_auto_approve(id, "shell", false)

    FakeLLM.push(FakeLLM.assistant([shell_call("c1", "echo again")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)
  end

  # APPR-13
  test "only tools that can need approval can be switched on", %{id: id} do
    assert {:error, :not_approvable} = Agent.set_auto_approve(id, "reload_skills", true)
    assert {:error, :not_approvable} = Agent.set_auto_approve(id, "no_such_tool", true)
    assert :ok = Agent.set_auto_approve(id, "read_file", true)
    assert %{auto_approve: ["read_file"]} = Agent.snapshot(id)

    # A name that is already on can always be turned off.
    assert :ok = Agent.set_auto_approve(id, "read_file", false)
    assert %{auto_approve: []} = Agent.snapshot(id)
  end

  # SESS-6, SESS-7, SESS-16
  test "changes are broadcast and shown in the snapshot, sorted", %{id: id} do
    assert %{auto_approve: []} = Agent.snapshot(id)

    :ok = Agent.set_auto_approve(id, "shell", true)
    assert_receive {:agent, ^id, {:auto_approve, ["shell"]}}
    :ok = Agent.set_auto_approve(id, "edit_file", true)
    assert_receive {:agent, ^id, {:auto_approve, ["edit_file", "shell"]}}
    :ok = Agent.set_auto_approve(id, "shell", false)
    assert_receive {:agent, ^id, {:auto_approve, ["edit_file"]}}

    assert %{auto_approve: ["edit_file"]} = Agent.snapshot(id)
  end

  # APPR-12, SESS-16, STORE-14, STORE-15
  test "the set is per chat and survives a restart", %{id: id} do
    other = Agent.new_id()
    # APPR-14: the other chat is started with its own (empty) set.
    {:ok, other_pid} = Agent.ensure_started(other, auto_approve: [])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, other_pid) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))
    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    :ok = Agent.set_auto_approve(id, "shell", true)
    assert Store.load_auto_approve(id) == ["shell"]
    assert %{auto_approve: []} = Agent.snapshot(other)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, _} = Agent.ensure_started(id)
    assert %{auto_approve: ["shell"]} = Agent.snapshot(id)

    :ok = Agent.set_auto_approve(id, "shell", false)
    assert Store.load_auto_approve(id) == []
  end

  # SESS-16: an empty chat isn't written to disk
  test "switching a tool on in an empty chat writes nothing", %{id: id} do
    :ok = Agent.set_auto_approve(id, "shell", true)
    assert Store.load_auto_approve(id) == []
    refute File.exists?(Path.join(Store.dir(), id <> ".term"))
  end

  # SESS-15
  test "a session with state from before :auto_approve existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :auto_approve))

    # APPR-14: the upgrade works out the default for a chat that is still new.
    assert %{auto_approve: @approvable, messages: []} = Agent.snapshot(id)
  end

  # SESS-15
  test "upgrading keeps the fields the state already has", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    selection = %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}

    :sys.replace_state(pid, fn state ->
      state |> Map.delete(:auto_approve) |> Map.put(:selection, selection)
    end)

    assert %{selection: ^selection, auto_approve: @approvable} = Agent.snapshot(id)
  end
end
