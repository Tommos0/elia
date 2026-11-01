defmodule Elia.AgentTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    %{id: id}
  end

  defp await_status(id, status) do
    assert_receive {:agent, ^id, {:status, ^status}}, 5000
  end

  test "plain reply streams and lands in history", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    :ok = Agent.send_message(id, "hi")
    assert_receive {:agent, ^id, {:delta, :text, "Hello!"}}
    await_status(id, :idle)

    assert [%Message{role: :user}, %Message{role: :assistant} = reply] =
             Agent.snapshot(id).messages

    assert Message.text_content(reply) == "Hello!"
    assert [%{system: system, tools: tools}] = FakeLLM.requests()
    assert system =~ "Skill: shell"

    assert Enum.map(tools, & &1.name) |> Enum.sort() ==
             ~w(edit_file hot_reload list_checkpoints read_file reload_skills reset_task rollback run_tests shell spawn_task update_ledger write_file)
  end

  test "shell call waits for approval, runs, and feeds the result back", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo elia"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("It printed elia.")]))

    :ok = Agent.send_message(id, "run echo")
    await_status(id, :awaiting_approval)
    assert {:error, :busy} = Agent.send_message(id, "again")

    :ok = Agent.approve(id, "c1")
    assert_receive {:agent, ^id, {:tool_status, "c1", :running}}
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert %{tool_call_id: "c1", is_error: false, content: content} = result
    assert content =~ "elia\n"
    assert content =~ "[exit: 0]"
  end

  test "denied calls return an error result to the model", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "rm -rf /tmp/x"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("OK, I won't.")]))

    :ok = Agent.send_message(id, "delete it")
    await_status(id, :awaiting_approval)
    :ok = Agent.deny(id, "c1")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()

    assert %Message{content: [%{is_error: true, content: "The user denied" <> _}]} =
             List.last(second.messages)
  end

  test "invalid tool input is rejected without running", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"cmd" => "ls"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Oops.")]))

    :ok = Agent.send_message(id, "list")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()

    assert %Message{content: [%{is_error: true, content: "Invalid input: command is required"}]} =
             List.last(second.messages)
  end

  # LOOP-3
  test "a turn with no max_steps option stops after the default 100 steps", %{} do
    id = start_fake_skill_session([])
    push_repeating_tool_call(101)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:error, "Stopped after 100 steps without finishing"}}, 10_000
    await_status(id, :idle)
  end

  # LOOP-16
  test "the max_steps option sets the turn's step limit", %{} do
    id = start_fake_skill_session(max_steps: 3)
    push_repeating_tool_call(4)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:error, "Stopped after 3 steps without finishing"}}, 10_000
    await_status(id, :idle)
  end

  # Starts a session whose only skill is `fake_skill/1`, plus the given loop
  # options, subscribed like the setup's (LOOP-3, LOOP-16).
  defp start_fake_skill_session(loop_opts) do
    id = Agent.new_id()
    opts = Keyword.put(loop_opts, :skills, fn -> fake_skill("ok") end)
    {:ok, pid} = Agent.ensure_started(id, loop_opts: opts)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    id
  end

  # Scripts the model to ask for the fake skill's tool `times` times, so only
  # the step limit ends the turn.
  defp push_repeating_tool_call(times) do
    fun = fn _request, _on_event ->
      message = FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", %{})])
      {:ok, %{message: message, stop_reason: :tool_use, model: "fake", usage: %{}}}
    end

    for _ <- 1..times, do: FakeLLM.push(fun)
  end

  test "stopping while awaiting approval closes the dangling call", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "sleep 5"})]))

    :ok = Agent.send_message(id, "wait")
    await_status(id, :awaiting_approval)
    :ok = Agent.stop(id)

    %{status: :idle, messages: messages} = Agent.snapshot(id)

    assert %Message{role: :tool, content: [%{tool_call_id: "c1", is_error: true}]} =
             List.last(messages)
  end

  test "history survives a session restart", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([Message.text("Remember me.")]))
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, _pid} = Agent.ensure_started(id)

    assert [%Message{role: :user}, reply] = Agent.snapshot(id).messages
    assert Message.text_content(reply) == "Remember me."
    assert %{title: "hi"} = Enum.find(Elia.Store.list(), &(&1.id == id))
  end

  test "writing a skill and reloading makes its tool available in the same turn", %{id: id} do
    skill_md = "---\nname: greeter\ndescription: Greets people\n---\nUse greet to say hello."

    tools_json =
      ~s([{"name": "greet", "description": "Say hi", "command": "echo hi $ELIA_ARG_NAME",
      "input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}])

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{
          "path" => "skills/greeter/SKILL.md",
          "content" => skill_md
        }),
        FakeLLM.tool_call("w2", "write_file", %{
          "path" => "skills/greeter/tools.json",
          "content" => tools_json
        })
      ])
    )

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("r1", "reload_skills", %{})]))

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("g1", "greet", %{"name" => "Ada; rm -rf /"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "make a greeter skill")
    # Extension writes and reload need no approval; the new script tool does.
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "g1")
    await_status(id, :idle)

    requests = FakeLLM.requests()
    assert "greet" in Enum.map(Enum.at(requests, 2).tools, & &1.name)
    %Message{content: [greet_result]} = List.last(List.last(requests).messages)
    assert %{is_error: false, content: "hi Ada; rm -rf /\n\n[exit: 0]"} = greet_result
  after
    File.rm_rf!(Path.join(Elia.Workspace.skills_dir(), "greeter"))
    Elia.Skills.reload()
  end

  test "failing tests after an Elixir change roll the turn back", %{id: id} do
    path = Path.join(Elia.Workspace.root(), "lib/broken.ex")

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => "lib/broken.ex", "content" => "oops"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Wrote it.")]))

    FakeLLM.push(
      FakeLLM.assistant([Message.text("Tests fail because this is not a mix project.")])
    )

    :ok = Agent.send_message(id, "add a module")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "w1")
    await_status(id, :idle)

    refute File.exists?(path)
    [_, _, third] = FakeLLM.requests()
    assert %Message{meta: %{harness: true}} = notice = List.last(third.messages)
    assert Message.text_content(notice) =~ "rolled back"
  end

  # CTX-6: the rolled-back request's usage is cleared with it.
  test "a refusal rolls the turn back", %{id: id} do
    FakeLLM.push(fn _request, _on_event ->
      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Sure.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{"input_tokens" => 10}
       }}
    end)

    FakeLLM.push(fn _request, _on_event ->
      {:ok, %{message: FakeLLM.assistant([]), stop_reason: :refusal, model: "fake", usage: %{}}}
    end)

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    :ok = Agent.send_message(id, "something declined")
    assert_receive {:agent, ^id, {:error, "The model declined this request."}}, 5000

    assert [%Message{role: :user}, %Message{role: :assistant}] = Agent.snapshot(id).messages
    assert Agent.snapshot(id).last_usage == nil
  end

  # CTX-10: usage carries the estimate for the history that request sent, which
  # excludes the reply it produced.
  test "usage records the estimate of the request's history", %{id: id} do
    FakeLLM.push(fn _request, _on_event ->
      {:ok,
       %{
         message: FakeLLM.assistant([Message.text(String.duplicate("long reply ", 100))]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{"input_tokens" => 10}
       }}
    end)

    :ok = Agent.send_message(id, "hi")
    assert_receive {:agent, ^id, {:usage, usage}}, 5000
    await_status(id, :idle)

    assert usage["estimated_input_tokens"] == Elia.LLM.Context.build([Message.user("hi")]).total
    assert Agent.snapshot(id).last_usage == usage
  end

  # MODEL-3
  test "a turn uses the model selected when it starts", %{id: id} do
    Elia.LLMCase.reset_settings()
    Elia.LLMCase.configure(Elia.LLM.OpenRouter, api_key: "or-key")
    {:ok, _} = Elia.LLM.select("openrouter", "vendor/picked")

    Elia.LLMCase.stub_openrouter_stream(self(), [
      %{"choices" => [%{"delta" => %{"content" => "From OpenRouter."}}]},
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
    ])

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    assert_receive {:request, "/api/v1/chat/completions", _headers, %{"model" => "vendor/picked"}}
    assert FakeLLM.requests() == []
    assert Message.text_content(List.last(Agent.snapshot(id).messages)) == "From OpenRouter."

    # Explicit loop options win over the selection.
    other = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(other, loop_opts: [llm: %{provider: FakeLLM}])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    Agent.subscribe(other)
    FakeLLM.push(FakeLLM.assistant([Message.text("From fake.")]))

    :ok = Agent.send_message(other, "hi")
    await_status(other, :idle)
    assert [request] = FakeLLM.requests()
    refute Map.has_key?(request, :model)
  end

  # MODEL-1, MODEL-16, SESS-14
  test "the chat remembers its model across restarts and other chats' choices", %{id: id} do
    Elia.LLMCase.reset_settings()
    Elia.LLMCase.configure(Elia.LLM.OpenRouter, api_key: "or-key")
    on_exit(fn -> Elia.Store.delete(id) end)

    # Selecting in an empty chat is broadcast but not written to disk.
    {:ok, _} = Agent.select_model(id, "openrouter", "vendor/chat-model", "Chat Model")
    assert_receive {:agent, ^id, {:model, %{model: "vendor/chat-model"}}}
    assert Elia.Store.load_model(id) == nil

    # A later choice elsewhere only changes the default.
    {:ok, _} = Elia.LLM.select("openrouter", "vendor/elsewhere")

    Elia.LLMCase.stub_openrouter_stream(self(), [
      %{"choices" => [%{"delta" => %{"content" => "Hi."}}]},
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
    ])

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    assert_receive {:request, "/api/v1/chat/completions", _, %{"model" => "vendor/chat-model"}}
    assert %{model: "vendor/chat-model"} = Elia.Store.load_model(id)

    # Restart the session: the selection is reloaded.
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, _} = Agent.ensure_started(id)
    assert %{model: "vendor/chat-model"} = Agent.snapshot(id).selection
  end

  # MODEL-16
  test "a chat without a selection pins the default when its first turn starts", %{id: id} do
    Elia.LLMCase.reset_settings()
    Elia.LLMCase.configure(Elia.LLM.OpenRouter, api_key: "or-key")
    on_exit(fn -> Elia.Store.delete(id) end)
    {:ok, _} = Elia.LLM.select("openrouter", "vendor/first")
    assert Agent.snapshot(id).selection == nil

    Elia.LLMCase.stub_openrouter_stream(self(), [
      %{"choices" => [%{"delta" => %{"content" => "Hi."}}]},
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
    ])

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    assert %{model: "vendor/first"} = Agent.snapshot(id).selection

    {:ok, _} = Elia.LLM.select("openrouter", "vendor/second")
    assert %{model: "vendor/first"} = Agent.snapshot(id).selection
  end

  # SESS-15
  test "a session with state from before :selection existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :selection))

    assert %{selection: nil, messages: []} = Agent.snapshot(id)
  end

  # SESS-15, SESS-17
  test "a session with state from before :task_meta existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :task_meta))

    assert %{messages: []} = Agent.snapshot(id)
    assert {:error, :not_a_task} = Agent.update_task(id, %{status: "done"})
  end

  # SESS-17, SESS-18
  test "task metadata is saved with the chat and can be updated" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    task = %{parent_id: "p", title: "T", brief: "B", status: "running"}
    selection = %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}
    default = Elia.Settings.get(:model)

    {:ok, _pid} =
      Agent.ensure_started(id,
        task: task,
        selection: selection,
        loop_opts: [llm: %{provider: FakeLLM}]
      )

    Agent.subscribe(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    assert Elia.Store.load_task(id) == task
    assert Elia.Store.load_model(id) == selection
    # SESS-17: the selection isn't stored as the default model.
    assert Elia.Settings.get(:model) == default

    :ok = Agent.update_task(id, %{status: "done"})
    assert %{status: "done", title: "T"} = Elia.Store.load_task(id)
    # SESS-20, SESS-7
    assert_receive {:agent, ^id, {:task, %{status: "done", title: "T"}}}
    assert %{task: %{status: "done"}} = Agent.snapshot(id)
  end

  # SESS-7
  test "an ordinary chat's snapshot has no task", %{id: id} do
    assert %{task: nil} = Agent.snapshot(id)
  end

  # SESS-21, LLM-33, SUBTASK-20
  test "a session closes tool calls left unanswered by an app restart" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    call = FakeLLM.tool_call("c1", "shell", %{"command" => "sleep 100"})

    :ok =
      Elia.Store.save(id, [Message.user("run it"), FakeLLM.assistant([call])])

    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert %{status: :idle, messages: [_, _, %Message{role: :tool, content: [result]}]} =
             Agent.snapshot(id)

    assert %{tool_call_id: "c1", is_error: true, content: "The app restarted" <> _} = result
    # Saved, so the next start doesn't do it again.
    assert [_, _, %Message{role: :tool}] = Elia.Store.load(id)

    # A finished chat is left alone.
    done = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(done) end)
    :ok = Elia.Store.save(done, [Message.user("hi"), FakeLLM.assistant([Message.text("hello")])])
    {:ok, pid} = Agent.ensure_started(done)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    assert [_, _] = Agent.snapshot(done).messages
  end

  # SESS-19
  test "status changes go to the activity topic and the registry", %{id: id} do
    Agent.subscribe_activity()
    refute id in Agent.awaiting_approval()

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    assert_receive {:chat_status, ^id, :running}
    assert_receive {:chat_status, ^id, :awaiting_approval}
    assert id in Agent.awaiting_approval()

    :ok = Agent.approve(id, "c1")
    assert_receive {:chat_status, ^id, :idle}, 5000
    refute id in Agent.awaiting_approval()
  end

  ## Projects (phase 3)

  defp tmp_dir(name) do
    dir = Path.join(System.tmp_dir!(), "elia-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp other_project(folder),
    do: %{id: Agent.new_id(), name: "Other", folder: folder, harness?: false}

  defp start_project_session(project, opts \\ []) do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, [project: project] ++ opts)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    id
  end

  # PROJ-9, SESS-7
  test "a chat belongs to its project" do
    project = other_project(tmp_dir("belongs"))
    id = start_project_session(project)

    assert %{project: %{id: project_id}} = Agent.snapshot(id)
    assert project_id == project.id
  end

  # PROJ-12, FILE-1, FILE-4
  test "a chat's project folder is its workspace for the file tools" do
    dir = tmp_dir("files")
    id = start_project_session(other_project(dir), loop_opts: [llm: %{provider: FakeLLM}])

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => "notes.txt", "content" => "hello"}),
        FakeLLM.tool_call("w2", "write_file", %{"path" => "../escape.txt", "content" => "no"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "write it")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "w1")
    await_status(id, :idle)

    # The relative path resolved against the project folder.
    assert File.read!(Path.join(dir, "notes.txt")) == "hello"
    refute File.exists?(Path.join(Path.dirname(dir), "escape.txt"))

    # A path outside the project folder is refused (WS-1, PROJ-12).
    [_, second] = FakeLLM.requests()

    assert %Message{role: :tool, content: [%{is_error: false}, escape]} =
             List.last(second.messages)

    assert %{is_error: true, content: content} = escape
    assert content =~ "outside the workspace"
  end

  # PROJ-12, SHELL-2
  test "the shell runs in the chat's project folder" do
    dir = tmp_dir("shell")
    File.write!(Path.join(dir, "marker.txt"), "here")
    id = start_project_session(other_project(dir), loop_opts: [llm: %{provider: FakeLLM}])

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("s1", "shell", %{"command" => "cat marker.txt"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "where")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "s1")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    assert %Message{content: [%{content: content, is_error: false}]} = List.last(second.messages)
    assert content == "here\n[exit: 0]"
  end

  # PROJ-15, PROJ-17, PROJ-18
  test "the system prompt is the chat's project's AGENTS.md and skills, without self-modification" do
    dir = tmp_dir("prompt")
    File.write!(Path.join(dir, "AGENTS.md"), "Project rule: be terse.")

    skill_dir = Path.join([dir, "skills", "proj-skill"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: proj-skill\ndescription: Only in this project\n---\nUse it.\n"
    )

    id = start_project_session(other_project(dir), loop_opts: [llm: %{provider: FakeLLM}])
    FakeLLM.push(FakeLLM.assistant([Message.text("Ok.")]))

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    [request] = FakeLLM.requests()
    assert request.system =~ "Project rule: be terse."
    assert request.system =~ "Skill: proj-skill"
    assert request.system =~ "Skill: harness"
    refute request.system =~ "self-modification"
    refute "hot_reload" in Enum.map(request.tools, & &1.name)
    refute "list_checkpoints" in Enum.map(request.tools, & &1.name)
  end

  # PROJ-9, STORE-19
  test "a chat's project survives a session restart through Elia.Store" do
    {:ok, project} = Elia.Projects.create("Restart", tmp_dir("restart"))
    on_exit(fn -> Elia.Projects.delete(project.id) end)

    id = start_project_session(project, loop_opts: [llm: %{provider: FakeLLM}])
    on_exit(fn -> Elia.Store.delete(id) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Ok.")]))
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    assert Elia.Store.load_project(id) == project.id
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert %{project: %{id: project_id}} = Agent.snapshot(id)
    assert project_id == project.id
  end

  # SESS-15, PROJ-9
  test "a session with state from before :project existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :project))

    assert %{project: %{id: "harness"}} = Agent.snapshot(id)
  end

  # PROJ-14
  test "a write in another project's folder doesn't checkpoint Elia's workspace" do
    dir = tmp_dir("ckpt")
    turn = "proj-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Elia.Skills.Files.write_file(
               %{"path" => "a.txt", "content" => "x"},
               %{turn_id: turn, workspace: dir}
             )

    assert File.read!(Path.join(dir, "a.txt")) == "x"
    # No checkpoint, so verification (and `mix test`) never runs for the turn.
    assert Elia.Checkpoint.for_turn(turn) == nil

    # In Elia's own root, the same call checkpoints (PROJ-14, CKPT-2).
    own = "own-#{System.unique_integer([:positive])}"
    path = "skills/tmp-proj14/a.txt"

    assert {:ok, _} =
             Elia.Skills.Files.write_file(%{"path" => path, "content" => "y"}, %{turn_id: own})

    assert Elia.Checkpoint.for_turn(own) != nil
  after
    File.rm_rf!(Path.join(Elia.Workspace.skills_dir(), "tmp-proj14"))
  end

  ## Compaction (COMPACT)

  # Six turns of bulky work: enough for the trigger to fire and for turns to age
  # out of a working set of two.
  defp big_history(turns) do
    Enum.flat_map(1..turns, fn n ->
      [
        Message.user("task #{n}: #{String.duplicate("ask ", 60)}"),
        %Message{
          role: :assistant,
          content: [
            %{type: :reasoning, text: String.duplicate("think #{n} ", 60)},
            %{
              type: :tool_call,
              id: "c#{n}",
              name: "read_file",
              input: %{"path" => "lib/file#{n}.ex"}
            }
          ]
        },
        %Message{
          role: :tool,
          content: [Message.tool_result("c#{n}", String.duplicate("output #{n} ", 60))]
        },
        %Message{role: :assistant, content: [Message.text("done #{n}")]}
      ]
    end)
  end

  defp start_compaction_session(id, opts) do
    {:ok, pid} = Agent.ensure_started(id, opts)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    pid
  end

  # COMPACT-2, COMPACT-5, COMPACT-6, COMPACT-24, COMPACT-26, SESS-24
  test "a turn over the trigger sends the model the request view, keeping the history" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    messages = big_history(6)
    :ok = Elia.Store.save(id, messages)

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [
        llm: %{provider: FakeLLM},
        summarizer: fn _ -> {:ok, "Six turns of reading files."} end
      ]
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "carry on")

    assert_receive {:agent, ^id, {:compaction, compaction}}, 5000
    assert_receive {:agent, ^id, {:usage, usage}}, 5000
    await_status(id, :idle)

    assert compaction.level == 3
    assert compaction.summary == "Six turns of reading files."

    # COMPACT-2: the model got the smaller view, the session kept everything.
    [request] = FakeLLM.requests()
    assert length(request.messages) < length(messages) + 1
    snapshot = Agent.snapshot(id)
    assert length(snapshot.messages) == length(messages) + 2

    # COMPACT-19, COMPACT-23: the summary and the marker lead the request.
    assert [%Message{meta: %{compaction: :summary}} = head | _] = request.messages
    assert Message.text_content(head) =~ "Six turns of reading files."
    assert Enum.any?(request.messages, &(&1.meta[:compaction] == :marker))

    # COMPACT-26: the estimate is of the request view, not of the history.
    assert usage["estimated_input_tokens"] == Elia.LLM.Context.build(request.messages).total
    assert usage["estimated_input_tokens"] < Elia.LLM.Context.build(messages).total

    # COMPACT-24: saved with the conversation.
    assert %{level: 3, summary: "Six turns of reading files."} = Elia.Store.load_compaction(id)

    # A restart reloads it: neither re-summarized nor lost.
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, _pid} = Agent.ensure_started(id)
    assert %{level: 3, summary: "Six turns of reading files."} = Agent.snapshot(id).compaction
  end

  # COMPACT-1, COMPACT-9, COMPACT-28
  test "a size-bounded working set sends a smaller request view, keeping the history" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    messages = big_history(4)
    :ok = Elia.Store.save(id, messages)

    start_compaction_session(id,
      compaction: %{budget: 1},
      loop_opts: [
        llm: %{provider: FakeLLM},
        summarizer: fn _ -> {:ok, "The first turns, folded."} end
      ]
    )

    # The turn count alone (the default working set of six) covers every turn of
    # a four-turn chat: the trigger fires, but nothing is cold and the whole
    # history is sent.
    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "one")
    await_status(id, :idle)

    assert Agent.snapshot(id).compaction.covered == 0
    [first] = FakeLLM.requests()
    assert length(first.messages) == length(messages) + 1

    # Bounding the working set by size keeps only the current turn, so the model
    # is sent a smaller view (COMPACT-28).
    assert :ok = Agent.set_compaction(id, %{working_set_tokens: 1})

    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "two")
    await_status(id, :idle)

    snapshot = Agent.snapshot(id)
    assert snapshot.compaction.covered > 0
    [_, second] = FakeLLM.requests()
    assert length(second.messages) < length(first.messages)
    assert Enum.any?(second.messages, &(&1.meta[:compaction] == :marker))

    # COMPACT-1: the history itself is complete, and untouched.
    assert length(snapshot.messages) == length(messages) + 4
    assert Enum.slice(snapshot.messages, 0, length(messages)) == messages
  end

  # A skill with one tool that returns a canned output, so a step's own tool
  # result is known exactly and no real tool runs (LOOP-16).
  defp fake_skill(output) do
    [
      %Elia.Skill{
        name: "fake",
        description: "Says what it was given",
        instructions: "Use `fake_tool` to get the canned output.",
        tools: [
          %Elia.Tool{
            name: "fake_tool",
            description: "Returns a canned output",
            input_schema: %{"type" => "object", "properties" => %{}},
            run: fn _input -> {:ok, output} end
          }
        ]
      }
    ]
  end

  # COMPACT-1, COMPACT-5, COMPACT-29
  test "a long turn compacts mid-turn, sending a smaller request each step" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # One turn of work in the history, and a current turn that will grow.
    messages = big_history(1)
    :ok = Elia.Store.save(id, messages)
    turn_tokens = Elia.LLM.Compaction.tokens(messages)
    carry_on = Message.user("carry on")
    user_tokens = Elia.LLM.Compaction.tokens([carry_on])

    # At the turn start that turn and the new user message both fit the working
    # set; the step's own tool output then pushes the older turn out of it
    # (COMPACT-28), so it becomes cold and is elided.
    output = String.duplicate("out ", 50)

    start_compaction_session(id,
      compaction: %{budget: 1, working_set_tokens: turn_tokens + user_tokens + 1},
      loop_opts: [llm: %{provider: FakeLLM}, skills: fake_skill(output)]
    )

    test_pid = self()

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "fake_tool", %{})]))

    # The step after the tool result blocks, so the turn is provably still
    # running when the mid-turn compaction is asserted on.
    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:second_request, self()})

      receive do
        :go -> :ok
      end

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("done")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(id, "carry on")

    # COMPACT-29: the state the loop advanced to is reported, saved and
    # broadcast, and it arrives before the turn ends.
    assert_receive {:second_request, loop}, 5000
    assert_receive {:agent, ^id, {:compaction, %{level: 3, covered: 4}}}, 5000
    assert Agent.snapshot(id).status == :running

    send(loop, :go)
    await_status(id, :idle)

    assert %{level: 3, covered: 4} = Elia.Store.load_compaction(id)

    [first, second] = FakeLLM.requests()

    # The request view shrinks as the turn grows: the older turn aged out of the
    # working set and was elided, while the step's own output was added.
    assert Elia.LLM.Compaction.tokens(second.messages) <
             Elia.LLM.Compaction.tokens(first.messages)

    assert Enum.any?(second.messages, &(&1.meta[:compaction] == :marker))
    refute Enum.any?(second.messages, &(Message.text_content(&1) =~ "done 1"))

    # COMPACT-29: every message of the turn being run is still sent in full.
    assert Enum.any?(second.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c1"}]} ->
               content == output

             _ ->
               false
           end)

    assert Enum.any?(second.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c1"))

             _ ->
               false
           end)

    # The request the step sent ends with that turn's own tool result.
    assert %Message{role: :tool, content: [%{tool_call_id: "c1", content: ^output}]} =
             List.last(second.messages)

    # COMPACT-1: the session's history is untouched and complete.
    snapshot = Agent.snapshot(id)
    assert Enum.slice(snapshot.messages, 0, length(messages)) == messages
    assert length(snapshot.messages) == length(messages) + 4
  end

  # COMPACT-7
  test "no window means no automatic compaction" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    messages = big_history(4)
    :ok = Elia.Store.save(id, messages)

    start_compaction_session(id,
      selection: %{provider: "openrouter", model: "vendor/no-window", name: "No window"},
      compaction: %{budget: 1},
      loop_opts: [llm: %{provider: FakeLLM}]
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "carry on")
    await_status(id, :idle)

    assert Agent.snapshot(id).compaction.level == 0
    [request] = FakeLLM.requests()
    assert length(request.messages) == length(messages) + 1
  end

  # COMPACT-9
  test "a chat's compaction options are configurable and saved" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(2))
    start_compaction_session(id, loop_opts: [llm: %{provider: FakeLLM}])

    assert :ok =
             Agent.set_compaction(id, %{
               budget: 5,
               working_set: 2,
               working_set_tokens: 1000,
               auto: false
             })

    assert_receive {:agent, ^id, {:compaction, %{options: %{budget: 5}}}}

    assert %{budget: 5, working_set: 2, working_set_tokens: 1000, auto: false} =
             Agent.snapshot(id).compaction.options

    assert %{options: %{budget: 5, auto: false}} = Elia.Store.load_compaction(id)
  end

  # COMPACT-10, SESS-25
  test "compact now compacts an idle chat, ignoring the threshold and the target" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{working_set: 2},
      loop_opts: [
        llm: %{provider: FakeLLM},
        summarizer: fn _ -> {:ok, "The first turns, folded."} end
      ]
    )

    # The default budget is far away: the turn itself doesn't compact.
    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "carry on")
    await_status(id, :idle)
    assert Agent.snapshot(id).compaction.level == 0
    [request] = FakeLLM.requests()
    assert length(request.messages) == length(big_history(4)) + 1

    :ok = Agent.compact(id)
    assert_receive {:agent, ^id, {:compaction, compaction}}, 5000
    assert compaction.level == 3
    assert compaction.summary == "The first turns, folded."
    assert %{level: 3} = Elia.Store.load_compaction(id)
  end

  # COMPACT-10, SESS-25
  test "compact now refuses while a turn is running" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    start_compaction_session(id, loop_opts: [llm: %{provider: FakeLLM}])

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))
    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)

    assert {:error, :busy} = Agent.compact(id)
    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)
  end

  # COMPACT-21, COMPACT-24, SESS-25, SESS-26
  test "pins are set, saved with the chat and reloaded on restart" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(2))
    start_compaction_session(id, loop_opts: [llm: %{provider: FakeLLM}])

    assert :ok = Agent.set_pin(id, 1)
    assert_receive {:agent, ^id, {:compaction, %{pins: [{1, nil}]}}}

    assert :ok = Agent.set_pin(id, 2, 0)
    assert %{pins: pins} = Agent.snapshot(id).compaction
    assert {1, nil} in pins and {2, 0} in pins

    assert :ok = Agent.set_pin(id, 1, nil, false)
    refute {1, nil} in Agent.snapshot(id).compaction.pins
    assert %{pins: pins} = Elia.Store.load_compaction(id)
    assert {2, 0} in pins

    # A message that isn't there can't be pinned.
    assert {:error, :no_such_message} = Agent.set_pin(id, 99)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, _pid} = Agent.ensure_started(id)
    assert {2, 0} in Agent.snapshot(id).compaction.pins
  end

  # COMPACT-17, COMPACT-18, COMPACT-19
  test "a second compaction folds the previous summary, not the whole history" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(6))
    test_pid = self()

    summarizer = fn input ->
      send(test_pid, {:summary_input, input})
      {:ok, "folded summary"}
    end

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: summarizer]
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "one")
    assert_receive {:summary_input, first}, 5000
    assert first =~ "task 1"
    await_status(id, :idle)
    assert Agent.snapshot(id).compaction.summary == "folded summary"

    # More turns age out; the next compaction folds them into the summary it
    # already has, and reads nothing that was already folded.
    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "two")
    assert_receive {:summary_input, _}, 5000
    await_status(id, :idle)

    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "three")
    assert_receive {:summary_input, third}, 5000
    await_status(id, :idle)

    assert third =~ "The summary so far:"
    assert third =~ "folded summary"
    refute third =~ "task 1:"
  end

  # COMPACT-20
  test "a summarizer that fails leaves the pruned view and no error" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    # The summarizer call fails; the turn's own call then goes through.
    FakeLLM.push(fn request, _on_event ->
      if request[:system] =~ "running summary" do
        {:error, "the summarizer is down"}
      else
        flunk("the summary request should be the first one")
      end
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("carried on")]))

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}]
    )

    :ok = Agent.send_message(id, "carry on")
    assert_receive {:agent, ^id, {:compaction, compaction}}, 5000
    await_status(id, :idle)

    # Pruned, not summarized, and the turn went on.
    assert compaction.level == 3
    assert compaction.summary == nil
    assert %{messages: messages} = Agent.snapshot(id)
    assert Message.text_content(List.last(messages)) == "carried on"

    [summary_request, request] = FakeLLM.requests()
    assert summary_request.system =~ "running summary"
    refute Enum.any?(request.messages, &(&1.meta[:compaction] == :summary))
    assert Enum.any?(request.messages, &(&1.meta[:compaction] == :marker))
  end

  # COMPACT-21, COMPACT-22
  test "the model pins facts by writing to the ledger, which survives compacting" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [
        llm: %{provider: FakeLLM},
        summarizer: fn _ -> {:ok, "Four turns, folded."} end
      ]
    )

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("l1", "update_ledger", %{
          "entries" => ["COMPACT-22: the ledger is in lib/elia/llm/compaction.ex"]
        })
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))
    :ok = Agent.send_message(id, "remember this")
    await_status(id, :idle)

    assert ["COMPACT-22: the ledger is in lib/elia/llm/compaction.ex"] =
             Agent.snapshot(id).compaction.ledger

    assert ["COMPACT-22: the ledger is in lib/elia/llm/compaction.ex"] =
             Elia.Store.load_compaction(id).ledger

    # The next request carries it verbatim, alongside the summary (COMPACT-22).
    FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))
    :ok = Agent.send_message(id, "and again")
    await_status(id, :idle)

    request = List.last(FakeLLM.requests())
    ledger = Enum.find(request.messages, &(&1.meta[:compaction] == :ledger))
    assert Message.text_content(ledger) =~ "COMPACT-22: the ledger is in"
    assert Enum.any?(request.messages, &(&1.meta[:compaction] == :summary))
  end

  # SESS-15, SESS-26
  test "a session with state from before :compaction existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :compaction))

    assert %{compaction: %Elia.LLM.Compaction{level: 0}} = Agent.snapshot(id)
  end
end
