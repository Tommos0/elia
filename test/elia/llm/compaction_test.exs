defmodule Elia.LLM.CompactionTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.{Compaction, Message}

  # A chat of turns `range`: each one a user message and an assistant reply that
  # reasons about it, reads a file and answers. Four messages per turn.
  defp history(range, opts \\ []) do
    text = Keyword.get(opts, :text, "word ")

    Enum.flat_map(Enum.to_list(range), fn n ->
      [
        Message.user("task #{n}: #{String.duplicate(text, 20)}"),
        %Message{
          role: :assistant,
          content: [
            %{type: :reasoning, text: "thinking about task #{n} #{String.duplicate(text, 10)}"},
            %{
              type: :tool_call,
              id: "c#{n}",
              name: "read_file",
              input: %{"path" => "file#{n}.txt"}
            }
          ]
        },
        %Message{
          role: :tool,
          content: [Message.tool_result("c#{n}", String.duplicate("output #{n} ", 50))]
        },
        %Message{role: :assistant, content: [Message.text("done #{n}")]}
      ]
    end)
  end

  defp options(overrides), do: Compaction.options(overrides)

  # A summarizer that never summarizes: the ladder-only tests use it so they
  # never reach a provider (COMPACT-20).
  defp no_summary, do: fn _ -> {:error, :none} end

  ## Options, trigger and target

  # COMPACT-6
  test "the trigger is the lower of the budget and the fraction of the window" do
    opts = options(budget: 150_000, fraction: 0.8)

    assert Compaction.trigger(1_000_000, opts) == 150_000
    assert Compaction.trigger(100_000, opts) == 80_000
  end

  # COMPACT-7
  test "there is no trigger without a known window" do
    assert Compaction.trigger(nil, options(budget: 10)) == nil
    assert Compaction.trigger(0, options(budget: 10)) == nil
  end

  # COMPACT-8
  test "the target is half the trigger" do
    assert Compaction.target(100_000, options(budget: 150_000, fraction: 0.8)) == 40_000
    assert Compaction.target(1_000_000, options(budget: 100_000)) == 50_000
  end

  # COMPACT-9
  test "the per-chat options override the defaults" do
    opts = options(budget: 300, working_set: 2, user_cap: 5)

    assert opts.budget == 300
    assert opts.working_set == 2
    assert opts.user_cap == 5
    # The defaults are still there.
    assert opts.fraction == 0.8
    assert Compaction.trigger(1000, opts) == 300
  end

  # COMPACT-9
  test "a chat state's own options apply to its derivation" do
    messages = [Message.user("first"), Message.user(String.duplicate("x", 4000))]
    view = Compaction.view(messages, %Compaction{options: %{user_cap: 5}})

    assert view.statuses[1].status == :truncated
  end

  ## The request view

  # COMPACT-2, COMPACT-3
  test "an uncompacted chat's view is its history, unchanged and deterministic" do
    messages = history(1..3)
    state = %Compaction{}

    view = Compaction.view(messages, state)

    assert view.messages == messages
    assert view.elided == 0
    assert view.head == 0
    assert view.messages == Compaction.view(messages, state).messages
  end

  # COMPACT-1, COMPACT-2
  test "the full history is never touched by deriving a view" do
    messages = history(1..4)
    before = messages

    messages
    |> Compaction.compact(%Compaction{}, target: 1, working_set: 2, summarizer: no_summary())
    |> then(&Compaction.view(messages, &1))

    assert messages == before
  end

  # COMPACT-12
  test "the working set of recent turns is kept verbatim" do
    messages = history(1..4)

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: no_summary()
      )

    view = Compaction.view(messages, state)

    # Two turns of the four are the working set: indices 8..15.
    assert state.level == 3
    assert state.covered == 8
    assert Enum.slice(view.messages, -8, 8) == Enum.slice(messages, 8, 8)
    assert Enum.all?(8..15, &(view.statuses[&1].status == :sent))
  end

  ## Boundary safety

  # COMPACT-4
  test "a tool call and its result are kept or dropped together" do
    messages = history(1..4)

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: no_summary()
      )

    view = Compaction.view(messages, state)

    ids =
      for %Message{role: :assistant, content: content} <- view.messages,
          call <- content,
          call.type == :tool_call,
          do: call.id

    results =
      for %Message{role: :tool, content: content} <- view.messages,
          result <- content,
          do: result.tool_call_id

    assert Enum.sort(ids) == Enum.sort(results)
    assert ids == ["c3", "c4"]
  end

  # COMPACT-4, COMPACT-11
  test "the view keeps the spoken record and starts as a user turn" do
    messages = history(1..5)

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: no_summary()
      )

    view = Compaction.view(messages, state)

    users =
      for %Message{role: :user} = m <- view.messages, not Map.get(m.meta, :harness, false), do: m

    # COMPACT-11: every user message survives, whatever its age.
    assert length(users) == 5
    assert Message.text_content(hd(users)) == Message.text_content(hd(messages))
  end

  # COMPACT-4
  test "provider raw blocks are sent byte-for-byte or dropped whole" do
    raw = %{"type" => "thinking", "thinking" => "…", "signature" => "abc"}

    messages = [
      Message.user("go"),
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: "hm", raw: {:provider, raw}},
          %{type: :text, text: "old answer", raw: {:provider, %{"type" => "text"}}}
        ]
      },
      Message.user("again"),
      %Message{role: :assistant, content: [Message.text("new answer")]}
    ]

    # Fresh region: nothing is rewritten.
    view = Compaction.view(messages, %Compaction{})
    assert [reasoning | _] = Enum.at(view.messages, 1).content
    assert reasoning.raw == {:provider, raw}

    # Cold and at the top of the ladder: the whole message goes, raw included.
    view = Compaction.view(messages, %Compaction{level: 3, covered: 2})

    refute Enum.any?(
             view.messages,
             &(&1.role == :assistant and Message.text_content(&1) == "old answer")
           )

    assert view.statuses[1].status == :elided
  end

  ## The ladder

  # COMPACT-14
  test "reasoning in the cold prefix is dropped first" do
    messages = history(1..3)
    view = Compaction.view(messages, %Compaction{level: 1, covered: 4})

    reasonings =
      for %Message{role: :assistant, content: content} <- view.messages,
          block <- content,
          block.type == :reasoning,
          do: block

    # Turn 1 is cold (indices 0..3); its reasoning is gone.
    assert length(reasonings) == 2
    assert view.statuses[1].status == :truncated
    assert view.statuses[1].blocks[0] == :elided
    assert view.statuses[1].blocks[1] == :sent
    # The text the human reads is untouched.
    assert view.statuses[0].status == :sent
  end

  # COMPACT-15
  test "old tool results are elided to a note naming the call" do
    messages = history(1..3)
    view = Compaction.view(messages, %Compaction{level: 2, covered: 4})

    [%Message{role: :tool, content: [result]} | _] =
      Enum.filter(view.messages, &(&1.role == :tool))

    assert result.content =~ "output elided by compaction"
    assert result.content =~ "read_file"
    assert result.content =~ "file1.txt"
    assert view.statuses[2].status == :truncated
    assert view.statuses[2].blocks[0] == :elided
    assert view.elided > 0
    # The call input is not elided on its own (COMPACT-15).
    assert [%{type: :tool_call, input: %{"path" => "file1.txt"}} | _] =
             Enum.at(view.messages, view.head + 1).content
  end

  # COMPACT-16
  test "whole old turns are dropped, oldest first" do
    messages = history(1..4)
    view = Compaction.view(messages, %Compaction{level: 3, covered: 8})

    assert Message.text_content(Enum.at(view.messages, view.head)) =~ "task 1"
    assert Enum.all?(1..3, &(view.statuses[&1].status == :elided))
    refute Enum.any?(view.messages, &(Message.text_content(&1) == "done 1"))

    # The summary-less marker names the amount (COMPACT-23).
    assert [%Message{role: :user, meta: %{compaction: :marker}} | _] = view.messages
    assert Message.text_content(hd(view.messages)) =~ "Context compacted"
  end

  # COMPACT-11, COMPACT-13
  test "a huge user message is truncated with a marker, and the first one never is" do
    long = String.duplicate("x", 10_000)
    messages = [Message.user(long), Message.user("middle"), Message.user(long)]

    view = Compaction.view(messages, %Compaction{}, %{user_cap: 100})

    # The first message (the task statement) is kept whole.
    assert Message.text_content(Enum.at(view.messages, view.head)) == long
    # The later one is cut to the cap (100 tokens ≈ 400 characters) with a marker.
    cut = Message.text_content(Enum.at(view.messages, view.head + 2))
    assert cut =~ "were cut"
    assert String.length(cut) < String.length(long)
    assert view.statuses[2].status == :truncated
    assert view.statuses[2].elided > 0
  end

  ## Summaries

  # COMPACT-17
  test "the cold prefix is summarized only when the ladder cannot reach the target" do
    messages = history(1..4)
    full = Compaction.view(messages, %Compaction{}).tokens

    reached =
      Compaction.compact(messages, %Compaction{},
        target: full,
        working_set: 2,
        summarizer: fn _ -> flunk("the summarizer must not be called") end
      )

    assert reached.level == 0
    assert reached.summary == nil
    assert reached.folded == 0

    # With an unreachable target it goes all the way and summarizes.
    unreachable =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: fn _ -> {:ok, "They did four tasks."} end
      )

    assert unreachable.level == 3
    assert unreachable.summary == "They did four tasks."
    assert unreachable.covered == 8
    assert unreachable.folded == 8
  end

  # COMPACT-18
  test "the summary is folded from the previous summary plus newly aged-out turns" do
    test_pid = self()
    summarizer = fn input -> send(test_pid, {:summary_input, input}) && {:ok, "folded"} end

    messages = history(1..4)

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: summarizer
      )

    assert_receive {:summary_input, first}
    assert first =~ "task 1"
    assert first =~ "done 2"
    refute first =~ "task 3"
    assert state.folded == 8

    # Growing the chat folds again: the second input carries the first summary
    # and only the turns that aged out since, never the whole history.
    later = history(1..6)

    state =
      Compaction.compact(later, state, target: 1, working_set: 2, summarizer: summarizer)

    assert_receive {:summary_input, second}
    assert second =~ "The summary so far:"
    assert second =~ "folded"
    refute second =~ "task 1:"
    assert second =~ "task 3"
    assert state.summary == "folded"
    assert state.folded == 16

    # A third fold with nothing new does not call the summarizer at all.
    state = Compaction.compact(later, state, target: 1, working_set: 2, summarizer: summarizer)
    refute_received {:summary_input, _}
    assert state.folded == 16
  end

  # COMPACT-18, COMPACT-19
  test "the summary is a harness message at the head of the view" do
    messages = history(1..3)
    state = %Compaction{level: 3, covered: 8, folded: 8, summary: "They read three files."}
    view = Compaction.view(messages, state)

    assert [%Message{role: :user, meta: %{harness: true, compaction: :summary}} = head | _] =
             view.messages

    assert Message.text_content(head) =~ "They read three files."
    # The head is not a turn of its own: it doesn't become a working-set boundary.
    assert Compaction.working_set_start(messages, 2) == 4
    assert Compaction.summary_block(state) == {8, "They read three files."}
  end

  # COMPACT-17, COMPACT-19
  test "dropped turns covered by a summary are annotated as summarized" do
    messages = history(1..3)
    state = %Compaction{level: 3, covered: 4, folded: 4, summary: "Turn one read file1.txt."}
    view = Compaction.view(messages, state)

    assert view.statuses[1].status == :summarized
    assert view.statuses[3].status == :summarized
  end

  # COMPACT-20
  test "a failing summarizer falls back to the pruned view with no error" do
    messages = history(1..3)

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 2,
        summarizer: fn _ -> {:error, :boom} end
      )

    assert state.level == 3
    assert state.summary == nil
    view = Compaction.view(messages, state)
    assert view.statuses[1].status == :elided
    assert Message.text_content(hd(view.messages)) =~ "Context compacted"
  end

  # COMPACT-20
  test "the summarizer is injectable and there is a default one" do
    assert is_function(Compaction.default_summarizer(%{provider: __MODULE__}), 1)
    assert is_function(Compaction.default_summarizer(), 1)
  end

  ## Pins and the ledger

  # COMPACT-21
  test "a pinned message is never elided" do
    messages = history(1..3)
    view = Compaction.view(messages, %Compaction{level: 3, covered: 4, pins: [{2, nil}]})

    assert %Message{role: :tool, content: [%{content: content}]} =
             Enum.find(view.messages, &(&1.role == :tool))

    assert content =~ "output 1"
    assert view.statuses[2].pinned
    assert view.statuses[2].status == :sent
  end

  # COMPACT-21, COMPACT-4
  test "a pinned block survives, with its message and the call it answers" do
    messages = history(1..3)
    view = Compaction.view(messages, %Compaction{level: 3, covered: 4, pins: [{2, 0}]})

    assert [%{content: content}] = Enum.find(view.messages, &(&1.role == :tool)).content
    assert content =~ "output 1"

    assert Enum.any?(view.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c1"))

             _ ->
               false
           end)

    # The rest of that turn is still dropped: only the pair is kept.
    assert view.statuses[3].status == :elided
  end

  # COMPACT-21
  test "pinning and unpinning round-trip" do
    state = %Compaction{}

    assert Compaction.pin(state, 3).pins == [{3, nil}]
    assert Compaction.pin(state, 3, 1).pins == [{3, 1}]

    assert state |> Compaction.pin(3, 1) |> Compaction.unpin(3, 1) |> Map.fetch!(:pins) == []

    state = Compaction.pin(%Compaction{}, 2, 0)
    assert Compaction.pinned?(state, 2, 0)
    refute Compaction.pinned?(state, 2, 1)

    # Pinning a whole message pins its blocks too.
    assert Compaction.pinned?(Compaction.pin(%Compaction{}, 2), 2, 1)
  end

  # COMPACT-22
  test "the ledger is append-and-trim only and is sent verbatim" do
    state = Compaction.add_ledger(%Compaction{}, ["path: lib/elia/llm/compaction.ex"])
    state = Compaction.add_ledger(state, "COMPACT-22 is implemented")

    assert state.ledger == ["path: lib/elia/llm/compaction.ex", "COMPACT-22 is implemented"]
    assert Compaction.add_ledger(%Compaction{}, ["  "]).ledger == []

    view = Compaction.view(history(1..2), %{state | level: 1, covered: 4})
    ledger = Enum.find(view.messages, &(&1.meta[:compaction] == :ledger))

    assert Message.text_content(ledger) =~ "COMPACT-22 is implemented"
    assert Message.text_content(ledger) =~ "lib/elia/llm/compaction.ex"
  end

  # COMPACT-22
  test "the ledger is trimmed, not re-summarized, past its cap" do
    state = Enum.reduce(1..300, %Compaction{}, &Compaction.add_ledger(&2, "entry #{&1}"))

    assert length(state.ledger) <= 200
    assert List.last(state.ledger) == "entry 300"
  end

  # COMPACT-23
  test "the marker names the elided amount and tells the model to re-read" do
    view = Compaction.view(history(1..3), %Compaction{level: 2, covered: 4})

    assert [%Message{meta: %{compaction: :marker}} = marker] = Enum.take(view.messages, 1)
    assert Message.text_content(marker) =~ "#{view.elided} tokens"
    assert Message.text_content(marker) =~ "Re-read files and re-run commands"
  end

  # COMPACT-25
  test "a single message's status matches the view's" do
    messages = history(1..3)
    state = %Compaction{level: 2, covered: 4}
    view = Compaction.view(messages, state)
    calls = Compaction.calls(messages)

    for index <- 0..(length(messages) - 1) do
      assert Compaction.status(Enum.at(messages, index), index, state, %{calls: calls}) ==
               view.statuses[index]
    end
  end

  ## State

  # COMPACT-24
  test "the state round-trips through a plain map" do
    state = %Compaction{
      level: 2,
      covered: 8,
      folded: 6,
      summary: "so far",
      ledger: ["a"],
      pins: [{1, 0}],
      options: %{budget: 10}
    }

    map = Compaction.to_map(state)
    assert map.level == 2
    refute Compaction.empty?(state)
    assert Compaction.from_map(map) == state
    assert Compaction.from_map(nil) == %Compaction{}
    assert Compaction.from_map(%{level: 9}).level == 3
    assert Compaction.empty?(%Compaction{})
  end
end
