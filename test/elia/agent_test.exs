defmodule Elia.AgentTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    # APPR-14: a new chat auto-approves everything, so these chats are started
    # with an empty set: what they test is the approval flow.
    {:ok, pid} = Agent.ensure_started(id, auto_approve: [])
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    %{id: id}
  end

  defp await_status(id, status) do
    assert_receive {:agent, ^id, {:status, ^status}}, 5000
  end

  # COMPACT-40, COMPACT-41: the state a pass folded its summary into. The
  # elision is broadcast from the callback the pass ran in, and the summary
  # later, from the worker that folded it, so this waits for the second
  # broadcast rather than the first.
  defp await_summary(id) do
    receive do
      {:agent, ^id, {:compaction, %{summary: summary} = compaction}} when is_binary(summary) ->
        compaction
    after
      5000 -> flunk("no summary was folded")
    end
  end

  # LOOP-2, SESS-5: the loop's text deltas reach the session as they stream, and
  # what it produces lands in the history.
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
             ~w(ask_user await_task cd get_chat_settings list_chats mark_done read_chat reload_skills request_network_host search_chats set_title shell spawn_task terminal_read terminal_send terminal_start terminal_stop update_ledger view_image)
  end

  # LOOP-9, LOOP-11, SHELL-1, SESS-3: the call is approved before it runs
  # (LOOP-9, SHELL-1), its status is reported as `:running` (LOOP-11), and a
  # message sent while the turn is in progress is refused (SESS-3).
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

  # LOOP-6, LOOP-7, LOOP-12: a call that can't run is answered rather than run —
  # the raw input when it wasn't valid JSON, the name when there is no such tool,
  # and the crash when the tool raises — and the turn carries on.
  test "a call that can't run gets an error result, and the turn goes on" do
    id = Agent.new_id()

    boom = %Elia.Tool{
      name: "boom",
      description: "raises",
      input_schema: %{"type" => "object", "properties" => %{}},
      approval: :never,
      run: fn _input, _ctx -> raise "the tool broke" end
    }

    skills = [%Elia.Skill{name: "boom", description: "boom", tools: [boom]}]

    {:ok, pid} =
      Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM}, skills: skills])

    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    Agent.subscribe(id)

    FakeLLM.push(
      FakeLLM.assistant([
        %{type: :tool_call, id: "j1", name: "shell", input: %{}, invalid_input: "{not json"},
        FakeLLM.tool_call("u1", "no_such_tool", %{}),
        FakeLLM.tool_call("b1", "boom", %{})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Carried on.")]))
    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    [_user, _call, %Message{role: :tool, content: results}] =
      List.last(FakeLLM.requests()).messages

    assert Enum.map(results, & &1.content) == [
             Jason.encode!(%{"INVALID_JSON" => "{not json"}),
             "Unknown tool: no_such_tool",
             "Tool crashed: the tool broke"
           ]

    # The turn went on: the reply after the results is the transcript's last.
    assert Message.text_content(List.last(Agent.snapshot(id).messages)) == "Carried on."
  end

  # LOOP-26, LOOP-10, LOOP-11: a call that exits, throws or whose process dies
  # gets its own error result; the step's other calls keep theirs, in order, every
  # status ends `:done`, and the turn goes on.
  test "a call that exits, throws or dies gets its own error result" do
    id = Agent.new_id()

    tool = fn name, run ->
      %Elia.Tool{
        name: name,
        description: name,
        input_schema: %{"type" => "object", "properties" => %{}},
        approval: :never,
        run: fn _input, _ctx -> run.() end
      }
    end

    tools = [
      tool.("exits", fn -> GenServer.call(:elia_test_no_such_server, :hello) end),
      tool.("throws", fn -> throw(:nope) end),
      tool.("dies", fn ->
        spawn_link(fn -> exit(:linked_crash) end)
        receive do: (:never -> {:ok, "unreachable"})
      end),
      tool.("works", fn -> {:ok, "fine"} end)
    ]

    skills = [%Elia.Skill{name: "failing", description: "failing", tools: tools}]

    {:ok, pid} =
      Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM}, skills: skills])

    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    Agent.subscribe(id)

    ids = ["e1", "t1", "d1", "w1"]

    FakeLLM.push(
      FakeLLM.assistant(
        for {call_id, name} <- Enum.zip(ids, ~w(exits throws dies works)),
            do: FakeLLM.tool_call(call_id, name, %{})
      )
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Carried on.")]))
    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    for call_id <- ids, do: assert_received({:agent, ^id, {:tool_status, ^call_id, :done}})

    [_user, _call, %Message{role: :tool, content: results}] =
      List.last(FakeLLM.requests()).messages

    assert Enum.map(results, & &1.tool_call_id) == ids
    assert [exited, thrown, died, worked] = results

    assert exited.is_error
    assert exited.content =~ ~r/\ATool crashed: \*\* \(exit\) exited in: GenServer\.call/
    assert exited.content =~ "no process"
    assert %{is_error: true, content: "Tool crashed: ** (throw) :nope"} = thrown
    assert %{is_error: true, content: "Tool crashed: ** (exit) :linked_crash"} = died
    assert %{is_error: false, content: "fine"} = worked

    assert Message.text_content(List.last(Agent.snapshot(id).messages)) == "Carried on."
  end

  # ASK-2, ASK-3, ASK-5, ASK-6, LOOP-21
  test "a question waits for the user's answer, which the turn goes on with", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("q1", "ask_user", %{
          "question" => "Which jail?",
          "options" => ["Jailed", "Not jailed"]
        })
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Jailed, then.")]))

    :ok = Agent.send_message(id, "ask me")
    await_status(id, :awaiting_input)

    # ASK-3, SESS-34: the call and the session are both awaiting the answer, and
    # the turn is not idle while it waits.
    assert_receive {:agent, ^id, {:tool_status, "q1", :awaiting_input}}
    assert id in Agent.awaiting_input()
    assert {:error, :busy} = Agent.send_message(id, "again")

    # ASK-4, ASK-6: a blank answer, and one for a call that isn't waiting,
    # change nothing.
    assert {:error, :blank} = Agent.answer(id, "q1", "   ")
    assert {:error, :not_pending} = Agent.answer(id, "other", "Jailed")

    :ok = Agent.answer(id, "q1", "Jailed")
    assert_receive {:agent, ^id, {:tool_status, "q1", :answered}}
    await_status(id, :idle)
    refute id in Agent.awaiting_input()

    # ASK-2, ASK-5: the answer is the call's result, in the same turn.
    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert %{tool_call_id: "q1", is_error: false} = result
    assert result.content == ~s(The user answered: "Jailed")

    # The turn ended in the reply after the answer, not in a new one.
    last = List.last(Agent.snapshot(id).messages)
    assert Message.text_content(last) == "Jailed, then."
  end

  # NET-31, NET-33, NET-36: a host request waits for the user's answer like a
  # question (LOOP-21, ASK-2), and the answer that allows the host for the chat
  # reaches the tool and puts it in the entries the chat names of its own, which
  # that chat alone reaches.
  test "a host request waits, and the answer that allows it for the chat adds it", %{id: id} do
    project = Agent.snapshot(id).project
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("n1", "request_network_host", %{
          "host" => "api.example.com",
          "reason" => "curl could not reach it"
        })
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Fetched it.")]))

    # This chat is in allowlist mode, so what it is limited by is the entry the
    # answer adds (NET-36).
    :ok = Agent.set_network(id, %{mode: :allowlist})

    :ok = Agent.send_message(id, "fetch the price")
    await_status(id, :awaiting_input)

    # NET-31: the session is awaiting input, as it is for a question.
    assert_receive {:agent, ^id, {:tool_status, "n1", :awaiting_input}}
    assert id in Agent.awaiting_input()

    :ok = Agent.answer(id, "n1", "Allow for chat")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert %{tool_call_id: "n1", is_error: false} = result
    assert result.content =~ "api.example.com"
    assert result.content =~ "allowed"

    # NET-33, NET-36: the host is the chat's own now — its project's list is
    # untouched — and the chat reaches it (NET-28).
    assert Elia.Projects.allowlist(project) == []
    assert Agent.network_setting(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
    assert Agent.network(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
  end

  # NET-33, NET-28: the answer that allows the host for the project puts it in
  # the project's list, which every chat of that project reaches from then on,
  # and leaves the chat's own entries alone (NET-36).
  test "a host request answered for the project joins the project's list", %{id: id} do
    project = Agent.snapshot(id).project
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("n1", "request_network_host", %{
          "host" => "api.example.com",
          "reason" => "curl could not reach it"
        })
      ])
    )

    :ok = Agent.set_network(id, %{mode: :allowlist})
    :ok = Agent.send_message(id, "fetch the price")
    await_status(id, :awaiting_input)

    :ok = Agent.answer(id, "n1", "Allow for project")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert result.content =~ "run the command again"
    assert result.content =~ project.name

    assert Elia.Projects.allowlist(project) == ["api.example.com"]
    assert Agent.network_setting(id) == %{mode: :allowlist, hosts: []}
    assert Agent.network(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
  end

  # NET-36: the entries a chat's file names are the entries it names of its own,
  # written before the entries moved to the project or since: the chat loads them
  # as its own, reaches them beside its project's, and its project's list is
  # untouched — no entry is moved into it (NET-28).
  test "the entries a chat names of its own stay its own as it loads" do
    id = Agent.new_id()
    project = Elia.Projects.default()
    on_exit(fn -> Elia.Store.delete(id) end)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    {:ok, _project} = Elia.Projects.set_allowlist(project, ["other.example.com"])

    :ok = Elia.Store.save(id, [Message.user("hi")], network: %{mode: :allowlist})
    path = Path.join(Elia.Store.dir(), id <> ".term")

    chat =
      path
      |> File.read!()
      |> :erlang.binary_to_term()
      |> Map.put(:network, %{mode: :allowlist, hosts: ["API.example.com"]})

    File.write!(path, :erlang.term_to_binary(chat))

    {:ok, pid} = Agent.ensure_started(id, project: project)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert Elia.Projects.allowlist(project) == ["other.example.com"]
    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network == %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Agent.network(id) ==
             %{mode: :allowlist, hosts: ["api.example.com", "other.example.com"]}
  end

  # ASK-6, APPR-3, APPR-4
  test "several questions in a step are all answered before its tools run", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("q1", "ask_user", %{"question" => "First?"}),
        FakeLLM.tool_call("q2", "ask_user", %{"question" => "Second?"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Both, thanks.")]))

    :ok = Agent.send_message(id, "ask twice")
    assert_receive {:agent, ^id, {:status, :running}}
    await_status(id, :awaiting_input)
    assert_receive {:agent, ^id, {:tool_status, "q1", :awaiting_input}}
    assert_receive {:agent, ^id, {:tool_status, "q2", :awaiting_input}}

    # The session stays awaiting input until the last of them is answered.
    :ok = Agent.answer(id, "q1", "one")
    assert_receive {:agent, ^id, {:tool_status, "q1", :answered}}
    refute_receive {:agent, ^id, {:status, :running}}, 100

    :ok = Agent.answer(id, "q2", "two")
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: results}] = second.messages

    assert Enum.map(results, & &1.content) == [
             ~s(The user answered: "one"),
             ~s(The user answered: "two")
           ]
  end

  # ASK-7, SESS-34
  test "stopping the turn closes the question, and the answer is too late", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("q1", "ask_user", %{"question" => "Well?"})])
    )

    :ok = Agent.send_message(id, "ask me")
    await_status(id, :awaiting_input)

    :ok = Agent.stop(id)
    await_status(id, :idle)
    refute id in Agent.awaiting_input()

    assert {:error, :not_pending} = Agent.answer(id, "q1", "too late")

    # SESS-34, STOP-1: the open call got its result, and the stop is written
    # under it, so the transcript says why the turn ended (STOP-2).
    messages = Agent.snapshot(id).messages

    assert %Message{role: :tool, content: [%{tool_call_id: "q1", is_error: true}]} =
             Enum.at(messages, -2)

    stopped = List.last(messages)
    assert %Message{role: :user, meta: %{harness: true, stopped: :stopped}} = stopped
    assert Message.text_content(stopped) =~ "Stopped by the user."
  end

  # ASK-8, LOOP-20
  test "time spent waiting for an answer doesn't count against the budget", %{} do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, loop_opts: [budget_ms: 300])
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("q1", "ask_user", %{"question" => "Well?"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Thanks.")]))

    :ok = Agent.send_message(id, "ask me")
    await_status(id, :awaiting_input)

    # The user takes longer to answer than the whole budget allows for a turn.
    Process.sleep(400)
    :ok = Agent.answer(id, "q1", "yes")

    await_status(id, :idle)

    # The turn carried on instead of stopping at the limit: the model's second
    # request has the answer (a budget that counted the wait would have ended
    # the turn before it).
    assert [_, %{messages: messages}] = FakeLLM.requests()
    assert %Message{content: [%{content: ~s(The user answered: "yes")}]} = List.last(messages)
  end

  # ASK-12, LOOP-8
  test "a question that doesn't match the schema never reaches the user", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("q1", "ask_user", %{
          "question" => "Which?",
          "options" => ~w(a b c d e f g)
        })
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Never mind.")]))

    :ok = Agent.send_message(id, "ask")
    assert_receive {:agent, ^id, {:status, :running}}, 1000
    refute_receive {:agent, ^id, {:status, :awaiting_input}}, 200
    await_status(id, :idle)

    [_, second] = FakeLLM.requests()
    [_user, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert result.is_error
    assert result.content =~ "options must have at most 6 items"
  end

  # LIMIT-9, LIMIT-10, SESS-37, STOP-1, STOP-2
  test "a chat that sets no limits pauses at the loop's default 300 steps, and says so", %{} do
    id = start_fake_skill_session([])
    push_step_tool_calls(300)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 60_000
    assert_receive {:agent, ^id, {:paused, "Step limit reached (300 steps)."}}, 10_000
    assert id in Agent.paused()

    # LIMIT-10, SESS-37: the pause is in the transcript as a harness message,
    # marked with the limit it names and saved — so it is still there however
    # long the chat is left waiting.
    last = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, limit: {:steps, 300}}} = last

    # UI-9: it reads as a harness message, with the pause's own wording.
    assert Message.text_content(last) =~
             "Step limit reached (300 steps). The turn is paused: Continue starts " <>
               "the count over, Fail ends it."

    # STOP-1, STOP-2: failing the pause ends the turn, and that is written too,
    # under the pause's own message — with the same text the event carries
    # (STOP-4).
    :ok = Agent.fail_task(id)
    assert_receive {:agent, ^id, {:error, "Stopped after 300 steps without finishing"}}, 10_000
    await_status(id, :idle)

    stopped = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, stopped: :limit}} = stopped
    assert Message.text_content(stopped) =~ "Stopped after 300 steps without finishing"
  end

  # LOOP-16, LIMIT-9, STOP-1, STOP-2
  test "the max_steps option sets the turn's step limit, and turning pausing off keeps the ending",
       %{} do
    id = start_fake_skill_session(max_steps: 3, pause_on_limit: false)
    push_step_tool_calls(4)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:error, "Stopped after 3 steps without finishing"}}, 10_000
    await_status(id, :idle)

    # STOP-1, STOP-2: the ending is written — marked `:limit`, and saved with
    # the chat, so it is still there when the chat is opened again.
    stopped = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, stopped: :limit}} = stopped
    assert Message.text_content(stopped) =~ "Stopped after 3 steps without finishing"
  end

  # LOOP-19, SESS-27
  test "pause_on_limit pauses at the step limit, and a resume starts the count over", %{} do
    id = start_fake_skill_session(max_steps: 2, pause_on_limit: true)
    push_step_tool_calls(2)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 10_000
    assert_receive {:agent, ^id, {:paused, "Step limit reached (2 steps)."}}, 10_000
    assert Agent.snapshot(id).pause == "Step limit reached (2 steps)."
    assert id in Agent.paused()

    # A chat that isn't paused refuses both decisions.
    other = start_fake_skill_session([])
    assert {:error, :not_paused} = Agent.resume(other)
    assert {:error, :not_paused} = Agent.fail_task(other)

    # Continue: the step count starts over, so the next step runs (it would
    # pause again straight away if the count had not been reset).
    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))
    :ok = Agent.resume(id)

    await_status(id, :idle)
    refute id in Agent.paused()
    assert Agent.snapshot(id).pause == nil
  end

  # LIMIT-10: a resumed turn that reaches the limit again writes another
  # message, so the transcript tells the whole story.
  test "each pause writes its own message", %{} do
    id = start_fake_skill_session(max_steps: 1, pause_on_limit: true)
    push_step_tool_calls(1)

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:status, :paused}}, 10_000

    # Continue: the count starts over, so the next step runs and the one after
    # it pauses again.
    push_step_tool_calls(1)
    :ok = Agent.resume(id)
    assert_receive {:agent, ^id, {:status, :paused}}, 10_000

    notices = Enum.filter(Elia.Store.load(id), &Map.get(&1.meta, :limit))
    assert length(notices) == 2

    :ok = Agent.fail_task(id)
    await_status(id, :idle)
  end

  # LOOP-19, SESS-27, STOP-1, STOP-2
  test "failing a paused turn ends it with the limit's error", %{} do
    id = start_fake_skill_session(max_steps: 1, pause_on_limit: true)
    push_step_tool_calls(1)

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:status, :paused}}, 10_000

    :ok = Agent.fail_task(id)

    assert_receive {:agent, ^id, {:error, "Stopped after 1 steps without finishing"}}, 10_000
    await_status(id, :idle)

    # LIMIT-10, STOP-2: the transcript holds both — that the turn waited (the
    # pause's own message) and that it was ended at the limit.
    messages = Elia.Store.load(id)
    assert %Message{role: :user, meta: %{limit: {:steps, 1}}} = Enum.at(messages, -2)

    stopped = List.last(messages)
    assert %Message{role: :user, meta: %{harness: true, stopped: :limit}} = stopped
    assert Message.text_content(stopped) =~ "Stopped after 1 steps without finishing"
  end

  # LOOP-24: the loop recognises a call it has made already in this turn — same
  # tool, same input. When that call's result comes back byte-identical, the
  # result the model is sent carries the loop's own notice: how many times the
  # identical call has now returned the identical result, and that nothing has
  # changed since. A call that changed its input is not a repeated call.
  test "a repeated call's identical result carries the loop's notice", %{} do
    id = start_fake_skill_session([])
    push_fake_calls([%{"n" => 1}, %{"n" => 1}, %{"n" => 2}])
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    requests = FakeLLM.requests()
    # The first time the turn makes the call, its result is the tool's own.
    assert tool_result(Enum.at(requests, 1)) == "ok"

    # The identical call after it says how often it has now returned it, and
    # that the result hasn't changed since — the notice is the loop's, appended
    # to the tool's own output, which is still there.
    second = tool_result(Enum.at(requests, 2))
    assert String.starts_with?(second, "ok")

    assert second =~
             "The identical call to fake_tool has now returned the identical result 2 times"

    assert second =~ "nothing has changed since"

    # A call that changed its input is not the same call, so it carries nothing.
    assert tool_result(Enum.at(requests, 3)) == "ok"
  end

  # LOOP-25, LIMIT-10, LIMIT-13, SESS-27: four byte-identical results from a
  # repeated call mean the turn stands still. The step that made it four
  # finished, and the turn is then at a limit like the others: it pauses for the
  # user, the pause is written into the transcript, and a resume starts the
  # count over.
  test "four identical results pause the turn, and a resume starts the count over", %{} do
    id = start_fake_skill_session(pause_on_limit: true)
    push_repeating_tool_call(4)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 10_000

    assert_receive {:agent, ^id,
                    {:paused, "Standing still: fake_tool returned the same result 4 times."}},
                   10_000

    assert Agent.snapshot(id).pause ==
             "Standing still: fake_tool returned the same result 4 times."

    assert id in Agent.paused()

    # LIMIT-10, LIMIT-13: the pause is in the transcript as a harness message,
    # marked with the limit it names, worded as the other limits are (LIMIT-9).
    last = List.last(Elia.Store.load(id))

    assert %Message{
             role: :user,
             meta: %{harness: true, limit: {:repetition, "fake_tool", 4}}
           } = last

    assert Message.text_content(last) =~
             "Standing still: fake_tool returned the same result 4 times. The turn is " <>
               "paused: Continue starts the count over, Fail ends it."

    # Continue: the count starts over, so the next identical call is the first
    # of a new count and the turn carries on to its end. A count that carried
    # over would have paused it again at once instead.
    push_repeating_tool_call(1)
    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))
    :ok = Agent.resume(id)

    await_status(id, :idle)
    refute id in Agent.paused()

    # The resumed turn's result is the first of a new count: no notice on it.
    assert tool_result(Enum.at(FakeLLM.requests(), 5)) == "ok"
  end

  # LOOP-25, LIMIT-13, STOP-1, STOP-2: with pausing off, the same limit ends the
  # turn instead of pausing it, and that ending is written too.
  test "without pause_on_limit, standing still ends the turn", %{} do
    id = start_fake_skill_session(pause_on_limit: false)
    push_repeating_tool_call(4)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id,
                    {:error, "Stopped standing still: fake_tool returned the same result 4 times"}},
                   10_000

    await_status(id, :idle)
    refute id in Agent.paused()

    stopped = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, stopped: :limit}} = stopped

    assert Message.text_content(stopped) =~
             "Stopped standing still: fake_tool returned the same result 4 times"
  end

  # LOOP-20, SESS-27
  test "the budget_ms option pauses the turn when its time runs out", %{} do
    id = start_fake_skill_session(max_steps: 100, pause_on_limit: true, budget_ms: 150)

    # Each step takes longer than the whole budget, so the second one pauses.
    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(250)
      message = FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", %{})])
      {:ok, %{message: message, stop_reason: :tool_use, model: "fake", usage: %{}}}
    end)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 10_000
    assert_receive {:agent, ^id, {:paused, "Time limit reached" <> _}}, 10_000

    # SESS-37, LIMIT-10: the budget's own wording, and the clock started over.
    last = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{limit: {:time, _}}} = last

    assert Message.text_content(last) =~
             "The turn is paused: Continue starts the clock over, Fail ends it."

    # Continue: the budget starts over, so a fast step finishes the turn.
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    :ok = Agent.resume(id)

    await_status(id, :idle)
  end

  # LOOP-22, LIMIT-12, SESS-27
  test "the token_budget option pauses the turn when the turn's tokens run out", %{} do
    id = start_fake_skill_session(max_steps: 100, pause_on_limit: true, token_budget: 1100)

    # Every step reports 300 input, 100 of it prompt-cache reads, and 200
    # output: 600 tokens a step, so the turn is over 1100 after two of them —
    # and the model's next step is never sent.
    push_token_step(300, 100, 200, 2)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 10_000
    assert_receive {:agent, ^id, {:paused, "Token limit reached (1100 tokens)."}}, 10_000

    # LIMIT-12: prompt-cache reads count as input (CTX-6), so each step cost 600
    # and the two steps it took to pass 1100 are the ones the model saw.
    assert length(FakeLLM.requests()) == 2

    # LIMIT-10: the pause is in the transcript, marked with the limit it names,
    # with the token budget's own wording.
    last = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, limit: {:tokens, 1100}}} = last

    assert Message.text_content(last) =~
             "Token limit reached (1100 tokens). The turn is paused: Continue " <>
               "starts the count over, Fail ends it."

    # Continue: the count starts over, so a step that reports nothing finishes.
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    :ok = Agent.resume(id)

    await_status(id, :idle)
    refute id in Agent.paused()
  end

  # LIMIT-1, LIMIT-2, LIMIT-3, LIMIT-12, SESS-31, STOP-1, STOP-2
  test "a chat's own token budget is what its turn runs with, and failing the pause ends it",
       %{} do
    id = start_fake_skill_session([])
    push_token_step(300, 100, 200, 2)

    # A change applies from the next turn (LIMIT-3).
    :ok = Agent.set_limits(id, %{max_tokens: 600})
    assert Agent.snapshot(id).settings.limits.max_tokens == 600

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:status, :paused}}, 10_000
    assert_receive {:agent, ^id, {:paused, "Token limit reached (600 tokens)."}}, 10_000

    :ok = Agent.fail_task(id)

    # STOP-1, STOP-2: the turn ended at the limit, which is written under the
    # pause's own message, with the token budget's wording.
    assert_receive {:agent, ^id, {:error, "Stopped after 600 tokens: the token budget ran out"}},
                   10_000

    await_status(id, :idle)

    messages = Elia.Store.load(id)
    assert %Message{role: :user, meta: %{limit: {:tokens, 600}}} = Enum.at(messages, -2)

    stopped = List.last(messages)
    assert %Message{role: :user, meta: %{harness: true, stopped: :limit}} = stopped
    assert Message.text_content(stopped) =~ "Stopped after 600 tokens: the token budget ran out"
  end

  # RETRY-1, RETRY-2, RETRY-3, SESS-39
  test "a model call that fails transiently is retried, and the turn carries on", %{} do
    id = start_fake_skill_session(step_retry: [delays_ms: [0, 0]])

    # The first attempt streams half an answer, then the stream times out.
    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "Half an ans"})
      {:error, Elia.LLM.Error.transient("Anthropic API request failed: timeout")}
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("A whole answer.")]))

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:delta, :text, "Half an ans"}}, 5000

    # RETRY-3: the retry is reported, with what failed and how long the wait is.
    assert_receive {:agent, ^id, {:retry, info}}, 5000

    assert %{attempt: 2, of: 3, delay_ms: 0, reason: "Anthropic API request failed: timeout"} =
             info

    assert info.text ==
             "Anthropic API request failed: timeout. Retrying at once (attempt 2 of 3)."

    await_status(id, :idle)

    # RETRY-2: the failed attempt left nothing behind — the history holds the
    # question and the answer that replaced it, never the half answer — and the
    # retry was sent the same request as the attempt it replaced.
    assert [%Message{role: :user}, %Message{role: :assistant} = reply] =
             Agent.snapshot(id).messages

    assert Message.text_content(reply) == "A whole answer."
    assert [first, second] = FakeLLM.requests()
    assert first.messages == second.messages
  end

  # RETRY-4, RETRY-5, STOP-1, STOP-2, LOOP-23
  test "a failure that outlasts the schedule ends the turn, saying it was retried", %{} do
    id = start_fake_skill_session(step_retry: [delays_ms: [0, 0]])
    for _ <- 1..3, do: FakeLLM.push(transient_failure())

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:retry, %{attempt: 2, of: 3}}}, 5000
    assert_receive {:agent, ^id, {:retry, %{attempt: 3, of: 3}}}, 5000

    assert_receive {:agent, ^id, {:error, text}}, 5000
    assert text == "Anthropic API request failed: timeout (retried 2 times)"
    await_status(id, :idle)

    # The stop is in the transcript, marked as a stop, and says what was done.
    assert %Message{role: :user, meta: %{harness: true, stopped: :error}} =
             stopped =
             List.last(Elia.Store.load(id))

    assert Message.text_content(stopped) =~ "(retried 2 times)"
    assert length(FakeLLM.requests()) == 3
  end

  # RETRY-1, RETRY-6
  test "a failure a retry cannot fix ends the turn at once", %{} do
    id = start_fake_skill_session(step_retry: [delays_ms: [0, 0]])

    FakeLLM.push(fn _request, _on_event ->
      {:error, Elia.LLM.Error.permanent("Anthropic API error 401: invalid x-api-key")}
    end)

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:error, "Anthropic API error 401: invalid x-api-key"}}, 5000
    refute_received {:agent, ^id, {:retry, _}}
    await_status(id, :idle)
    assert length(FakeLLM.requests()) == 1
  end

  # RETRY-4
  test "with no schedule a transient failure ends the turn as before", %{} do
    id = start_fake_skill_session(step_retry: [delays_ms: []])
    FakeLLM.push(transient_failure())

    :ok = Agent.send_message(id, "go")

    assert_receive {:agent, ^id, {:error, "Anthropic API request failed: timeout"}}, 5000
    refute_received {:agent, ^id, {:retry, _}}
    await_status(id, :idle)
    assert length(FakeLLM.requests()) == 1
  end

  # RETRY-2, LOOP-3
  test "a retry is the same step, not another one", %{} do
    # Two steps allowed: the first fails once and is retried, and the tool call
    # its retried answer asks for runs; the second step finishes the turn. A
    # retry counted as a step would end it at the limit instead.
    id = start_fake_skill_session(max_steps: 2, step_retry: [delays_ms: [0]])

    FakeLLM.push(transient_failure())
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", %{})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")

    await_status(id, :idle)

    messages = Elia.Store.load(id)
    refute Enum.any?(messages, & &1.meta[:stopped])
    assert Enum.any?(messages, &(&1.role == :tool))
    assert length(FakeLLM.requests()) == 3
  end

  # RETRY-4, LOOP-20
  test "the wait before a retry doesn't count against the turn's time budget", %{} do
    # The wait is longer than the whole budget: if it counted, the next step
    # would pause the turn at the budget instead of finishing it.
    id =
      start_fake_skill_session(
        budget_ms: 500,
        pause_on_limit: true,
        step_retry: [delays_ms: [700]]
      )

    FakeLLM.push(transient_failure())
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", %{})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")

    await_status(id, :idle)
    refute_received {:agent, ^id, {:paused, _}}
  end

  # RETRY-1: a model call that fails in a way a retry may fix (RETRY-6).
  defp transient_failure do
    fn _request, _on_event ->
      {:error, Elia.LLM.Error.transient("Anthropic API request failed: timeout")}
    end
  end

  # Starts a session whose only skill is `fake_skill/1`, plus the given loop
  # options, subscribed like the setup's (LOOP-3, LOOP-16). LOOP-17: the `skills`
  # option takes a function of no arguments, which the loop calls every step.
  defp start_fake_skill_session(loop_opts) do
    id = Agent.new_id()
    opts = Keyword.put(loop_opts, :skills, fn -> fake_skill("ok") end)
    {:ok, pid} = Agent.ensure_started(id, loop_opts: opts)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    id
  end

  # LOOP-24: scripts the model to ask for the fake skill's tool once per step,
  # with the given input each time.
  defp push_fake_calls(inputs) do
    for input <- inputs do
      FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", input)]))
    end
  end

  # Scripts the model to ask for the fake skill's tool `times` times, a
  # different call each step — never the same call with the same input twice, so
  # no repetition (LOOP-24) and only the step limit ends the turn.
  defp push_step_tool_calls(times) do
    push_fake_calls(for step <- 1..times, do: %{"step" => step})
  end

  # Scripts the model to ask for the fake skill's tool `times` times with the
  # same input every step, so every result is identical to the one before it
  # (LOOP-24, LOOP-25).
  defp push_repeating_tool_call(times) do
    push_fake_calls(for _ <- 1..times, do: %{})
  end

  # LOOP-10: the tool result of the step the request's history carries last —
  # one result, since these tests' calls each make one.
  defp tool_result(request) do
    %Message{role: :tool, content: [result]} = List.last(request.messages)
    result.content
  end

  # LOOP-22, LIMIT-12: scripts the model to ask for the fake skill's tool `times`
  # times, each request reporting what it cost: `input` tokens in, `cached` of
  # them prompt-cache reads, and `output` tokens back.
  defp push_token_step(input, cached, output, times) do
    fun = fn _request, _on_event ->
      message = FakeLLM.assistant([FakeLLM.tool_call("c", "fake_tool", %{})])

      usage = %{
        "input_tokens" => input,
        "cache_read_input_tokens" => cached,
        "output_tokens" => output
      }

      {:ok, %{message: message, stop_reason: :tool_use, model: "fake", usage: usage}}
    end

    for _ <- 1..times, do: FakeLLM.push(fun)
  end

  # SESS-38: the user's stop goes through the same path as the loop's error, its
  # refusal and its death — the marked harness message STOP-2 describes.
  test "stopping while awaiting approval closes the dangling call", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "sleep 5"})]))

    :ok = Agent.send_message(id, "wait")
    await_status(id, :awaiting_approval)
    :ok = Agent.stop(id)

    %{status: :idle, messages: messages} = Agent.snapshot(id)

    # SESS-8, STOP-1: the dangling call is closed and the stop follows it.
    assert %Message{role: :tool, content: [%{tool_call_id: "c1", is_error: true}]} =
             Enum.at(messages, -2)

    assert %Message{role: :user, meta: %{stopped: :stopped}} = List.last(messages)
  end

  # SESS-43, SHELL-12: stopping a turn ends the commands its tool calls are
  # running — the shell and the child it left in its group — rather than leaving
  # them to run out their timeout behind an idle chat.
  test "stopping a turn kills the OS commands its shell calls are running", %{id: id} do
    # A sleep length no other run uses, so a process an earlier run leaked is
    # never counted; that run's leftovers go first, and this run's own on every
    # exit path.
    System.cmd("pkill", ["-KILL", "-f", "^sleep 3173"])
    marker = "3173.#{System.unique_integer([:positive])}"
    command = "sleep #{marker} & sleep #{marker}; wait"
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-x", "-f", "sleep #{marker}"]) end)

    call = FakeLLM.tool_call("c1", "shell", %{"command" => command, "timeout_seconds" => 600})
    FakeLLM.push(FakeLLM.assistant([call]))

    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "c1")
    assert eventually(fn -> sleeping(marker) == 2 end)

    :ok = Agent.stop(id)
    assert %{status: :idle} = Agent.snapshot(id)
    assert eventually(fn -> sleeping(marker) == 0 end)
  end

  # SESS-44: the save interval for this test, put back afterwards.
  defp save_interval(ms) do
    previous = Application.get_env(:elia, Elia.Agent.Session)
    Application.put_env(:elia, Elia.Agent.Session, save_interval_ms: ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, Elia.Agent.Session, previous),
        else: Application.delete_env(:elia, Elia.Agent.Session)
    end)
  end

  # SESS-44: a step that calls the fake tool, then a model call that waits for
  # `:go` — so the loop's two messages (the call and its result) are appended
  # and the turn is still running. Answers `{:model_waiting, loop}`.
  defp push_held_step(test_pid) do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "fake_tool", %{})]))

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:model_waiting, self()})
      receive do: (:go -> :ok)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Done.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)
  end

  defp saved_count(id), do: length(Elia.Store.load(id))

  # SESS-46: storage that fails for one chat — the path its file belongs at is a
  # directory, so the rename the write ends in cannot happen, whatever user the
  # suite runs as. `File.rmdir!/1` puts storage back.
  defp break_storage(id) do
    path = Path.join(Elia.Store.dir(), id <> ".term")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # SESS-44, SESS-5: the loop's messages wait for the interval and go in one
  # save, while the message that started the turn was saved at once.
  test "a running turn's messages are saved together at the end of the interval" do
    save_interval(3_000)
    id = start_fake_skill_session([])
    push_held_step(self())

    :ok = Agent.send_message(id, "go")
    assert_receive {:model_waiting, loop}, 10_000

    # The call and its result are in the history and were broadcast…
    assert [_user, _call, _result] = Agent.snapshot(id).messages
    # …but only the turn's own message is on disk yet.
    assert saved_count(id) == 1

    # One save at the end of the interval writes both.
    assert eventually(fn -> saved_count(id) == 3 end)

    send(loop, :go)
    await_status(id, :idle)
    assert saved_count(id) == 4
  end

  # SESS-44: the end of a turn saves at once, with whatever the interval held.
  test "the end of a turn saves at once, interval or not" do
    save_interval(60_000)
    id = start_fake_skill_session([])
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "fake_tool", %{})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    assert saved_count(id) == 4
    assert Elia.Store.load_turn(id) == nil
  end

  # SESS-44, SESS-21: a session that is shut down saves what the interval had
  # not — the turn's record included, so the next start sees a turn cut short.
  test "a session that is shut down first saves its unsaved messages" do
    save_interval(60_000)
    id = start_fake_skill_session([])
    push_held_step(self())

    :ok = Agent.send_message(id, "go")
    assert_receive {:model_waiting, _loop}, 10_000
    assert saved_count(id) == 1

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    # SESS-45: the loop ends with its session, so this test needs no cleanup of
    # its own for the held one.
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    assert saved_count(id) == 3
    assert %{id: _} = Elia.Store.load_turn(id)
  end

  # SESS-44, SESS-46, SESS-13: every save the turn made failed, and nothing
  # changes the chat afterwards — so the shutdown save is the one that writes
  # it, which is the save the failed one used to take with it.
  test "a failed save leaves the chat unsaved for the shutdown save" do
    save_interval(60_000)
    id = start_fake_skill_session([])
    push_held_step(self())
    # Storage fails for this chat from its first save on.
    path = break_storage(id)

    :ok = Agent.send_message(id, "go")
    assert_receive {:model_waiting, loop}, 10_000

    # SESS-13: the message that starts the turn, the call the step made and its
    # result, and the turn's own record (INTR-1), are all in the session's
    # history and none of them is on disk.
    assert [_user, _call, _result] = Agent.snapshot(id).messages
    assert saved_count(id) == 0

    send(loop, :go)
    await_status(id, :idle)

    # The turn ended — its record cleared in the session (INTR-1) — and the save
    # that would have written that failed, so the chat is still unsaved.
    assert %{status: :idle} = Agent.snapshot(id)
    assert saved_count(id) == 0

    # Storage recovers, and the session is shut down with no message, setting or
    # title in between: the retry a live session would make (SESS-46) is 60 s
    # away, so the shutdown save is the only chance the chat gets.
    File.rmdir!(path)
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    assert saved_count(id) == 4
    assert Elia.Store.load_turn(id) == nil
  end

  # SESS-46: a failed save is tried again while the session lives, one interval
  # after it failed, whether or not the chat changes in between — so storage
  # that recovers gets the write at the next attempt.
  test "a failed save is retried at the next interval" do
    save_interval(100)
    id = start_fake_skill_session([])
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "fake_tool", %{})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    path = break_storage(id)

    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)
    # Every save the turn made failed, the turn's own end included.
    assert saved_count(id) == 0

    File.rmdir!(path)

    assert eventually(fn -> saved_count(id) == 4 end)
    assert Elia.Store.load_turn(id) == nil
  end

  # SESS-13: a save that fails is logged and does not stop the session — the
  # turn ends as it would have, with the file the only thing that is behind.
  test "a failed save is logged and the session carries on", %{id: id} do
    save_interval(200)
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello.")]))
    path = break_storage(id)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = Agent.send_message(id, "hi")
        await_status(id, :idle)
      end)

    assert log =~ "Could not save session #{id}"
    assert %{status: :idle, messages: [_, _]} = Agent.snapshot(id)

    # Storage recovers while the session is alive, so the chat is written
    # without anything else happening to it.
    File.rmdir!(path)
    assert eventually(fn -> saved_count(id) == 2 end)
  end

  # SESS-45: a session its supervisor terminates — no stop of any kind, and
  # nothing of the test's own — ends the loop of the turn it was running with it
  # (SESS-8 is the same in the other direction: the stop kills the loop).
  test "terminating a session ends its loop" do
    id = start_fake_skill_session([])
    push_held_step(self())

    :ok = Agent.send_message(id, "go")
    assert_receive {:model_waiting, loop}, 10_000

    ref = Process.monitor(loop)
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    assert_receive {:DOWN, ^ref, :process, ^loop, _reason}, 5_000
  end

  # SESS-45: a loop waiting on a decision is ended too, rather than held for a
  # chat that no longer has a session — and a killed session runs nothing of its
  # own, so only the loop's own monitoring of it can end it.
  test "a session killed while its loop awaits approval ends the loop", %{id: id} do
    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo elia"})])
    )

    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    loop = :sys.get_state(pid).task.pid
    ref = Process.monitor(loop)
    Process.exit(pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^loop, _reason}, 5_000
  end

  # SESS-45, SHELL-12: a session killed outright still ends the turn, so the
  # command its shell call is running goes with it instead of working on for a
  # chat no session runs (SESS-43 is the same for the stop).
  test "a session killed while a command runs ends the command with it", %{id: id} do
    # A sleep length no other run uses, as the stop's test does.
    System.cmd("pkill", ["-KILL", "-f", "^sleep 3175"])
    marker = "3175.#{System.unique_integer([:positive])}"
    command = "sleep #{marker} & sleep #{marker}; wait"
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-x", "-f", "sleep #{marker}"]) end)

    call = FakeLLM.tool_call("c1", "shell", %{"command" => command, "timeout_seconds" => 600})
    FakeLLM.push(FakeLLM.assistant([call]))

    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "c1")
    assert eventually(fn -> sleeping(marker) == 2 end)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    Process.exit(pid, :kill)

    assert eventually(fn -> sleeping(marker) == 0 end)
  end

  # SESS-44, `## Stored data`: the saved shape is unchanged, so a chat written
  # before this change loads in a session as it always did.
  test "a chat saved by an older version still loads" do
    id = Agent.new_id()
    File.mkdir_p!(Elia.Store.dir())
    path = Path.join(Elia.Store.dir(), id <> ".term")

    old = %{
      version: 1,
      messages: [Message.user("from before"), FakeLLM.assistant([Message.text("hi")])]
    }

    File.write!(path, :erlang.term_to_binary(old))
    on_exit(fn -> Elia.Store.delete(id) end)

    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert [%Message{role: :user} = user, %Message{role: :assistant}] =
             Agent.snapshot(id).messages

    assert Message.text_content(user) == "from before"
  end

  # How many processes run `sleep <marker>`.
  defp sleeping(marker) do
    {count, _} = System.cmd("pgrep", ["-c", "-x", "-f", "sleep #{marker}"])
    count |> String.trim() |> String.to_integer()
  end

  # Whether `check` holds within 30 s, asked every 20 ms: an OS process ending
  # sends this test no event to wait on, and a loaded node can be slow to start
  # or reap one.
  defp eventually(check) do
    deadline = System.monotonic_time(:millisecond) + 30_000

    Stream.repeatedly(fn ->
      receive do
      after
        20 -> check.()
      end
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end

  # SESS-2: a session loads its saved history on start, so a restart shows the
  # same conversation.
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

  # LOOP-1: skills and the project's instructions are read again every step, so a
  # skill reloaded mid-turn applies from the next one.
  test "writing a skill and reloading makes its tool available in the same turn", %{id: id} do
    skill_md = "---\nname: greeter\ndescription: Greets people\n---\nUse greet to say hello."

    tools_json =
      ~s([{"name": "greet", "description": "Say hi", "command": "echo hi $ELIA_ARG_NAME",
      "input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}])

    # SHELL-15: one command writes both files — the calls of a step run at the
    # same time (LOOP-10), so two of them could not depend on each other.
    command =
      "mkdir -p skills/greeter && cat > skills/greeter/SKILL.md <<'EOF'\n" <>
        skill_md <>
        "\nEOF\ncat > skills/greeter/tools.json <<'EOF'\n" <> tools_json <> "\nEOF"

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("w1", "shell", %{"command" => command})]))

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("r1", "reload_skills", %{})]))

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("g1", "greet", %{"name" => "Ada; rm -rf /"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    # APPR-8: the extension's own shell commands are approved for this chat; the
    # new script tool still asks.
    :ok = Agent.set_auto_approve(id, "shell", true)

    :ok = Agent.send_message(id, "make a greeter skill")
    # Writing the skill and reloading it need no approval; the new script tool
    # does.
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

  # CTX-6, STOP-5: a refused request's usage is cleared with it — and only a stop
  # is written for it, so the rollback stays the reset it is.
  test "a refusal clears the usage and the turn's messages", %{id: id} do
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

    # SESS-10, STOP-2: the rollback is what the refusal needs; the stop is what
    # the transcript keeps of it, written after the rollback so it is the last
    # thing there rather than the request the model declined.
    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :user, meta: %{harness: true, stopped: :refused}} = stopped
           ] = Agent.snapshot(id).messages

    assert Message.text_content(stopped) =~ "The model declined this request."
    assert Agent.snapshot(id).last_usage == nil
  end

  # STOP-1, STOP-2, STOP-4, SESS-11, LOOP-23
  test "a provider that failed is written into the transcript as the stop it is", %{} do
    id = start_fake_skill_session([])

    # Nothing scripted: the provider call fails, so the loop returns an error
    # (LOOP-5, LLM-13) instead of a reply.
    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    # STOP-4: the event a watcher reads carries the message's own text.
    assert_receive {:agent, ^id, {:error, "FakeLLM: no scripted turn"}}, 5000

    # STOP-1, STOP-2: the loop's reason, marked as the error kind, saved with
    # the chat.
    stopped = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, stopped: :error}} = stopped
    assert Message.text_content(stopped) =~ "FakeLLM: no scripted turn"
  end

  # STOP-1, STOP-2, STOP-3
  test "a loop that dies is written into the transcript, and the next turn reads it", %{id: id} do
    # The loop dying is logged by the task supervisor (hence the capture), and
    # it is the crash the stop reports.
    ExUnit.CaptureLog.capture_log(fn ->
      FakeLLM.push(fn _request, _on_event -> raise "boom" end)

      :ok = Agent.send_message(id, "go")
      await_status(id, :idle)
    end)

    # STOP-2: the reason the loop died with, on one line, not a stacktrace.
    stopped = List.last(Elia.Store.load(id))
    assert %Message{role: :user, meta: %{harness: true, stopped: :crash}} = stopped
    assert Message.text_content(stopped) =~ "The harness crashed:"
    assert Message.text_content(stopped) =~ "boom"
    refute Message.text_content(stopped) =~ "stacktrace"

    # STOP-3: the message is part of the history, so the next turn sends it to
    # the model instead of a history that stops mid-turn.
    FakeLLM.push(FakeLLM.assistant([Message.text("I know.")]))
    :ok = Agent.send_message(id, "carry on")
    await_status(id, :idle)

    request = List.last(FakeLLM.requests())
    assert Enum.any?(request.messages, &(&1.meta[:stopped] == :crash))
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
    Elia.LLMCase.stub_catalog(Elia.LLM.OpenRouter)
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
    Elia.LLMCase.stub_catalog(Elia.LLM.OpenRouter)
    on_exit(fn -> Elia.Store.delete(id) end)

    # Selecting in an empty chat is broadcast but not written to disk.
    {:ok, _} = Agent.select_model(id, "openrouter", "vendor/chat-model", "Chat Model")
    assert_receive {:agent, ^id, {:settings, %{model: %{model: "vendor/chat-model"}}}}
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
    assert %{model: "vendor/chat-model"} = Agent.snapshot(id).settings.model
  end

  # MODEL-16
  test "a chat without a selection pins the default when its first turn starts", %{id: id} do
    Elia.LLMCase.reset_settings()
    Elia.LLMCase.configure(Elia.LLM.OpenRouter, api_key: "or-key")
    on_exit(fn -> Elia.Store.delete(id) end)
    Elia.LLMCase.stub_catalog(Elia.LLM.OpenRouter)
    {:ok, _} = Elia.LLM.select("openrouter", "vendor/first")
    assert Agent.snapshot(id).settings.model == nil

    Elia.LLMCase.stub_openrouter_stream(self(), [
      %{"choices" => [%{"delta" => %{"content" => "Hi."}}]},
      %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}
    ])

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    assert %{model: "vendor/first"} = Agent.snapshot(id).settings.model

    {:ok, _} = Elia.LLM.select("openrouter", "vendor/second")
    assert %{model: "vendor/first"} = Agent.snapshot(id).settings.model
  end

  # SESS-15, SESS-41
  test "a session with state from before the one settings map existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :settings))

    assert %{settings: %{model: nil, jail: true, effort: nil}, messages: []} = Agent.snapshot(id)
  end

  # SESS-47, NET-1: a session that outlived the hot reload which added the
  # network setting reads it at its default rather than crashing on it — the
  # key a page opening the chat asked for (SESS-7).
  test "a session whose settings map predates a key reads it as its default", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)

    # The map such a session holds: SESS-41's five keys, its own jail setting
    # among them, and no network setting at all.
    :sys.replace_state(pid, fn state ->
      %{state | settings: Map.put(Map.delete(state.settings, :network), :jail, false)}
    end)

    assert %{settings: %{network: network, jail: false}} = Agent.snapshot(id)
    assert network == Elia.Net.default()
  end

  # SESS-15, INTR-1
  test "a session with state from before :turn existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :turn))

    # The record belongs to the process that runs the turn, so nothing is loaded
    # from the chat for it — and a turn still runs (INTR-1).
    assert %{status: :idle} = Agent.snapshot(id)
    assert Elia.Store.load_turn(id) == nil

    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    assert [%Message{role: :user}, %Message{role: :assistant}] = Agent.snapshot(id).messages
    # The turn was recorded and cleared as usual.
    assert Elia.Store.load_turn(id) == nil
  end

  # SESS-15, SESS-17
  test "a session with state from before :task_meta existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :task_meta))

    assert %{messages: []} = Agent.snapshot(id)
    # SESS-18: the session saves the task map it was started with and the result
    # once; there is no API to merge anything into it.
    refute function_exported?(Agent, :update_task, 2)
  end

  # SESS-17, SESS-18
  test "task metadata is saved with the chat, and is what the session was started with" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    task = %{parent_id: "p", started_at: ~U[2026-01-02 03:04:05Z]}
    selection = %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}
    default = Elia.Settings.get(:model)

    {:ok, _pid} =
      Agent.ensure_started(id,
        task: task,
        selection: selection,
        auto_approve: ["shell"],
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
    # SESS-17: the option sets the chat's auto-approved tools, then it saves them.
    assert %{settings: %{auto_approve: ["shell"]}} = Agent.snapshot(id)
    assert Elia.Store.load_auto_approve(id) == ["shell"]

    # SESS-18: the chat's task map is the one its session was started with, and
    # the session saves it as it is — no merge API and no `{:task, …}` event.
    assert %{task: ^task} = Agent.snapshot(id)
    refute_receive {:agent, ^id, {:task, _}}, 50
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

  # INTR-1, STORE-30, STORE-31
  test "a turn in flight is recorded in the saved chat, and cleared when it ends", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    # The turn waits for approval, so it is still in flight.
    await_status(id, :awaiting_approval)

    # The chat carries the turn: its id names the chat and it says when it began.
    assert %{id: turn_id, started_at: %DateTime{}} = Elia.Store.load_turn(id)
    assert turn_id =~ id
    # STORE-31, INTR-2: a session runs for it, so the list doesn't call it
    # interrupted.
    assert %{interrupted: false} = listed(id)

    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)

    # INTR-1: the record goes with the turn.
    assert Elia.Store.load_turn(id) == nil
    assert %{interrupted: false} = listed(id)
  end

  # SESS-32
  test "live?/1 reads the registry without starting a session", %{id: id} do
    assert Agent.live?(id)
    refute Agent.live?(Agent.new_id())
    refute Agent.live?("not a chat id")
    refute Agent.live?(nil)
  end

  # INTR-2, INTR-3, STORE-31, UI-72, UI-73
  test "a session starting after a restart reports the interrupted turn" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # The app stopped mid-turn: the chat still carries the turn it was running.
    turn = %{id: "turn-1", started_at: DateTime.utc_now()}
    :ok = Elia.Store.save(id, [Message.user("run it")], turn: turn)

    # STORE-31, INTR-2: the chat list says so before the chat is opened.
    assert %{interrupted: true} = listed(id)

    Agent.subscribe(id)
    Agent.subscribe_activity()
    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    # INTR-3, UI-73: the notice is a harness message marked as the interruption.
    assert_receive {:agent, ^id,
                    {:message, %Message{meta: %{harness: true, interrupted: true}} = notice}}

    assert Message.text_content(notice) =~ "The app restarted while this turn was running"

    # It is part of the history, so the transcript keeps it, and the record the
    # restart left behind is gone (INTR-1).
    assert [%Message{role: :user}, %Message{meta: %{interrupted: true}}] = Elia.Store.load(id)
    assert Elia.Store.load_turn(id) == nil
    assert %{status: :idle, messages: [_, _]} = Agent.snapshot(id)

    # UI-72: the status broadcast is what drops the marker in every other page.
    assert_receive {:chat_status, ^id, :idle}
    assert %{interrupted: false} = listed(id)

    # INTR-3: a chat with no record is left untouched.
    done = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(done) end)
    :ok = Elia.Store.save(done, [Message.user("hi"), FakeLLM.assistant([Message.text("hello")])])
    {:ok, pid} = Agent.ensure_started(done)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    assert [_, %Message{role: :assistant}] = Agent.snapshot(done).messages
  end

  # INTR-3, SESS-21
  test "an interrupted turn whose last message was a tool call still says so" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # The app stopped while a tool call was out, so its chat ends with a call
    # that has no result — and closing that call is a save of the chat (SESS-21),
    # which must not take the notice with it.
    call = FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})
    turn = %{id: "turn-1", started_at: DateTime.utc_now()}
    :ok = Elia.Store.save(id, [Message.user("run it"), FakeLLM.assistant([call])], turn: turn)

    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool, content: [result]},
             %Message{meta: %{interrupted: true}} = notice
           ] = Elia.Store.load(id)

    assert %{tool_call_id: "c1", is_error: true} = result
    assert Message.text_content(notice) =~ "The app restarted while this turn was running"
    assert Elia.Store.load_turn(id) == nil
  end

  # INTR-4, STORE-31, SUBTASK-20
  test "a sub-task chat whose turn a restart cut short says so too" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    task = %{parent_id: "parent-1", started_at: ~U[2026-01-02 03:04:05Z]}
    turn = %{id: "turn-1", started_at: DateTime.utc_now()}
    :ok = Elia.Store.save(id, [Message.user("do it")], task: task, turn: turn)

    # STORE-31: the record the restart left behind is the chat's own, so the
    # status its parent reads from its chat (STORE-18, UI-46) is `interrupted`.
    assert %{interrupted: true} = listed(id)
    refute Map.has_key?(listed(id), :task_status)

    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    assert [%Message{role: :user}, %Message{meta: %{interrupted: true}}] = Elia.Store.load(id)
    # Nothing else about the task changes (STORE-16: it carries no status).
    assert Elia.Store.load_task(id) == task
  end

  defp listed(id), do: Enum.find(Elia.Store.list(1000), &(&1.id == id)) || %{interrupted: false}

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

  # SESS-19, SESS-35, UI-49: a chat's done flag is announced on the activity
  # topic as its status, so a page showing other chats — a parent's sidebar —
  # learns a child was marked done live.
  test "a chat's done flag is announced on the activity topic", %{id: id} do
    Agent.subscribe_activity()

    assert {:ok, true} = Agent.set_done(id, true)
    assert_receive {:agent, ^id, {:done, true}}
    assert_receive {:chat_status, ^id, :done}

    # DONE-9: reopening it announces the status the chat goes back to, which is
    # the one its row shows (UI-59).
    assert {:ok, false} = Agent.set_done(id, false)
    assert_receive {:agent, ^id, {:done, false}}
    assert_receive {:chat_status, ^id, :idle}
  end

  # SESS-19, SESS-35: a turn that ends keeps announcing what it announces — the
  # status a chat marked done was set to is not left standing in the registry,
  # and the flag's own event never replaces a turn's (PUSH-11, PUSH-12).
  test "a done chat's turn still runs to idle", %{id: id} do
    Agent.subscribe_activity()
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    assert {:ok, true} = Agent.set_done(id, true)
    assert_receive {:chat_status, ^id, :done}

    :ok = Agent.send_message(id, "go")
    assert_receive {:chat_status, ^id, :idle}, 5000
    assert Agent.snapshot(id).done == false
  end

  # SESS-28
  test "the running ids are the sessions with a turn in progress", %{id: id} do
    Agent.subscribe_activity()
    refute id in Agent.running()

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "run it")
    assert_receive {:chat_status, ^id, :running}
    assert id in Agent.running()

    # Waiting for approval is no longer "running" (SESS-4).
    assert_receive {:chat_status, ^id, :awaiting_approval}
    refute id in Agent.running()

    :ok = Agent.deny(id, "c1")
    assert_receive {:chat_status, ^id, :idle}, 5000
    refute id in Agent.running()
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

  # VISION-9, VISION-14: the message of a request that carries the picture a look
  # put in it, wherever in the request it now is.
  defp picture_message(request) do
    Enum.find(request.messages, fn
      %Message{role: :tool, content: content} ->
        Enum.any?(content, &(&1[:type] == :image))

      _message ->
        false
    end)
  end

  # VISION-15: an attachment is not sent as a picture by itself — the request
  # carries the line naming its path and nothing of the picture, whether the
  # model can see pictures or not. Only a look sends one (VISION-12).
  test "an attachment is not sent as a picture by itself" do
    dir = tmp_dir("vision-attachment")
    write_image(dir, "uploads/shot.png")

    for vision <- [true, false] do
      id =
        start_project_session(other_project(dir),
          loop_opts: [llm: %{provider: FakeLLM, vision: vision}]
        )

      FakeLLM.push(FakeLLM.assistant([Message.text("ok")]))

      :ok = Agent.send_message(id, "look at this", ["uploads/shot.png"])
      await_status(id, :idle)

      request = List.last(FakeLLM.requests())
      assert request.vision == vision

      # The path is named, as it always was (UPLOAD-10), and no picture is sent
      # for it.
      [%Message{role: :user, content: content} | _] = request.messages

      assert Message.text_content(%Message{role: :user, content: content}) =~
               "[Uploaded files: uploads/shot.png]"

      refute Enum.any?(request.messages, &Enum.any?(&1.content, fn b -> b[:type] == :image end))

      # Nothing was recorded on the message either: what it carries is the same
      # whichever model it is sent to.
      assert Message.attachments(Enum.find(Agent.snapshot(id).messages, &(&1.role == :user))) ==
               ["uploads/shot.png"]
    end
  end

  # VISION-2: a PNG, whose signature is what makes the file one. Returns the
  # bytes, so a test can hold the request's image to the file's own.
  defp write_image(dir, path) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    png = <<0x89, "PNG\r\n", 0x1A, "\n">> <> "shot body"
    File.write!(file, png)
    png
  end

  defp start_project_session(project, opts \\ []) do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, [project: project] ++ opts)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    id
  end

  # SECRET-6, SECRET-8, SECRET-10, SECRET-12: a project's secret never reaches
  # the model — not in the system prompt, not in what a command printed — while
  # the transcript keeps what the command actually printed.
  test "a secret a command printed is redacted from the request and kept in the transcript" do
    dir = tmp_dir("secrets")
    File.write!(Path.join(dir, ".env"), "STRIPE_KEY=sk_live_secret_value\n")
    id = start_project_session(other_project(dir), auto_approve: [])

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "cat .env"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Read it.")]))

    :ok = Agent.send_message(id, "read the env file")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)

    [first, second] = FakeLLM.requests()

    # SECRET-12: the model is told the name, never the value.
    assert first.system =~ "## Project secrets"
    assert first.system =~ "STRIPE_KEY"
    refute first.system =~ "sk_live_secret_value"

    # SECRET-6, SECRET-8: the result the command produced is redacted on its way
    # to the model, and the request carries no occurrence of the value at all.
    [_, _call, %Message{role: :tool, content: [result]}] = second.messages
    assert result.content =~ "[redacted:STRIPE_KEY]"
    refute inspect(second) =~ "sk_live_secret_value"

    # SECRET-10: the transcript keeps what the command printed, so the user reads
    # the real thing.
    tool_message = Enum.find(Agent.snapshot(id).messages, &match?(%Message{role: :tool}, &1))
    assert [%{content: kept}] = tool_message.content
    assert kept =~ "sk_live_secret_value"
  end

  # PROJ-9, SESS-7
  test "a chat belongs to its project" do
    project = other_project(tmp_dir("belongs"))
    id = start_project_session(project)

    assert %{project: %{id: project_id}} = Agent.snapshot(id)
    assert project_id == project.id
  end

  # VISION-9, VISION-12, VISION-14: the agent looks at a picture with the
  # `view_image` tool, and the request carries it beside that call's own result —
  # read from the chat's workspace as the request is built, and again at the next
  # step of the turn, while the chat itself keeps the path and no picture
  # (VISION-15).
  test "a look puts the picture in the result's own turn" do
    dir = tmp_dir("vision")
    png = write_image(dir, "uploads/shot.png")

    id =
      start_project_session(other_project(dir),
        loop_opts: [llm: %{provider: FakeLLM, vision: true}]
      )

    # One step looks at the picture, and one more step follows it, so there are
    # two requests after the look to compare with.
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "view_image", %{"path" => "uploads/shot.png"})
      ])
    )

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c2", "set_title", %{"title" => "A picture"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("I see it.")]))

    :ok = Agent.send_message(id, "look at uploads/shot.png")
    await_status(id, :idle)

    assert [first, second, third] = FakeLLM.requests()

    # VISION-14: the request that asked for the look carries no picture at all —
    # the result it belongs to doesn't exist yet.
    refute Enum.any?(first.messages, &Enum.any?(&1.content, fn b -> b[:type] == :image end))

    # VISION-9: the next step of the turn sends it, and so does the one after
    # that — read from the chat's workspace again as each request is built.
    for request <- [second, third] do
      assert request.vision == true

      assert %Message{role: :tool, content: [result, picture]} = picture_message(request)

      # VISION-12: the result records what the look read, and its text says so to
      # the model (SNAP-8).
      assert result.image == %{
               path: "uploads/shot.png",
               media_type: "image/png",
               size: byte_size(png)
             }

      assert result.content =~ "Looked at uploads/shot.png"

      # VISION-14: the picture is the file's own, in that result's own turn.
      assert %{type: :image, media_type: "image/png", path: "uploads/shot.png"} = picture
      assert Base.decode64!(picture.data) == png

      # And it is the only picture in the request.
      assert Enum.count(request.messages, &Enum.any?(&1.content, fn b -> b[:type] == :image end)) ==
               1
    end

    # VISION-15: the saved chat keeps the path the look recorded and no picture.
    messages = Agent.snapshot(id).messages
    assert %Message{role: :tool, content: [result]} = Enum.find(messages, &(&1.role == :tool))
    assert result.image.path == "uploads/shot.png"
    refute Enum.any?(messages, &Enum.any?(&1.content, fn b -> b[:type] == :image end))
    refute inspect(Elia.Store.load(id)) =~ Base.encode64(png)
  end

  # VISION-4, VISION-13: a look on a model that accepts no pictures is refused as
  # that call's own error — no path is recorded — and the model is sent what it
  # is sent today: no picture at all.
  test "a model that accepts no pictures refuses a look and is sent none" do
    dir = tmp_dir("vision-none")
    write_image(dir, "uploads/shot.png")

    id =
      start_project_session(other_project(dir),
        loop_opts: [llm: %{provider: FakeLLM, vision: false}]
      )

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "view_image", %{"path" => "uploads/shot.png"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("It can't be looked at.")]))

    :ok = Agent.send_message(id, "look at uploads/shot.png")
    await_status(id, :idle)

    assert [_first, second] = FakeLLM.requests()
    assert second.vision == false

    assert %Message{role: :tool, content: [result]} = List.last(second.messages)
    assert result.is_error
    assert result.content =~ "accepts no pictures"
    refute Map.has_key?(result, :image)

    refute Enum.any?(second.messages, &Enum.any?(&1.content, fn b -> b[:type] == :image end))
  end

  # PROJ-12, WD-1, WD-9, LOOP-10, SESS-23
  test "a chat's project folder is its workspace" do
    dir = tmp_dir("files")
    # APPR-14: an empty set, so the command below still asks (this test approves
    # it), and the `cd` needs no approval at all (WD-6).
    id =
      start_project_session(other_project(dir),
        loop_opts: [llm: %{provider: FakeLLM}],
        auto_approve: []
      )

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "shell", %{"command" => "pwd && echo hello > notes.txt"}),
        FakeLLM.tool_call("c2", "cd", %{"path" => "."})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(id, "write it")
    await_status(id, :awaiting_approval)
    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)

    # The command ran in the project folder, and its relative path resolved
    # there.
    assert File.read!(Path.join(dir, "notes.txt")) == "hello\n"
    refute File.exists?(Path.join(Path.dirname(dir), "notes.txt"))

    [_, second] = FakeLLM.requests()

    # PROJ-12, WD-9: `pwd` is the project's folder.
    assert %Message{role: :tool, content: [%{is_error: false, content: out}, cd]} =
             List.last(second.messages)

    assert out =~ Elia.Workspace.real_location(dir)
    assert out =~ "[exit: 0]"

    # PROJ-12, WD-1: `cd` judges a path against that folder too, so `.` is
    # inside it and needs no approval (WD-6).
    assert %{is_error: false, content: "Working directory: ." <> _} = cd
    assert File.read!(Path.join(dir, "notes.txt")) == "hello\n"
  end

  # SKILL-17, SKILL-18: the project instructions a request carries are the
  # confined ones — an `AGENTS.md` that is a link out of the project folder is
  # not read, so nothing of the file it points at reaches the request at all.
  test "an AGENTS.md link out of the project folder never reaches the request" do
    dir = tmp_dir("agents")
    outside = Path.join(System.tmp_dir!(), "elia-agents-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    target = Path.join(outside, "secrets.md")
    File.write!(target, "SENTINEL-never-in-the-prompt")
    File.ln_s!(target, Path.join(dir, "AGENTS.md"))
    on_exit(fn -> File.rm_rf!(outside) end)

    id = start_project_session(other_project(dir), loop_opts: [llm: %{provider: FakeLLM}])

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    # The whole request: no section was added, and none of the file is in it.
    [request] = FakeLLM.requests()
    refute inspect(request) =~ "SENTINEL-never-in-the-prompt"
    refute inspect(request) =~ "Project instructions"
  end

  # PROJ-12, SHELL-2
  test "the shell runs in the chat's project folder" do
    dir = tmp_dir("shell")
    File.write!(Path.join(dir, "marker.txt"), "here")

    # APPR-14: an empty set, so the command still asks (this test approves it).
    id =
      start_project_session(other_project(dir),
        loop_opts: [llm: %{provider: FakeLLM}],
        auto_approve: []
      )

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

  # PROJ-14, PROJ-15, PROJ-18
  test "the system prompt is the chat's project's AGENTS.md and skills, with no Elia-own instruction" do
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
    # PROJ-14: Elia's own worktree instruction is in Elia's own AGENTS.md, so a
    # chat in another project is not given it.
    refute request.system =~ "tmp/worktrees/"
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
              name: "shell",
              input: %{"command" => "cat lib/file#{n}.ex"}
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

    # COMPACT-40: the elision is applied and broadcast first, in the callback the
    # message was sent to; the summary lands later, from the worker that folded
    # it, and the turn starts from it.
    assert_receive {:agent, ^id, {:compaction, elided}}, 5000
    assert elided.level == 3

    compaction = await_summary(id)
    assert compaction.summary == "Six turns of reading files."

    assert_receive {:agent, ^id, {:usage, usage}}, 5000
    await_status(id, :idle)

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

    # COMPACT-29, COMPACT-32: the most recent step of the turn being run — its
    # assistant message, its calls and their results — is still sent in full.
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

  # COMPACT-1, COMPACT-5, COMPACT-29, COMPACT-31, COMPACT-32, COMPACT-33
  test "a chat whose whole history is one turn is bounded from inside it mid-turn" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # A chat with no history: the turn being run is the whole chat, so there is
    # no cold prefix at all (COMPACT-28), and the rung inside the turn is the
    # only thing that can bound it (COMPACT-31).
    output = String.duplicate("out ", 700)
    big_reasoning = String.duplicate("think ", 2_000)

    start_compaction_session(id,
      compaction: %{budget: 1},
      loop_opts: [llm: %{provider: FakeLLM}, skills: fake_skill(output)]
    )

    test_pid = self()

    # Step one reasons a lot and calls the tool; step two's call is answered
    # while step three waits, so the turn is provably still running when the
    # mid-turn pass is asserted on.
    FakeLLM.push(
      FakeLLM.assistant([
        %{type: :reasoning, text: big_reasoning},
        FakeLLM.tool_call("c1", "fake_tool", %{})
      ])
    )

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:second_request, self()})

      receive do
        :go -> :ok
      end

      {:ok,
       %{
         message:
           FakeLLM.assistant([
             %{type: :reasoning, text: "a short thought"},
             FakeLLM.tool_call("c2", "fake_tool", %{})
           ]),
         stop_reason: :tool_use,
         model: "fake",
         usage: %{}
       }}
    end)

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:third_request, self()})

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

    :ok = Agent.send_message(id, "do the work")
    assert_receive {:second_request, loop}, 5000
    send(loop, :go)
    assert_receive {:third_request, third_loop}, 5000

    # COMPACT-29: the pass's state is reported, saved and broadcast before the
    # turn ends. Nothing is cold — the chat is one turn — and the marker is the
    # boundary of the turn's most recent step (COMPACT-31, COMPACT-32). The pass
    # takes the older step's reasoning and its tool result, so the deepest rung it
    # went to is that of tool results (COMPACT-36, COMPACT-37): no whole step is
    # dropped, since no message is cold (COMPACT-39).
    assert_receive {:agent, ^id, {:compaction, %{level: 2, covered: 0, turn_covered: 3}}}, 5000
    assert Agent.snapshot(id).status == :running

    send(third_loop, :go)
    await_status(id, :idle)

    assert %{level: 2, covered: 0, turn_covered: 3} = Elia.Store.load_compaction(id)

    [first, second, third] = FakeLLM.requests()

    # The request view shrinks while the history grows: the step before the most
    # recent one is elided (COMPACT-31), so the third request is smaller than the
    # second even though a whole step was added to the chat.
    assert Elia.LLM.Compaction.tokens(third.messages) <
             Elia.LLM.Compaction.tokens(second.messages)

    assert Enum.any?(third.messages, &(&1.meta[:compaction] == :marker))

    # COMPACT-32: the most recent step — its assistant message, its call and its
    # result — is sent in full. The tool's own output is sent whole; the loop
    # appends its standing-still notice to it because this step's call is the
    # identical call to the one before it (LOOP-24).
    assert Enum.any?(third.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c2"}]} ->
               String.starts_with?(content, output)

             _ ->
               false
           end)

    assert Enum.any?(third.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c2"))

             _ ->
               false
           end)

    # COMPACT-33: the older step is elided by the rungs only — its reasoning is
    # gone and its result is a note — and its call is still there.
    refute Enum.any?(third.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :reasoning and &1.text == big_reasoning))

             _ ->
               false
           end)

    assert Enum.any?(third.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c1"}]} ->
               content =~ "output elided by compaction"

             _ ->
               false
           end)

    assert Enum.any?(third.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c1"))

             _ ->
               false
           end)

    # The user message that began the turn is still sent (COMPACT-32).
    assert Enum.any?(third.messages, &(Message.text_content(&1) == "do the work"))

    # COMPACT-1: the session's history keeps everything, that reasoning included.
    snapshot = Agent.snapshot(id)
    assert length(snapshot.messages) == 6

    assert Enum.any?(snapshot.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :reasoning and &1.text == big_reasoning))

             _ ->
               false
           end)

    # The first request had nothing to elide: it was the brief alone.
    assert Enum.all?(first.messages, &(&1.meta[:compaction] != :marker))
  end

  # COMPACT-38, ## Stored data
  test "a saved state that predates the item list still elides what it described" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    messages = big_history(3)

    # A state as a build before the item list saved it: a level and the
    # boundaries that went with it, and no items.
    :ok =
      Elia.Store.save(id, messages,
        compaction: %{
          level: 3,
          covered: 8,
          folded: 0,
          turn_covered: 0,
          pins: [],
          ledger: [],
          options: %{}
        }
      )

    start_compaction_session(id, loop_opts: [llm: %{provider: FakeLLM}])

    state = Agent.snapshot(id).compaction

    # The chat loads with the items the level described materialised, so nothing
    # it had already elided comes back.
    assert state.items != []
    view = Elia.LLM.Compaction.view(messages, state)
    assert Enum.all?([1, 2, 3, 5, 6, 7], &(view.statuses[&1].status in [:elided, :summarized]))
    refute Enum.any?(view.messages, &(Message.text_content(&1) == "done 1"))
    # Its user messages are still sent (COMPACT-11).
    assert Enum.any?(view.messages, &(Message.text_content(&1) =~ "task 1"))
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

    # COMPACT-40, COMPACT-41: the manual pass elides and answers at once; its
    # summary lands later, from the worker that folded it.
    :ok = Agent.compact(id)
    assert_receive {:agent, ^id, {:compaction, elided}}, 5000
    assert elided.level == 3

    compaction = await_summary(id)
    assert compaction.summary == "The first turns, folded."
    assert %{level: 3} = Elia.Store.load_compaction(id)
  end

  # COMPACT-10, COMPACT-31, COMPACT-32, COMPACT-33
  test "compact now reaches inside a chat whose whole history is one turn" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # One turn only, so there is no cold prefix at all (COMPACT-28) and the
    # manual pass (COMPACT-10) is the only one that can bound it (COMPACT-31).
    output = String.duplicate("out ", 700)
    reasoning = String.duplicate("think ", 2_000)

    messages = [
      Message.user("do the work"),
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: reasoning},
          %{type: :tool_call, id: "c1", name: "shell", input: %{"command" => "cat lib/a.ex"}}
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("c1", output)]},
      %Message{
        role: :assistant,
        content: [
          %{type: :tool_call, id: "c2", name: "shell", input: %{"command" => "cat lib/b.ex"}}
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("c2", "the newest output")]}
    ]

    :ok = Elia.Store.save(id, messages)

    start_compaction_session(id,
      loop_opts: [
        llm: %{provider: FakeLLM},
        summarizer: fn _ -> {:ok, "The one turn, folded."} end
      ]
    )

    assert Agent.snapshot(id).compaction.level == 0

    :ok = Agent.compact(id)
    assert_receive {:agent, ^id, {:compaction, _compaction}}, 5000

    compaction = Agent.snapshot(id).compaction
    view = Elia.LLM.Compaction.view(messages, compaction)

    # The request view is smaller than the history, which is what nothing could
    # do for a chat of one turn before (COMPACT-31).
    assert view.tokens < Elia.LLM.Compaction.tokens(messages)

    # COMPACT-32: the turn's most recent step — its call and its result — is sent
    # in full, and so is the user message that began the turn.
    assert Enum.any?(view.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c2"}]} ->
               content == "the newest output"

             _ ->
               false
           end)

    assert Enum.any?(view.messages, &(Message.text_content(&1) == "do the work"))

    # COMPACT-33: the older step was elided by the rungs only — its reasoning is
    # gone and its result is a note — and its call is still there (COMPACT-4).
    refute Enum.any?(view.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :reasoning and &1.text == reasoning))

             _ ->
               false
           end)

    assert Enum.any?(view.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c1"}]} ->
               content =~ "output elided by compaction"

             _ ->
               false
           end)

    assert Enum.any?(view.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c1"))

             _ ->
               false
           end)
  end

  # COMPACT-10, SESS-25
  test "compact now refuses while a turn is running" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    # APPR-14: an empty set, so the command below waits for approval.
    start_compaction_session(id, loop_opts: [llm: %{provider: FakeLLM}], auto_approve: [])

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

  ## A summary off the session's path (COMPACT-40..COMPACT-46)

  # A summarizer that holds until the test releases it, so a fold is provably
  # still running while the chat is driven. It names the process holding it,
  # which is what the test releases.
  defp held_summarizer(test_pid) do
    fn _input ->
      send(test_pid, {:summarizing, self()})

      receive do
        :go -> {:ok, "held summary"}
      end
    end
  end

  # COMPACT-40, COMPACT-41, COMPACT-45
  test "a held summary does not hold the chat's calls" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: held_summarizer(self())]
    )

    assert :ok = Agent.compact(id)
    assert_receive {:summarizing, worker}, 5000

    # COMPACT-40: the elision is applied and the chat answers its own calls —
    # its snapshot, a pin, a ledger entry — while the summary is still held.
    assert %{status: :idle, compaction: %{level: 3}} = Agent.snapshot(id)
    assert :ok = Agent.set_pin(id, 1)

    assert {:ok, ["a fact written while the summary ran"]} =
             Agent.add_ledger(id, ["a fact written while the summary ran"])

    # COMPACT-45: one fold at a time, so a second manual pass is busy.
    assert {:error, :busy} = Agent.compact(id)

    send(worker, :go)
    compaction = await_summary(id)

    # COMPACT-41: what landed is the summary alone, onto the state as it stands.
    assert compaction.summary == "held summary"
    assert compaction.ledger == ["a fact written while the summary ran"]
    assert {1, nil} in compaction.pins

    assert %{summary: "held summary", ledger: ["a fact written while the summary ran"]} =
             Elia.Store.load_compaction(id)
  end

  # COMPACT-42
  test "a turn whose start began a fold starts from the summary it waited for" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: held_summarizer(self())]
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("carried on")]))

    assert :ok = Agent.send_message(id, "carry on")
    assert_receive {:summarizing, worker}, 5000

    # COMPACT-42: the turn is the chat's already — its record and its message are
    # in the history and it shows as running, so its calls are answered and a
    # second message is refused — while the summary is held.
    assert %{status: :running} = Agent.snapshot(id)
    assert {:error, :busy} = Agent.send_message(id, "again")

    send(worker, :go)
    await_status(id, :idle)

    # COMPACT-42: the loop starts from the fold's result, so the turn's request
    # carries the summary the fold produced (COMPACT-19).
    [request] = FakeLLM.requests()
    assert [%Message{meta: %{compaction: :summary}} = head | _] = request.messages
    assert Message.text_content(head) =~ "held summary"

    assert Message.text_content(List.last(Agent.snapshot(id).messages)) == "carried on"
  end

  # COMPACT-43
  test "a stop ends a summary in flight, and its late result starts no turn" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: held_summarizer(self())]
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("carried on")]))
    :ok = Agent.send_message(id, "carry on")
    assert_receive {:summarizing, worker}, 5000

    ref = Process.monitor(worker)
    assert :ok = Agent.stop(id)

    # COMPACT-43: the worker is ended, so the summary it held is never produced.
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5000

    # The turn is over, the stop is what the transcript holds, and no request was
    # ever made: nothing started from the result that never landed.
    snapshot = Agent.snapshot(id)
    assert snapshot.status == :idle
    assert snapshot.compaction.summary == nil
    assert FakeLLM.requests() == []
    assert Message.text_content(List.last(snapshot.messages)) =~ "Stopped by the user."
  end

  # COMPACT-44
  test "a session's death ends the summary in flight" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: held_summarizer(self())]
    )

    assert :ok = Agent.compact(id)
    assert_receive {:summarizing, worker}, 5000

    ref = Process.monitor(worker)
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    # COMPACT-44: the fold belongs to the session that started it (SESS-45).
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5000
  end

  # COMPACT-46
  test "a turn that starts while a summary is in flight folds nothing of its own" do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, big_history(4))

    start_compaction_session(id,
      compaction: %{budget: 1, working_set: 2},
      loop_opts: [llm: %{provider: FakeLLM}, summarizer: held_summarizer(self())]
    )

    # The manual pass's summary is held, so it is in flight when the turn starts.
    assert :ok = Agent.compact(id)
    assert_receive {:summarizing, worker}, 5000

    FakeLLM.push(FakeLLM.assistant([Message.text("carried on")]))
    :ok = Agent.send_message(id, "carry on")
    await_status(id, :idle)

    # COMPACT-46: the turn-start pass elided as it would and folded nothing of
    # its own, so the turn ran on the elision alone.
    [request] = FakeLLM.requests()
    assert Enum.any?(request.messages, &(&1.meta[:compaction] == :marker))
    refute Enum.any?(request.messages, &(&1.meta[:compaction] == :summary))
    refute_receive {:summarizing, _another}, 100

    # The fold that was in flight is still the one that lands (COMPACT-41).
    send(worker, :go)
    assert await_summary(id).summary == "held summary"
  end

  # SESS-29
  test "delete removes the chat and its session, so nothing saves it again", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    assert [%Message{role: :user}, %Message{role: :assistant}] = Elia.Store.load(id)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    ref = Process.monitor(pid)

    assert :ok = Agent.delete(id)

    # The session process is gone, so a stale session can't save the chat again.
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000
    assert Registry.lookup(Elia.Agent.Registry, id) == []
    assert Elia.Store.load(id) == []
    refute Enum.any?(Elia.Store.list(1000), &(&1.id == id))

    # A chat opened again starts from nothing: nothing came back.
    {:ok, restarted} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, restarted) end)
    assert Agent.snapshot(id).messages == []
  end

  # SESS-29
  test "delete of a chat with no session simply removes it" do
    id = Agent.new_id()
    :ok = Elia.Store.save(id, [Message.user("hi")])
    on_exit(fn -> Elia.Store.delete(id) end)

    assert :ok = Agent.delete(id)
    assert Elia.Store.load(id) == []
  end

  # SESS-48
  test "delete announces the chat on the activity topic" do
    id = Agent.new_id()
    :ok = Elia.Store.save(id, [Message.user("hi")])
    on_exit(fn -> Elia.Store.delete(id) end)

    Agent.subscribe_activity()

    assert :ok = Agent.delete(id)
    assert_receive {:chat_deleted, ^id}, 2000
    # The chat is gone by the time the event arrives, so a page that reads the
    # chats again finds it gone (ACTIVE-7).
    refute Enum.any?(Elia.Store.list(1000), &(&1.id == id))
  end

  # SESS-29, SESS-8, UI-65
  test "delete stops a running turn and the chat stays deleted" do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "thinking"})
      Process.sleep(5000)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("late")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(id, "hi")
    assert_receive {:agent, ^id, {:status, :running}}, 2000
    # The user message is saved as the turn starts.
    assert [%Message{role: :user}] = Elia.Store.load(id)

    assert :ok = Agent.delete(id)

    assert Registry.lookup(Elia.Agent.Registry, id) == []
    assert Elia.Store.load(id) == []
    refute File.exists?(Path.join(Elia.Store.dir(), id <> ".term"))
  end

  # SESS-29, STORE-4
  test "delete rejects an invalid id" do
    assert {:error, :invalid_id} = Agent.delete("../bad")
    assert {:error, :invalid_id} = Agent.delete("")
  end

  # SESS-15, SESS-26
  test "a session with state from before :compaction existed is upgraded", %{id: id} do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :compaction))

    assert %{compaction: %Elia.LLM.Compaction{level: 0}} = Agent.snapshot(id)
  end

  # SESS-15, SESS-30
  test "a session with state from before the settings map existed loads its saved jail", %{
    id: id
  } do
    :ok = Elia.Store.save(id, [Message.user("hi")], jail: false)
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.replace_state(pid, &Map.delete(&1, :settings))

    # The upgrade loads the chat's saved setting (STORE-26).
    assert %{settings: %{jail: false}} = Agent.snapshot(id)
  end

  # SESS-7, SESS-30, ISOL-16
  test "a chat is jailed by default, and the snapshot says so", %{id: id} do
    assert %{settings: %{jail: true}} = Agent.snapshot(id)
  end

  # SESS-6, SESS-30, SESS-41
  test "setting the jail broadcasts it and shows in the snapshot", %{id: id} do
    :ok = Agent.set_jail(id, false)
    assert_receive {:agent, ^id, {:settings, %{jail: false}}}
    assert %{settings: %{jail: false}} = Agent.snapshot(id)

    :ok = Agent.set_jail(id, true)
    assert_receive {:agent, ^id, {:settings, %{jail: true}}}
    assert %{settings: %{jail: true}} = Agent.snapshot(id)
  end

  # NET-1, NET-3, NET-28, SESS-41: a chat's network setting is its mode — the
  # entries are its project's — set, broadcast like its other settings, and
  # shown in the snapshot; what its commands are limited by carries the
  # project's entries (NET-6).
  test "setting the network broadcasts it and shows in the snapshot", %{id: id} do
    # NET-1: a chat that has never chosen a mode starts at the default.
    assert Agent.snapshot(id).settings.network == Elia.Net.default(jail: true)

    :ok = Agent.set_network(id, %{mode: :allowlist})

    assert_receive {:agent, ^id, {:settings, %{network: %{mode: :allowlist}}}}
    assert %{settings: %{network: %{mode: :allowlist, hosts: []}}} = Agent.snapshot(id)

    :ok = Agent.set_network(id, %{mode: :none})
    assert_receive {:agent, ^id, {:settings, %{network: %{mode: :none}}}}
    assert Agent.network(id) == %{mode: :none, hosts: []}
  end

  # NET-1, NET-28, SESS-42: a mode that isn't one of the three changes nothing
  # and says why; the entries a chat is offered are its project's, so a list of
  # its own is not stored (PROJ-49).
  test "a network setting that isn't one is refused", %{id: id} do
    :ok = Agent.set_network(id, %{mode: :allowlist})

    assert {:error, message} = Agent.set_network(id, %{mode: :everything})
    assert message =~ "network"
    assert Agent.network(id) == %{mode: :allowlist, hosts: []}

    # An entry of its own is not the chat's to keep: the project's list is.
    :ok = Agent.set_network(id, %{mode: :allowlist, hosts: ["not a host"]})
    assert %{settings: %{network: %{mode: :allowlist, hosts: []}}} = Agent.snapshot(id)
  end

  # NET-6: a chat with no running session answers nil, so a proxy deciding a
  # request falls back to the list it started with.
  test "a chat with no session has no network to read" do
    assert Agent.network("no-such-chat") == nil
  end

  # SESS-6, SESS-40, SESS-41
  test "setting the reasoning effort broadcasts it and shows in the snapshot", %{id: id} do
    :ok = Agent.set_effort(id, "high")
    assert_receive {:agent, ^id, {:settings, %{effort: "high"}}}
    assert %{settings: %{effort: "high"}} = Agent.snapshot(id)

    :ok = Agent.set_effort(id, nil)
    assert_receive {:agent, ^id, {:settings, %{effort: nil}}}
    assert %{settings: %{effort: nil}} = Agent.snapshot(id)
  end

  # SESS-40, SESS-42: the three efforts a request can name (LLM-39) and nothing
  # else.
  test "an effort that isn't low, medium or high is rejected", %{id: id} do
    assert {:error, message} = Agent.set_effort(id, "very high")
    assert message =~ "low, medium or high"
    assert %{settings: %{effort: nil}} = Agent.snapshot(id)
    refute_receive {:agent, ^id, {:settings, _}}
  end

  # SESS-40, STORE-37, STORE-38
  test "the reasoning effort is per chat and survives a restart", %{id: id} do
    other = Agent.new_id()
    {:ok, other_pid} = Agent.ensure_started(other)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, other_pid) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))
    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    :ok = Agent.set_effort(id, "low")
    assert Elia.Store.load_effort(id) == "low"
    # The setting belongs to one chat.
    assert %{settings: %{effort: nil}} = Agent.snapshot(other)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, _} = Agent.ensure_started(id)
    assert %{settings: %{effort: "low"}} = Agent.snapshot(id)

    :ok = Agent.set_effort(id, nil)
    assert Elia.Store.load_effort(id) == nil
  end

  # SESS-40, CSET-6: an empty chat isn't written to disk (SESS-14)
  test "setting the effort in an empty chat writes nothing", %{id: id} do
    :ok = Agent.set_effort(id, "low")
    assert Elia.Store.load_effort(id) == nil
    refute File.exists?(Path.join(Elia.Store.dir(), id <> ".term"))
  end

  # SESS-40, LLM-39
  test "a turn's request carries the chat's own effort", %{id: id} do
    :ok = Agent.set_effort(id, "low")
    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))

    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    assert [%{effort: "low"}] = FakeLLM.requests()
  end

  # SESS-40: an effort the caller named in its own loop options wins.
  test "an effort the caller passed in loop options wins" do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, auto_approve: [], loop_opts: [llm: %{effort: "high"}])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    Agent.subscribe(id)

    :ok = Agent.set_effort(id, "low")
    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))

    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    assert [%{effort: "high"}] = FakeLLM.requests()
  end

  # SESS-30, STORE-25, ISOL-16, ISOL-18
  test "the jail setting is per chat and survives a restart", %{id: id} do
    other = Agent.new_id()
    {:ok, other_pid} = Agent.ensure_started(other)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, other_pid) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))
    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    :ok = Agent.set_jail(id, false)
    assert Elia.Store.load_jail(id) == false
    # The setting belongs to one chat (ISOL-18).
    assert %{settings: %{jail: true}} = Agent.snapshot(other)

    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    {:ok, _} = Agent.ensure_started(id)
    assert %{settings: %{jail: false}} = Agent.snapshot(id)

    :ok = Agent.set_jail(id, true)
    assert Elia.Store.load_jail(id) == true
  end

  # SESS-30: an empty chat isn't written to disk (SESS-14)
  test "turning the jail off in an empty chat writes nothing", %{id: id} do
    :ok = Agent.set_jail(id, false)
    assert Elia.Store.load_jail(id) == true
    refute File.exists?(Path.join(Elia.Store.dir(), id <> ".term"))
  end

  # SESS-30, ISOL-19: allowed mid-turn
  test "the jail can be turned off while a turn runs", %{id: id} do
    parent = self()

    FakeLLM.push(fn _request, _on_event ->
      send(parent, {:turn_started, self()})

      receive do
        :go ->
          {:ok,
           %{
             message: FakeLLM.assistant([Message.text("Done.")]),
             stop_reason: :end_turn,
             model: "fake",
             usage: %{}
           }}
      end
    end)

    :ok = Agent.send_message(id, "hi")
    assert_receive {:turn_started, loop}, 2000

    assert :ok = Agent.set_jail(id, false)
    assert_receive {:agent, ^id, {:settings, %{jail: false}}}
    assert %{settings: %{jail: false}} = Agent.snapshot(id)

    send(loop, :go)
    await_status(id, :idle)
    assert Elia.Store.load_jail(id) == false
  end

  # ISOL-15, LOOP-18: the tool context of a turn carries the chat's jail setting,
  # so the tools jail a call according to the chat they run in — and it is the
  # context LOOP-18 describes that a tool's `run/2` is handed.
  test "the turn's tool context carries the chat's jail setting" do
    id = Agent.new_id()
    test_pid = self()

    spy = %Elia.Tool{
      name: "spy",
      description: "reports the tool context it was given",
      input_schema: %{"type" => "object", "properties" => %{}},
      approval: :never,
      run: fn _input, ctx ->
        send(test_pid, {:tool_ctx, ctx})
        {:ok, "reported"}
      end
    }

    skills = [%Elia.Skill{name: "spy", description: "spy", tools: [spy]}]

    {:ok, pid} =
      Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM}, skills: skills])

    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    Agent.subscribe(id)
    :ok = Agent.set_jail(id, false)

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "spy", %{})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    :ok = Agent.send_message(id, "go")

    assert_receive {:tool_ctx, ctx}, 5000
    assert ctx.jail == false
    await_status(id, :idle)
  end

  ## One settings path (SESS-41, SESS-42)

  # SESS-41: one call sets any of the five, and the change is one save and one
  # event carrying the whole map.
  test "one call sets several settings at once, with one event", %{id: id} do
    selection = %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}

    assert :ok =
             Agent.set_settings(id, %{
               model: selection,
               auto_approve: %{"shell" => true},
               jail: false,
               limits: %{max_steps: 5},
               effort: "low"
             })

    assert_receive {:agent, ^id, {:settings, settings}}
    assert settings.model == selection
    assert settings.auto_approve == ["shell"]
    assert settings.jail == false
    assert settings.effort == "low"
    assert settings.limits.max_steps == 5
    # LIMIT-9: a limit the change didn't name keeps what it had, which is the
    # default (pausing).
    assert settings.limits.pause_on_limit == true

    assert %{settings: ^settings} = Agent.snapshot(id)
    # One change, one event.
    refute_receive {:agent, ^id, {:settings, _}}, 50
  end

  # SESS-41: the typed setters keep their signatures and are the same one path.
  test "the typed setters make the same one change", %{id: id} do
    # MODEL-15: selecting writes the picked model into the settings database as
    # the default, so the scratch one is emptied and put back (LLMCase).
    Elia.LLMCase.reset_settings()
    # VISION-7: a choice asks the provider's catalog, so it is stubbed here.
    Elia.LLMCase.configure(Elia.LLM.OpenRouter)
    Elia.LLMCase.stub_catalog(Elia.LLM.OpenRouter)
    :ok = Agent.set_jail(id, false)
    assert_receive {:agent, ^id, {:settings, %{jail: false}}}

    {:ok, selection} = Agent.select_model(id, "openrouter", "vendor/m", "Vendor M")
    assert_receive {:agent, ^id, {:settings, %{model: ^selection, jail: false}}}

    :ok = Agent.set_effort(id, "low")
    assert_receive {:agent, ^id, {:settings, %{effort: "low"}}}

    :ok = Agent.set_limits(id, %{max_steps: 3})
    assert_receive {:agent, ^id, {:settings, %{limits: %{max_steps: 3}}}}

    :ok = Agent.set_auto_approve(id, "shell", true)
    assert_receive {:agent, ^id, {:settings, %{auto_approve: ["shell"]}}}
  end

  # SESS-42: a key the one path doesn't know is refused, and nothing changes.
  test "an unknown setting is refused and changes nothing", %{id: id} do
    assert {:error, message} = Agent.set_settings(id, %{temperature: 0.5})
    assert message =~ "temperature"

    assert %{settings: %{jail: true}} = Agent.snapshot(id)
    refute_receive {:agent, ^id, {:settings, _}}
  end

  # SESS-42: one bad value rejects the whole change — the keys that were fine
  # with it too.
  test "one bad value rejects the whole change", %{id: id} do
    assert {:error, message} = Agent.set_settings(id, %{jail: false, effort: "very high"})
    assert message =~ "low, medium or high"

    assert %{settings: %{jail: true, effort: nil}} = Agent.snapshot(id)
    refute_receive {:agent, ^id, {:settings, _}}
  end

  # SESS-42: each of the five is checked by the rule of its own requirement
  # (MODEL-1, APPR-13, ISOL-16, LIMIT-7, LLM-39).
  test "each setting's own rule is what a change is checked against", %{id: id} do
    assert {:error, message} = Agent.set_settings(id, %{model: "vendor/m"})
    assert message =~ "model"

    assert {:error, message} = Agent.set_settings(id, %{auto_approve: %{"reload_skills" => true}})
    assert message =~ "reload_skills"

    assert {:error, message} = Agent.set_settings(id, %{jail: "off"})
    assert message =~ "jail"

    assert {:error, message} = Agent.set_settings(id, %{limits: %{max_steps: 0}})
    assert message =~ "step limit"

    assert {:error, message} = Agent.set_settings(id, %{effort: "medium-ish"})
    assert message =~ "low, medium or high"

    # APPR-13: a name can always be turned off, and one that can need approval
    # can be turned on.
    assert :ok = Agent.set_settings(id, %{auto_approve: %{"reload_skills" => false}})
    assert_receive {:agent, ^id, {:settings, %{auto_approve: []}}}
  end

  # SESS-41, STORE-1, STORE-14, STORE-25, STORE-27, STORE-37: one change of a
  # chat with messages is saved with it, each key by its own rule.
  test "one change is saved with the chat", %{id: id} do
    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))
    :ok = Agent.send_message(id, "hello")
    await_status(id, :idle)

    assert :ok =
             Agent.set_settings(id, %{
               jail: false,
               effort: "low",
               limits: %{max_steps: 4},
               auto_approve: %{"shell" => true}
             })

    assert Elia.Store.load_jail(id) == false
    assert Elia.Store.load_effort(id) == "low"
    assert Elia.Store.load_limits(id).max_steps == 4
    assert Elia.Store.load_auto_approve(id) == ["shell"]
  end

  # SNAP-6, SNAP-8: the pair of snapshots bracketing a `shell` call rides on that
  # call's own tool result, which the chat saves (SNAP-7), while what the model is
  # sent stays the command's output and exit status.
  test "a shell call's snapshot pair rides on its tool result" do
    tree = Elia.LiveTree.create()
    on_exit(fn -> Elia.LiveTree.remove(tree) end)
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, workspace: tree, auto_approve: ["shell"])
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "shell", %{"command" => "echo made > made.txt"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Made it.")]))

    :ok = Agent.send_message(id, "make a file")
    await_status(id, :idle)

    assert [_, _, %Message{role: :tool, content: [result]}, _] = Agent.snapshot(id).messages
    assert %{snapshot: %{from: from, to: to, files: files}} = result
    assert from =~ "refs/elia/snapshots/"
    assert to =~ "refs/elia/snapshots/"
    assert %{status: "added", path: "made.txt"} in files
    assert result.content =~ "[exit: 0]"

    # SNAP-8: what the model is sent is the command's output and exit status,
    # with nothing of the pair on it, whichever provider encodes it — the pair
    # lives on the chat's own record of the call.
    [_first, second] = FakeLLM.requests()
    assert %Message{role: :tool, content: [sent]} = List.last(second.messages)
    assert sent.content == result.content

    assert Elia.LLM.OpenAI.encode_messages([%Message{role: :tool, content: [sent]}]) ==
             [%{"role" => "tool", "tool_call_id" => "c1", "content" => result.content}]

    refute inspect(Elia.LLM.Anthropic.encode_messages([%Message{role: :tool, content: [sent]}])) =~
             "snapshots"
  end

  # SNAP-9: a chat working outside a git work tree records no pair, and its call
  # runs exactly as it would have without one.
  test "a shell call outside a git work tree records no pair" do
    dir = Path.join(System.tmp_dir!(), "elia-no-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, workspace: dir, auto_approve: ["shell"])
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Said hi.")]))

    :ok = Agent.send_message(id, "say hi")
    await_status(id, :idle)

    assert [_, _, %Message{role: :tool, content: [result]}, _] = Agent.snapshot(id).messages
    refute Map.has_key?(result, :snapshot)
    assert result.content =~ "hi"
  end
end
