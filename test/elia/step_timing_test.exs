defmodule Elia.StepTimingTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, StepTiming, Store}
  alias Elia.LLM.{Error, Message}

  # TIME-1 to TIME-10: each loop step is recorded beside its chat — when it
  # happened, how long it took, where that time went and what the provider said
  # it cost.
  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  defp start_chat(opts \\ []) do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id, opts)
    Agent.subscribe(id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
      Store.delete(id)
    end)

    id
  end

  defp await_status(id, status) do
    assert_receive {:agent, ^id, {:status, ^status}}, 5000
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, data} -> data |> String.split("\n", trim: true)
      _error -> []
    end
  end

  # TIME-7: the file as it stands while the turn is still running.
  defp await_lines(path, count, tries \\ 200) do
    case lines(path) do
      lines when length(lines) >= count -> lines
      _fewer when tries > 0 -> Process.sleep(5) && await_lines(path, count, tries - 1)
      lines -> lines
    end
  end

  defp transient_failure do
    fn _request, _on_event ->
      {:error, Error.transient("Anthropic API request failed: timeout")}
    end
  end

  defp reply(text), do: FakeLLM.assistant([Message.text(text)])

  # TIME-6, TIME-9: one line of JSON per step, read back in order, oldest first.
  test "a step is recorded with its stamps, durations and no tools" do
    id = start_chat()

    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(30)
      {:ok, %{message: reply("Hello!"), stop_reason: :end_turn, model: "fake", usage: %{}}}
    end)

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    # TIME-2, TIME-3: what the step was and how long it took.
    assert [record] = StepTiming.load(id)
    assert String.starts_with?(record.turn, id <> "-")
    assert record.step == 1
    assert record.attempt == 1
    assert record.outcome == :ok
    assert %DateTime{} = record.turn_started_at
    assert %DateTime{} = record.started_at
    assert %DateTime{} = record.finished_at
    assert DateTime.compare(record.started_at, record.finished_at) == :lt
    assert record.model_ms >= 25
    assert record.tool_ms == 0
    assert record.approval_wait_ms == 0
    assert record.answer_wait_ms == 0
    assert record.retry_wait_ms == 0
    assert record.tools == []
    # TIME-5: FakeLLM reports no counts, so none are recorded.
    refute Map.has_key?(record, :input_tokens)
    refute Map.has_key?(record, :output_tokens)

    # TIME-6: the record is a line of plain-text JSON with string keys, appended
    # to the chat's own `.timing` file rather than into the saved chat.
    assert File.exists?(StepTiming.path(id))
    assert [line] = lines(StepTiming.path(id))
    assert %{"step" => 1, "outcome" => "ok", "model_ms" => _ms} = Jason.decode!(line)
  end

  # TIME-3, TIME-4: the tools of a step are timed, and the wait for the user's
  # approval is kept apart from the work it delayed.
  test "a step with a tool call times the call, and the approval wait apart from it" do
    id = start_chat(auto_approve: [])

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "shell", %{"command" => "sleep 0.05; echo elia"})
      ])
    )

    FakeLLM.push(reply("It printed elia."))

    :ok = Agent.send_message(id, "run it")
    await_status(id, :awaiting_approval)
    Process.sleep(30)
    :ok = Agent.approve(id, "c1")
    await_status(id, :idle)

    assert [first, second] = StepTiming.load(id)
    assert first.step == 1
    assert second.step == 2
    assert first.approval_wait_ms >= 20
    assert first.tool_ms >= 40
    assert [%{name: "shell", ms: ms, failed: false}] = first.tools
    assert is_integer(ms)
    # The step that only answered has no tools to time.
    assert second.tools == []
    assert second.tool_ms == 0
  end

  # TIME-1, TIME-2: a retried step records both attempts, and the attempt that
  # followed a wait says how long the wait was.
  test "both attempts of a retried step are recorded, and the wait before the retry" do
    id = start_chat(loop_opts: [step_retry: [delays_ms: [60]]])

    FakeLLM.push(transient_failure())
    FakeLLM.push(reply("Recovered."))

    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    assert [failed, retried] = StepTiming.load(id)
    assert failed.step == 1
    assert failed.attempt == 1
    assert failed.outcome == :error
    assert failed.retry_wait_ms == 0
    assert failed.model_ms >= 0

    assert retried.step == 1
    assert retried.attempt == 2
    assert retried.outcome == :ok
    assert retried.retry_wait_ms == 60
  end

  # TIME-1, TIME-2: a request that failed for good is recorded too, and the
  # turn ends with the error as before.
  test "a model call that failed for good is recorded, and the turn ends" do
    id = start_chat(loop_opts: [step_retry: [delays_ms: []]])

    FakeLLM.push(transient_failure())

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:error, _text}}, 5000
    await_status(id, :idle)

    assert [record] = StepTiming.load(id)
    assert record.attempt == 1
    assert record.outcome == :error
  end

  # TIME-2: a refusal is an outcome of its own (LOOP-4).
  test "a refused request is recorded as refused" do
    id = start_chat()

    FakeLLM.push(fn _request, _on_event ->
      {:ok, %{message: FakeLLM.assistant([]), stop_reason: :refusal, model: "fake", usage: %{}}}
    end)

    :ok = Agent.send_message(id, "go")
    await_status(id, :idle)

    assert [record] = StepTiming.load(id)
    assert record.outcome == :refused
  end

  # TIME-5, CTX-6: the counts are the provider's, normalised, so a cached read
  # counts as input on any provider (LLM-1).
  test "the tokens the provider reported are recorded as CTX-6 counts them" do
    id = start_chat()

    FakeLLM.push(fn _request, _on_event ->
      {:ok,
       %{
         message: reply("hi"),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{
           "input_tokens" => 900,
           "output_tokens" => 40,
           "cache_read_input_tokens" => 100
         }
       }}
    end)

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    assert [record] = StepTiming.load(id)
    assert record.input_tokens == 1000
    assert record.output_tokens == 40
  end

  # TIME-7: a record is written when its step finishes, so a turn still running
  # can be watched as it goes.
  test "a step is recorded before the turn it belongs to ends" do
    id = start_chat()
    path = StepTiming.path(id)
    test_pid = self()

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "read_file", %{"path" => "mix.exs"})])
    )

    # The second request is the turn still running: the first step's record is
    # already in the file by the time it is made.
    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:while_running, await_lines(path, 1)})
      {:ok, %{message: reply("Read it."), stop_reason: :end_turn, model: "fake", usage: %{}}}
    end)

    :ok = Agent.send_message(id, "read it")
    await_status(id, :idle)

    assert_receive {:while_running, [line]}
    assert %{"step" => 1} = Jason.decode!(line)
    assert length(lines(path)) == 2
  end

  # TIME-8: nothing is recorded for a chat that never ran a step, and a record
  # that can't be written is dropped without touching the turn.
  test "a chat that never ran a step has no records" do
    id = start_chat()

    refute File.exists?(StepTiming.path(id))
    assert StepTiming.load(id) == []
  end

  test "a record that can't be written is dropped and the turn carries on" do
    id = start_chat()
    # A directory where the file goes: the append fails.
    File.mkdir_p!(StepTiming.path(id))
    on_exit(fn -> File.rmdir!(StepTiming.path(id)) end)

    FakeLLM.push(reply("Hello!"))

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    # The turn ran as if nothing had happened.
    assert [%Message{role: :assistant}] = Agent.snapshot(id).messages |> Enum.drop(1)
    assert StepTiming.load(id) == []
  end

  # TIME-9: an id that isn't a valid chat id, or a chat with no records, reads
  # as no records rather than failing (STORE-4).
  test "reading records of an invalid id gives none" do
    assert StepTiming.load("not an id") == []
    assert StepTiming.load("../etc/passwd") == []
    assert StepTiming.load(nil) == []
  end

  # TIME-10: a chat's records go with the chat, and a `.timing` file is not a
  # chat the list shows or resumes (STORE-12, STORE-29).
  test "records are deleted with their chat and are never a chat" do
    id = start_chat()
    FakeLLM.push(reply("Hello!"))

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    assert StepTiming.load(id) != []

    orphan = "timing#{System.unique_integer([:positive])}"
    :ok = StepTiming.record(orphan, %{turn: "t", step: 1})
    assert File.exists?(StepTiming.path(orphan))
    refute Enum.any?(Store.list(), &(&1.id == orphan))

    :ok = Store.delete(id)
    refute File.exists?(StepTiming.path(id))
    assert StepTiming.load(id) == []
    assert StepTiming.delete(orphan) == :ok
  end
end
