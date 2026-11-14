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

  # One turn of a chat, sized by `text`: a user message, a reasoning block and a
  # tool call, the tool's result, and a reply. Four messages per turn, as in
  # `history/2`, so turn `n` starts at index `(n - 1) * 4`.
  defp turn(n, text) do
    [
      Message.user("task #{n}: #{text}"),
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: text},
          %{
            type: :tool_call,
            id: "c#{n}",
            name: "read_file",
            input: %{"path" => "file#{n}.txt"}
          }
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("c#{n}", text)]},
      %Message{role: :assistant, content: [Message.text("done #{n}")]}
    ]
  end

  defp turn_tokens(messages, n), do: Compaction.tokens(Enum.slice(messages, (n - 1) * 4, 4))

  # One step of the turn being run: an assistant message that reasons about the
  # work and calls a tool, and the tool's result. Two messages, so a turn of
  # `k` steps ends with the result of step `k`.
  defp step(n, k, text) do
    [
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: "thinking #{n}.#{k} #{String.duplicate(text, 10)}"},
          %{
            type: :tool_call,
            id: "c#{n}-#{k}",
            name: "read_file",
            input: %{"path" => "file#{n}-#{k}.txt"}
          }
        ]
      },
      %Message{
        role: :tool,
        content: [
          Message.tool_result("c#{n}-#{k}", "output #{n}.#{k} #{String.duplicate(text, 50)}")
        ]
      }
    ]
  end

  # A turn being run at the start of its next step: its user message, then
  # `steps` steps, so the last one is its most recent step (COMPACT-32). Message
  # `2k` is step `k`'s assistant message and `2k + 1` its result.
  defp running_turn(n, steps, text) do
    [Message.user("task #{n}: #{String.duplicate(text, 20)}")] ++
      Enum.flat_map(1..steps, &step(n, &1, text))
  end

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

  # COMPACT-6, COMPACT-28: the shipped defaults, which `options/1` merges the app
  # config and a chat's own overrides under. A chat stops at 100,000 tokens or
  # 60% of its window, whichever is lower, and its working set is a quarter of
  # that budget, so the ladder still has room to reach the target (COMPACT-8).
  test "the shipped defaults are a 100,000 budget, 60% of the window and a 25,000 working set" do
    opts = Compaction.options()

    assert opts.budget == 100_000
    assert opts.fraction == 0.6
    assert opts.working_set_tokens == 25_000

    # A 200k model: 60% would be 120,000, so the budget binds.
    assert Compaction.trigger(200_000, opts) == 100_000
    # A small window: the fraction binds.
    assert Compaction.trigger(100_000, opts) == 60_000
    # A large window cannot lift the ceiling above the budget.
    assert Compaction.trigger(1_000_000, opts) == 100_000
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
    assert opts.fraction == 0.6
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

  ## The size-bounded working set (COMPACT-28)

  # COMPACT-12, COMPACT-28
  test "short turns still keep the last `working_set` turns" do
    messages = Enum.flat_map(1..10, &turn(&1, "word "))

    # Ten short turns are far below the token cap, so the turn count decides.
    assert Compaction.tokens(messages) < 40_000
    assert Compaction.working_set_start(messages, %{working_set: 6}) == 16

    state =
      Compaction.compact(messages, %Compaction{}, target: 1, summarizer: no_summary())

    view = Compaction.view(messages, state)
    assert state.covered == 16
    assert Enum.all?(16..39, &(view.statuses[&1].status == :sent))
    assert view.statuses[1].status == :elided
  end

  # COMPACT-28
  test "a long recent turn ages the older turns out of the working set" do
    # Turn 3 is huge, turns 1 and 2 are small. With the turn count alone every
    # turn is in the working set, so nothing can be compacted at all.
    messages =
      turn(1, "word ") ++ turn(2, "word ") ++ turn(3, String.duplicate("big ", 6_000))

    [t1, t2, t3] = for n <- 1..3, do: turn_tokens(messages, n)
    assert Compaction.working_set_start(messages, %{working_set: 10}) == 0

    # A budget that fits turns 2 and 3 but not turn 1 keeps only those: the cold
    # prefix is turn 1 alone.
    budget = t2 + t3
    assert t1 + t2 + t3 > budget

    assert Compaction.working_set_start(messages, %{
             working_set: 10,
             working_set_tokens: budget
           }) == 4

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set: 10,
        working_set_tokens: budget,
        summarizer: no_summary()
      )

    view = Compaction.view(messages, state)
    assert state.covered == 4
    assert view.statuses[1].status == :elided
    assert view.statuses[4].status == :sent
    assert view.statuses[8].status == :sent
  end

  # COMPACT-28
  test "a turn bigger than the budget is never cold" do
    # One huge turn is the current one, so the working set is still all of it.
    huge = turn(1, String.duplicate("huge ", 20_000))
    assert Compaction.tokens(huge) > 40_000
    assert Compaction.working_set_start(huge, %{}) == 0
    assert Compaction.view(huge, %Compaction{}).tokens == Compaction.tokens(huge)

    # Two turns: the budget keeps the current turn alone, however big it is.
    messages = turn(1, "word ") ++ turn(2, String.duplicate("huge ", 20_000))

    assert Compaction.working_set_start(messages, %{working_set_tokens: 1}) == 4

    state =
      Compaction.compact(messages, %Compaction{},
        target: 1,
        working_set_tokens: 1,
        summarizer: no_summary()
      )

    view = Compaction.view(messages, state)
    assert state.covered == 4

    # Nothing of the current turn is elided: it is the working set, however big
    # it is. (Its user message is still subject to the COMPACT-11 cap.)
    refute Enum.any?(4..7, &(view.statuses[&1].status == :elided))
    assert Enum.all?(5..7, &(view.statuses[&1].status == :sent))
  end

  # COMPACT-4, COMPACT-28
  test "the sized working set still starts at a user message" do
    messages = turn(1, "word ") ++ turn(2, "word ")
    t2 = turn_tokens(messages, 2)

    start = Compaction.working_set_start(messages, %{working_set_tokens: t2})
    assert start == 4
    assert %Message{role: :user} = Enum.at(messages, start)

    # A harness message at the head of a view (COMPACT-19) is not a turn start:
    # the boundary is the user message that begins the turn.
    harness = Message.harness("earlier context")
    shifted = [harness | messages]

    assert Compaction.working_set_start(shifted, %{working_set_tokens: t2}) == 5
    assert %Message{role: :user, meta: %{harness: true}} = Enum.at(shifted, 0)
  end

  # COMPACT-9, COMPACT-28
  test "the token cap on the working set is an option" do
    assert options(%{}).working_set_tokens == 25_000
    assert options(working_set_tokens: 123).working_set_tokens == 123
    # The turn count is still there.
    assert options(working_set_tokens: 123).working_set == 6

    # A chat state's own option applies to its derivation (COMPACT-9).
    messages = turn(1, "word ") ++ turn(2, "word ")

    state =
      Compaction.compact(messages, %Compaction{options: %{working_set_tokens: 1}},
        target: 1,
        summarizer: no_summary()
      )

    assert state.covered == 4
  end

  ## Boundary safety

  # COMPACT-4, LLM-33
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
    assert Compaction.working_set_start(messages, %{working_set: 2}) == 4
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

  ## The mid-turn pass (COMPACT-29)

  # A summarizer that fails the test if a mid-turn pass ever reaches for one
  # (COMPACT-29: elision only).
  defp no_mid_turn_summary, do: fn _ -> flunk("a mid-turn pass is elision only") end

  # Four turns whose reasoning and tool results outweigh the elision marker the
  # view carries (COMPACT-23), so each rung of the ladder shrinks it.
  defp bulky_history, do: history(1..4, text: String.duplicate("w ", 20))

  # COMPACT-29
  test "trim changes nothing while the estimate is at or under the trigger" do
    messages = history(1..4)
    state = %Compaction{}
    overhead = 50
    tokens = Compaction.view(messages, state).tokens

    opts = %{
      target: 1,
      overhead: overhead,
      working_set: 2,
      summarizer: no_mid_turn_summary()
    }

    # At the trigger, under it, and without a known trigger: nothing changes.
    assert Compaction.trim(messages, state, Map.put(opts, :trigger, tokens + overhead)) == state

    assert Compaction.trim(messages, state, Map.put(opts, :trigger, tokens + overhead - 1)) !=
             state

    assert Compaction.trim(messages, state, Map.put(opts, :trigger, nil)) == state
    assert Compaction.trim(messages, state, Map.delete(opts, :trigger)) == state
  end

  # COMPACT-29
  test "trim elides the cold prefix down the ladder, but never summarizes" do
    messages = bulky_history()
    state = %Compaction{}
    covered = Compaction.working_set_start(messages, %{working_set: 2})
    assert covered == 8

    trimmed =
      Compaction.trim(messages, state, %{
        trigger: 1,
        target: 1,
        overhead: 0,
        working_set: 2,
        summarizer: no_mid_turn_summary()
      })

    assert trimmed.covered == 8
    assert trimmed.level == 3
    # No model call: the state carries no summary (COMPACT-17, COMPACT-20).
    assert trimmed.summary == nil
    assert trimmed.folded == 0

    view = Compaction.view(messages, trimmed)
    assert view.elided > 0
    # The spoken record survives the elision (COMPACT-11).
    assert Enum.any?(view.messages, &(Message.text_content(&1) =~ "task 1"))
  end

  # COMPACT-29
  test "trim stops as soon as the estimate reaches the target" do
    messages = bulky_history()
    covered = Compaction.working_set_start(messages, %{working_set: 2})

    at = fn level ->
      Compaction.view(messages, %Compaction{level: level, covered: covered}).tokens
    end

    # Level 1 (reasoning dropped from the cold prefix) is already enough, so the
    # ladder stops there rather than eliding results or whole turns too.
    assert at.(0) > at.(1)

    trimmed =
      Compaction.trim(messages, %Compaction{}, %{
        trigger: 1,
        target: at.(1),
        overhead: 0,
        working_set: 2
      })

    assert trimmed.level == 1
    assert Compaction.view(messages, trimmed).tokens <= at.(1)
  end

  # COMPACT-29
  test "trim advances the level no further than the target requires" do
    messages = bulky_history()
    covered = Compaction.working_set_start(messages, %{working_set: 2})

    at = fn level ->
      Compaction.view(messages, %Compaction{level: level, covered: covered}).tokens
    end

    # A target the level-2 view meets but the level-1 view does not.
    assert at.(1) > at.(2)

    trimmed =
      Compaction.trim(messages, %Compaction{}, %{
        trigger: 1,
        target: at.(2),
        overhead: 0,
        working_set: 2
      })

    assert trimmed.level == 2
    assert Compaction.view(messages, trimmed).tokens <= at.(2)
  end

  # COMPACT-4, COMPACT-5, COMPACT-29, COMPACT-31, COMPACT-32, COMPACT-33
  test "trim makes the turn being run cold up to its most recent step" do
    huge = String.duplicate("huge ", 20_000)
    # The current turn alone is bigger than the working set budget, so it is all
    # of the working set (COMPACT-28) — and the rung inside it is what bounds it
    # (COMPACT-31).
    messages = turn(1, "word ") ++ turn(2, huge)

    trimmed = Compaction.trim(messages, %Compaction{}, %{trigger: 1, target: 1})
    view = Compaction.view(messages, trimmed)

    assert trimmed.covered == 4
    # The boundary the pass elided to is the turn's most recent step (COMPACT-32).
    assert trimmed.turn_covered == 7

    # The turn being run's own older step is elided by the rungs (COMPACT-31):
    # its reasoning (COMPACT-14) and the content of its tool result (COMPACT-15).
    assert view.statuses[5].status == :truncated
    assert view.statuses[6].status == :truncated

    # Its user message is capped, never elided (COMPACT-11, COMPACT-32), and its
    # tool_call block survives (COMPACT-32).
    refute view.statuses[4].status in [:elided, :summarized]

    assert Enum.any?(view.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c2"))

             _ ->
               false
           end)

    # The rungs only: no step of the turn being run is dropped whole (COMPACT-33).
    refute Enum.any?(4..7, &(view.statuses[&1].status == :elided))

    # Its most recent step is sent in full (COMPACT-32) — and the step before it
    # was elided by the rungs only, its result a note naming its call
    # (COMPACT-15, COMPACT-33).
    assert view.statuses[7].status == :sent

    assert Enum.any?(view.messages, fn
             %Message{role: :tool, content: [%{content: content}]} ->
               content =~ "output elided by compaction"
               content =~ "read_file file2.txt"

             _ ->
               false
           end)
  end

  ## The turn being run (COMPACT-31, COMPACT-32, COMPACT-33)

  # COMPACT-31, COMPACT-32, COMPACT-33
  test "a pass elides the turn being run's own older steps, keeping its most recent one" do
    messages = running_turn(1, 3, "word ")
    # One turn, so nothing is cold: the whole history is the turn being run.
    assert Compaction.working_set_start(messages, %{}) == 0

    trimmed = Compaction.trim(messages, %Compaction{}, %{trigger: 1, target: 1})
    view = Compaction.view(messages, trimmed)

    assert trimmed.covered == 0
    assert trimmed.turn_covered == 5

    # The older steps' machinery is elided (COMPACT-31): each step's reasoning
    # (COMPACT-14) and the content of its tool result (COMPACT-15).
    assert Enum.map(1..4, &view.statuses[&1].status) ==
             [:truncated, :truncated, :truncated, :truncated]

    # The most recent step — its assistant message, its calls and their results —
    # is sent in full (COMPACT-32).
    assert view.statuses[5].status == :sent
    assert view.statuses[6].status == :sent

    assert Enum.any?(view.messages, fn
             %Message{role: :tool, content: [%{content: content, tool_call_id: "c1-3"}]} ->
               content =~ "output 1.3"

             _ ->
               false
           end)

    # The user message that begins the turn is never elided (COMPACT-32), and a
    # call of an older step survives with its message (COMPACT-15, COMPACT-32).
    refute view.statuses[0].status in [:elided, :summarized]

    assert Enum.any?(view.messages, fn
             %Message{role: :assistant, content: content} ->
               Enum.any?(content, &(&1.type == :tool_call and &1.id == "c1-1"))

             _ ->
               false
           end)

    # The rungs only: no step of the turn was dropped whole (COMPACT-33), and the
    # gap is named (COMPACT-23).
    refute Enum.any?(0..6, &(view.statuses[&1].status == :elided))
    assert Enum.any?(view.messages, &(&1.meta[:compaction] == :marker))

    # The single-message path agrees with the view about the turn being run
    # (COMPACT-25).
    calls = Compaction.calls(messages)

    for index <- 0..(length(messages) - 1) do
      assert Compaction.status(Enum.at(messages, index), index, trimmed, %{
               messages: messages,
               calls: calls
             }) == view.statuses[index]
    end
  end

  # COMPACT-31, COMPACT-32
  test "a chat whose whole history is one turn is bounded from inside it" do
    messages = running_turn(1, 4, "word ")
    full = Compaction.tokens(messages)

    trimmed = Compaction.trim(messages, %Compaction{}, %{trigger: 1, target: 1})
    view = Compaction.view(messages, trimmed)

    # Nothing is cold — the working set is the one turn (COMPACT-12, COMPACT-28)
    # — and the request view is still smaller than the history (COMPACT-31).
    assert trimmed.covered == 0
    assert view.elided > 0
    assert view.tokens < full

    # What bounds it is the turn's own most recent step (COMPACT-32): its
    # assistant message, its call and its result are all there, whole.
    assert view.statuses[7].status == :sent
    assert view.statuses[8].status == :sent
  end

  # COMPACT-31, COMPACT-33
  test "an elision inside the turn stays elided for the rest of it" do
    messages = running_turn(1, 3, "word ")
    trimmed = Compaction.trim(messages, %Compaction{}, %{trigger: 1, target: 1})
    assert trimmed.turn_covered == 5

    # The turn grows by a step: the pass takes the turn further, and the elision
    # it made before is still there (COMPACT-33).
    grown = messages ++ step(1, 4, "word ")
    later = Compaction.trim(grown, trimmed, %{trigger: 1, target: 1})
    assert later.turn_covered == 7

    view = Compaction.view(grown, later)
    assert Enum.all?(1..6, &(view.statuses[&1].status == :truncated))
    assert Enum.all?(7..8, &(view.statuses[&1].status == :sent))

    # A state that has already elided further than the history's own boundary
    # keeps its elision: the marker never moves back up (COMPACT-33).
    ahead = %Compaction{level: 2, turn_covered: 8}
    assert Enum.all?(1..7, &(Compaction.view(grown, ahead).statuses[&1].status == :truncated))

    assert Compaction.trim(grown, ahead, %{trigger: 1, target: 1}).turn_covered == 8
  end

  # COMPACT-31, COMPACT-33
  test "a state with nothing elided inside the turn elides nothing inside it" do
    # The field's default (COMPACT-33, ## Stored data): a state saved before the
    # rung inside the turn existed — or one whose pass has not run yet — leaves
    # the turn being run as it is, whatever the level.
    messages = running_turn(1, 3, "word ")

    for level <- 0..3 do
      view = Compaction.view(messages, %Compaction{level: level})
      assert Enum.all?(0..6, &(view.statuses[&1].status == :sent))
    end
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

  # COMPACT-22, COMPACT-35
  test "the ledger is trimmed, not re-summarized, past its cap" do
    state = Enum.reduce(1..300, %Compaction{}, &Compaction.add_ledger(&2, "entry #{&1}"))

    assert List.last(state.ledger) == "entry 300"

    # COMPACT-35: the newest entries fill the cap and the founding ones are kept
    # beyond it, so writing a line per step does not push out what the chat was
    # founded on.
    assert Enum.take(state.ledger, 10) == Enum.map(1..10, &"entry #{&1}")
    assert length(state.ledger) <= 210
  end

  # COMPACT-35
  test "the founding entries are kept up to their own, smaller cap" do
    entry = fn i -> "#{i}:" <> String.duplicate("x", 500) end
    state = Enum.reduce(1..300, %Compaction{}, &Compaction.add_ledger(&2, entry.(&1)))

    # 502 characters each: the founding cap holds three of them, and the middle
    # entries are the ones that fall off.
    assert Enum.take(state.ledger, 3) == Enum.map(1..3, &entry.(&1))
    refute entry.(4) in state.ledger
    assert length(state.ledger) <= 203

    # The first entry stays however long it is, as the newest one does.
    huge = String.duplicate("y", 30_000)
    assert Compaction.add_ledger(%Compaction{}, [huge]).ledger == [huge]
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
      assert Compaction.status(Enum.at(messages, index), index, state, %{
               calls: calls,
               messages: messages
             }) == view.statuses[index]
    end
  end

  ## State

  # COMPACT-24, COMPACT-33
  test "the state round-trips through a plain map" do
    state = %Compaction{
      level: 2,
      covered: 8,
      folded: 6,
      turn_covered: 12,
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

    # COMPACT-33, ## Stored data: a state saved before the rung inside the turn
    # existed loads with it at its default — nothing elided inside the turn.
    assert Compaction.from_map(%{level: 2, covered: 8}).turn_covered == 0
    assert Compaction.from_map(%{turn_covered: "12"}).turn_covered == 0
  end
end
