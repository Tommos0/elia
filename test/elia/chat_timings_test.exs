defmodule Elia.Skills.ChatTimingsTest do
  # The store is shared state (one sessions dir per run), and these tests save
  # chats and their step records to sum, so they don't run inside one another.
  use ExUnit.Case, async: false

  alias Elia.LLM.Message
  alias Elia.{Projects, StepTiming, Store, Workspace}
  alias Elia.Skills.Chats

  defp tool(name), do: Enum.find(Chats.tools(), &(&1.name == name))

  defp call(input, ctx \\ %{}), do: Elia.Tool.call(tool("chat_timings"), input, ctx)

  defp summary(input, ctx \\ %{}) do
    {:ok, json} = call(input, ctx)
    Jason.decode!(json)
  end

  # A chat of this test's own, with the step records given; both go when it ends
  # (TIME-10).
  defp save(records, opts \\ []) do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("a chat to time")], Keyword.put_new(opts, :title, "Timed"))
    for record <- records, do: :ok = StepTiming.record(id, record)
    id
  end

  # A record as the loop writes one (TIME-2 to TIME-5), with what a test cares
  # about overridden.
  defp record(step, fields) do
    Map.merge(
      %{
        "turn" => "turn-1",
        "turn_started_at" => "2026-01-01T00:00:00Z",
        "step" => step,
        "attempt" => 1,
        "outcome" => "ok",
        "started_at" => "2026-01-01T00:00:00Z",
        "finished_at" => "2026-01-01T00:00:01Z",
        "model_ms" => 100,
        "tool_ms" => 0,
        "approval_wait_ms" => 0,
        "answer_wait_ms" => 0,
        "retry_wait_ms" => 0
      },
      fields
    )
  end

  # A project of this test's own, so a listing holds exactly the chats it saves.
  defp project do
    {:ok, project} = Projects.create("Timings #{Elia.Agent.new_id()}", Workspace.root())
    on_exit(fn -> Projects.delete(project.id) end)
    project
  end

  # TIME-11: the chats skill provides the tool, and says what it reads.
  test "TIME-11 the chats skill provides chat_timings and says what it reads" do
    assert "chat_timings" in Enum.map(Chats.tools(), & &1.name)
    assert Chats.instructions() =~ "`chat_timings`"
    # ISOL-6, ISOL-13: the records live beside the chat in `.elia/sessions`, out
    # of a jailed command's reach, so the tool reads them through the harness as
    # the other chats tools do.
    assert Chats.instructions() =~ "through the harness"
    assert tool("chat_timings").description =~ "step records"
  end

  # TIME-12: one chat by id, and an id that is refused as `read_chat` refuses it
  # (HIST-8).
  test "TIME-12 one chat by id, and the ids it refuses" do
    id = save([record(1, %{"model_ms" => 1000})])

    assert %{"chats" => [chat], "total" => %{"chats" => 1}} = summary(%{"id" => id})
    assert chat["id"] == id
    assert chat["model_ms"] == 1000

    assert {:error, message} = call(%{"id" => "not an id"})
    assert message =~ "not a valid chat id"

    assert {:error, message} = call(%{"id" => "no-such-chat"})
    assert message =~ "No saved chat"

    # HIST-11: a chat of another project is refused ...
    elsewhere = project()
    theirs = save([record(1, %{"model_ms" => 500})], project: elsewhere.id)

    assert {:error, message} = call(%{"id" => theirs})
    assert message =~ "another project"

    # ... and is the chat its own project's chats read.
    assert %{"chats" => [%{"id" => ^theirs, "model_ms" => 500}]} =
             summary(%{"id" => theirs}, %{project: elsewhere})
  end

  # TIME-12: a listing is the newest chats of the project that have records, 5
  # by default and at most 20 (TIME-17: a chat with no records is left out).
  test "TIME-12 a listing is the newest chats with records, 5 by default and at most 20" do
    project = project()
    ctx = %{project: project}

    ids = for n <- 1..21, do: save([record(1, %{"model_ms" => n})], project: project.id)
    untimed = save([], project: project.id)
    newest_first = Enum.reverse(ids)

    assert %{"chats" => five, "total" => %{"chats" => 5}} = summary(%{}, ctx)
    assert Enum.map(five, & &1["id"]) == Enum.take(newest_first, 5)
    refute Enum.any?(five, &(&1["id"] == untimed))

    assert %{"chats" => twenty, "total" => %{"chats" => 20}} = summary(%{"limit" => 100}, ctx)
    assert Enum.map(twenty, & &1["id"]) == Enum.take(newest_first, 20)
    refute Enum.any?(twenty, &(&1["id"] == untimed))
  end

  # TIME-13, TIME-14: a chat's figures come from its records and nothing else.
  test "TIME-13, TIME-14 a chat's figures are its records summed" do
    id =
      save([
        record(1, %{
          "model_ms" => 1000,
          "tool_ms" => 500,
          "approval_wait_ms" => 200,
          "input_tokens" => 100,
          "output_tokens" => 10
        }),
        record(2, %{
          "model_ms" => 2000,
          "answer_wait_ms" => 300,
          "input_tokens" => 200,
          "output_tokens" => 20
        }),
        record(3, %{"attempt" => 2, "model_ms" => 500, "retry_wait_ms" => 60}),
        record(4, %{"outcome" => "error", "model_ms" => 100}),
        record(5, %{"outcome" => "refused", "model_ms" => 50})
      ])

    assert %{"chats" => [chat]} = summary(%{"id" => id})

    assert chat["steps"] == 5
    assert chat["model_ms"] == 3650
    assert chat["tool_ms"] == 500
    assert chat["approval_wait_ms"] == 200
    assert chat["answer_wait_ms"] == 300
    assert chat["retry_wait_ms"] == 60
    # TIME-13: the waiting is a figure of its own beside the work it delayed.
    assert chat["waited_ms"] == 560
    # TIME-14: a retried step, a step that failed and one that was refused.
    assert chat["failed_or_retried"] == 3
    assert chat["input_tokens"] == 300
    assert chat["output_tokens"] == 30
  end

  # TIME-15: the result names each chat and totals the figures over all of them.
  test "TIME-15 the total sums every record of every chat reported" do
    project = project()
    ctx = %{project: project}

    older = save([record(1, %{"model_ms" => 1000})], project: project.id, title: "Older")
    newer = save([record(1, %{"model_ms" => 250, "input_tokens" => 5})], project: project.id)

    assert %{"chats" => [newest, then], "total" => total} = summary(%{}, ctx)
    assert newest["id"] == newer
    assert newest["title"] == "Timed"
    assert then["id"] == older
    assert then["title"] == "Older"

    assert total == %{
             "chats" => 2,
             "steps" => 2,
             "model_ms" => 1250,
             "tool_ms" => 0,
             "approval_wait_ms" => 0,
             "answer_wait_ms" => 0,
             "retry_wait_ms" => 0,
             "waited_ms" => 0,
             "failed_or_retried" => 0,
             "input_tokens" => 5
           }
  end

  # TIME-16: the tool reads and changes nothing, and never needs approval
  # (HIST-10).
  test "TIME-16 chat_timings reads and changes nothing and never needs approval" do
    id = save([record(1, %{"model_ms" => 1000})])
    chat = Path.join(Store.dir(), id <> ".term")
    records = StepTiming.path(id)
    before = {File.read!(chat), File.read!(records)}

    assert Elia.Tool.approval(tool("chat_timings"), %{}, %{}) == :never

    assert {:ok, _} = call(%{"id" => id})
    assert {:ok, _} = call(%{})

    # No session is started for a chat it reads (SESS-14), and neither the saved
    # chat nor the records are touched: no record is written either.
    refute Elia.Agent.live?(id)
    assert {File.read!(chat), File.read!(records)} == before
  end

  # TIME-17: a chat with no records is reported as having none, not as an error.
  test "TIME-17 a chat with no records is reported with no steps" do
    id = save([])

    assert %{"chats" => [chat], "total" => total} = summary(%{"id" => id})

    assert chat["id"] == id
    assert chat["steps"] == 0
    assert chat["model_ms"] == 0
    assert chat["waited_ms"] == 0
    assert chat["failed_or_retried"] == 0
    refute Map.has_key?(chat, "input_tokens")
    refute Map.has_key?(chat, "output_tokens")

    assert total["chats"] == 1
    assert total["steps"] == 0
  end

  # TIME-18: one unreadable line never fails a summary.
  test "TIME-18 a line that isn't a record is skipped, and a field that isn't a whole number is zero" do
    id = save([])

    File.write!(StepTiming.path(id), """
    not a record at all
    {"step": 1, "model_ms": "lots", "tool_ms": 100, "input_tokens": "many"}
    {"step": 2, "model_ms": 200, "input_tokens": 7}
    """)

    assert %{"chats" => [chat]} = summary(%{"id" => id})

    assert chat["steps"] == 2
    assert chat["model_ms"] == 200
    assert chat["tool_ms"] == 100
    assert chat["input_tokens"] == 7
    refute Map.has_key?(chat, "output_tokens")
  end
end
