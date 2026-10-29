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
             ~w(edit_file hot_reload list_checkpoints read_file reload_skills rollback run_tests shell write_file)
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

  # MODEL-3
  test "a turn uses the model selected when it starts", %{id: id} do
    Elia.LLMCase.reset_settings()
    Elia.LLMCase.configure(Elia.LLM.OpenRouter, api_key: "or-key")
    :ok = Elia.LLM.select("openrouter", "vendor/picked")

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
end
