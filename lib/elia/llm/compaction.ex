defmodule Elia.LLM.Compaction do
  @moduledoc """
  Derives the **request view**: the smaller history the model is sent, derived
  from the full one the session keeps and shows (COMPACT-2).

  A long chat grows without bound, and almost all of what grows is
  re-derivable: the survey in `specs/compaction.md` puts reasoning, file
  traffic and shell output at ~95% of the context, and everything the human
  said or the model concluded under 5%. So the view keeps the spoken record
  verbatim and elides the machinery.

  The single derivation here is used by `Elia.Agent.Session` and
  `Elia.Agent.Loop` (which send it: the session when a turn starts, the loop at
  every step of the running turn, COMPACT-5 and COMPACT-29) and by
  `EliaWeb.ChatLive` (which annotates the transcript with it), so they can never
  disagree. Given the history, the chat's state and its options it is
  deterministic (COMPACT-3).

  ## The state

  `t:Elia.LLM.Compaction.t/0` is per chat and saved with the conversation
  (COMPACT-24):

    * `items` - the items the ladder has elided (COMPACT-38): `{message index,
      block index | nil}`, a block naming a reasoning block or a tool result and
      `nil` a whole step (message). The request view elides **exactly** these,
      plus the user-message cap (COMPACT-11), so nothing a pass elided comes
      back and a later pass only adds to the list;
    * `level` - how far down the ladder the chat has gone: `0` nothing, `1`
      reasoning dropped (COMPACT-14), `2` old tool results elided too
      (COMPACT-15), `3` whole old steps dropped too (COMPACT-16). It is
      bookkeeping: what the view elides is `items`, and the level never drives a
      blanket whole-message drop (COMPACT-39);
    * `covered` - the history index the cold region ended at the last time it
      was compacted, i.e. the aged-out marker: a message before it is *eligible*
      for the ladder. Falling out of the working set elides nothing by itself
      (COMPACT-39);
    * `folded` - the index the summary has already been folded from
      (COMPACT-18), so a new fold only reads what aged out since;
    * `summary` - the folded summary (COMPACT-17), sent as a harness message at
      the head of the view (COMPACT-19);
    * `ledger` - append-only exact facts, sent verbatim (COMPACT-22);
    * `pins` - `{message index, block index | nil}` items no rule may elide
      (COMPACT-21);
    * `turn_covered` - how far the turn being run has been elided inside itself
      (COMPACT-31, COMPACT-33): the history index the last pass took it cold up
      to, which is the boundary of its most recent step, so what was elided
      inside the turn stays elided for the rest of it;
    * `options` - this chat's overrides of the config (COMPACT-9).

  The ladder never moves back up: compaction is monotone, so a region that was
  elided (or summarized) stays elided and the summary keeps covering it.
  """

  alias Elia.LLM.{Message, Tokens}

  @option_keys [
    :budget,
    :fraction,
    :target_fraction,
    :working_set,
    :working_set_tokens,
    :user_cap,
    :elide_floor,
    :auto
  ]

  @defaults %{
    budget: 100_000,
    fraction: 0.6,
    target_fraction: 0.5,
    working_set: 6,
    working_set_tokens: 25_000,
    user_cap: 8_000,
    elide_floor: 1_000,
    auto: true
  }

  # COMPACT-14, COMPACT-15, COMPACT-16: the ladder's levels — reasoning dropped,
  # old tool results elided too, whole old steps dropped too. Each item records
  # the level it was taken at, which is the rung order a pass takes them in.
  @reasoning_level 1
  @result_level 2
  @top_level 3

  # COMPACT-36: the two floor tiers. An item at or above `elide_floor` is worth
  # eliding before any item below it.
  @at_floor 0
  @below_floor 1

  # COMPACT-22: the ledger is append-and-trim only. The newest entries are kept.
  @ledger_entries 200
  @ledger_chars 20_000

  # COMPACT-35: the oldest entries are kept beyond that cap, up to a smaller one,
  # so writing a line per step cannot push out what the chat was founded on.
  @ledger_founding_entries 10
  @ledger_founding_chars 2_000

  # A tool result's output is cut to this before the summarizer sees it, and a
  # user turn to that, so the summarizer's own input stays bounded (COMPACT-18).
  @chunk_chars 1_000
  @user_chunk_chars 4_000

  @summary_system """
  You maintain the running summary of a long agent chat, folding newly aged-out \
  turns into the summary you are given. Compress them into a compact factual \
  summary: what the user asked for, what was decided and why, which files and \
  commands mattered, and anything still open. Keep exact identifiers — file \
  paths, requirement IDs, commit ids, commands. Do not invent anything, and \
  write prose, not headings.
  """

  defstruct level: 0,
            covered: 0,
            folded: 0,
            turn_covered: 0,
            items: [],
            summary: nil,
            ledger: [],
            pins: [],
            options: %{}

  @typedoc """
  One item the ladder elided (COMPACT-38): a message and, for a reasoning block
  or a tool result, the block within it — `nil` for the whole step (COMPACT-16).
  """
  @type item :: {non_neg_integer(), non_neg_integer() | nil}
  @type pin :: {non_neg_integer(), non_neg_integer() | nil}
  @type t :: %__MODULE__{
          level: non_neg_integer(),
          covered: non_neg_integer(),
          folded: non_neg_integer(),
          turn_covered: non_neg_integer(),
          items: [item()],
          summary: binary() | nil,
          ledger: [binary()],
          pins: [pin()],
          options: map()
        }

  @type view :: %{
          messages: [Message.t()],
          statuses: %{non_neg_integer() => message_status()},
          elided: non_neg_integer(),
          elided_messages: non_neg_integer(),
          tokens: non_neg_integer(),
          head: non_neg_integer()
        }

  @type message_status :: %{
          status: :sent | :truncated | :elided | :summarized,
          blocks: %{non_neg_integer() => :sent | :truncated | :elided},
          elided: non_neg_integer(),
          pinned: boolean()
        }

  ## State

  @doc "A state from a saved (or given) map; an absent or partial map is filled with defaults."
  @spec from_map(t() | map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(%__MODULE__{} = state), do: state

  def from_map(map) when is_map(map) do
    defaults = %__MODULE__{}

    %__MODULE__{
      level: level(map),
      covered: Map.get(map, :covered) || defaults.covered,
      folded: Map.get(map, :folded) || defaults.folded,
      turn_covered: turn_covered(map),
      items: items(map),
      summary: Map.get(map, :summary),
      ledger: Map.get(map, :ledger) || [],
      pins: Map.get(map, :pins) || [],
      options: Map.get(map, :options) || %{}
    }
  end

  defp level(map) do
    case Map.get(map, :level) do
      n when is_integer(n) and n >= 0 -> min(n, @top_level)
      _ -> 0
    end
  end

  # COMPACT-38, `## Stored data`: the items the ladder elided. A state saved
  # before the list existed has none — a field this build does not know is
  # ignored — and `materialise/2` fills them in from the level and boundaries
  # that state does carry.
  defp items(map) do
    case Map.get(map, :items) do
      list when is_list(list) ->
        for {index, block} <- list,
            is_integer(index) and index >= 0,
            is_nil(block) or (is_integer(block) and block >= 0),
            uniq: true,
            do: {index, block}

      _other ->
        []
    end
  end

  # COMPACT-33: a state saved before the rung inside the turn existed loads with
  # it at its default — nothing elided inside the turn (`specs/compaction.md`,
  # ## Stored data).
  defp turn_covered(map) do
    case Map.get(map, :turn_covered) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  @doc """
  COMPACT-38, `## Stored data`: the elision a state describes.

  A state saved before the item list existed carries only its `level` and the
  boundaries that went with it, so the items that level elided are materialised
  here — when the chat loads — and nothing a chat had already elided comes back.
  A state with its own item list, or one that has elided nothing, is returned as
  it is; the expansion is deterministic, so materialising twice changes nothing.
  """
  @spec materialise(t(), [Message.t()]) :: t()
  def materialise(%__MODULE__{} = state, messages) do
    if state.items == [] and state.level > 0 do
      %{state | items: legacy_items(messages, state)}
    else
      state
    end
  end

  # The state's items by message index, so the request view looks one message up
  # in constant time.
  defp item_map(items) do
    Enum.reduce(items, %{}, fn {index, block}, acc ->
      Map.update(acc, index, [block], &[block | &1])
    end)
  end

  # The items the old level and boundaries describe, message by message: a whole
  # cold message at the top rung (COMPACT-16, never a user message, a pinned one
  # or a call's pinned partner), and, for the cold prefix and the turn being run
  # alike, its reasoning (COMPACT-14) and its tool results (COMPACT-15).
  defp legacy_items(messages, state) do
    keep = keep_indexes(messages, state.pins)
    covered = min(state.covered, length(messages))
    region = region(messages, state, covered)

    for {message, index} <- Enum.with_index(messages),
        item <- legacy_items_of(message, index, state, keep, covered, region),
        uniq: true,
        do: item
  end

  defp legacy_items_of(message, index, state, keep, covered, region) do
    pins = pins_of(state.pins, index)
    cold? = index < covered and not MapSet.member?(keep, index) and pins == []
    inside? = in_region?(index, region) and pins != :all

    cond do
      pins == :all ->
        []

      cold? and state.level >= @top_level and message.role != :user ->
        [{index, nil}]

      (cold? or inside?) and message.role == :assistant and state.level >= 1 ->
        for {%{type: :reasoning}, block} <- Enum.with_index(message.content),
            not block_pinned?(pins, block),
            do: {index, block}

      (cold? or inside?) and message.role == :tool and state.level >= 2 ->
        for {%{type: :tool_result}, block} <- Enum.with_index(message.content),
            not block_pinned?(pins, block),
            do: {index, block}

      true ->
        []
    end
  end

  @doc "The state as a plain map, for `Elia.Store`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state), do: Map.from_struct(state)

  @doc "Whether nothing has been compacted or pinned in this chat."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = state) do
    state.level == 0 and state.covered == 0 and state.folded == 0 and state.items == [] and
      is_nil(state.summary) and state.ledger == [] and state.pins == [] and state.options == %{}
  end

  ## Options (COMPACT-9)

  @doc """
  The compaction options: the built-in defaults, over the app config
  (`config :elia, Elia.LLM.Compaction`), over `overrides`.

  `:budget` bounds cost and latency in tokens, `:fraction` is the share of the
  model's window to stay under, `:target_fraction` the share of the trigger to
  reduce to, `:working_set` the number of recent turns kept verbatim,
  `:working_set_tokens` the size cap on those turns, `:user_cap` the token cap
  for one user message, `:elide_floor` the size below which an item is left for
  last (COMPACT-36) and `:auto` whether a turn compacted on its own.
  """
  @spec options(map() | keyword()) :: map()
  def options(overrides \\ %{}) do
    configured = Application.get_env(:elia, __MODULE__, []) |> Map.new() |> Map.take(@option_keys)
    given = overrides |> Map.new() |> Map.take(@option_keys)

    @defaults
    |> Map.merge(Map.reject(configured, fn {_, v} -> is_nil(v) end))
    |> Map.merge(Map.reject(given, fn {_, v} -> is_nil(v) end))
  end

  @doc "COMPACT-6: the trigger, the lower of the token budget and `fraction` of the window."
  @spec trigger(pos_integer() | nil, map() | keyword()) :: pos_integer() | nil
  def trigger(window, opts \\ %{})

  def trigger(window, opts) when is_integer(window) and window > 0 do
    options = options(opts)
    min(options.budget, round(options.fraction * window))
  end

  # COMPACT-7: without a known window nothing automatic happens, however big the
  # budget is.
  def trigger(_window, _opts), do: nil

  @doc "COMPACT-8: the target to reduce to, half the trigger by default."
  @spec target(pos_integer() | nil, map() | keyword()) :: pos_integer() | nil
  def target(window, opts \\ %{}) do
    case trigger(window, opts) do
      nil -> nil
      trigger -> round(trigger * options(opts).target_fraction)
    end
  end

  @doc "Whether automatic compaction is on for this chat (COMPACT-9)."
  @spec auto?(map() | keyword()) :: boolean()
  def auto?(opts \\ %{}), do: options(opts).auto

  ## The request view (COMPACT-2, COMPACT-3)

  @doc """
  The request view of `messages` under `state` (COMPACT-2): the messages the
  model is sent, each message's status for the UI (COMPACT-25), the estimated
  tokens of the messages alone and how many tokens were elided (COMPACT-26).

  Deterministic given history, state and options (COMPACT-3). Options may carry
  a prebuilt `:calls` index (`calls/1`) and option overrides.
  """
  @spec view([Message.t()], t(), map() | keyword()) :: view()
  def view(messages, state \\ %__MODULE__{}, opts \\ %{}) do
    state = from_map(state) |> materialise(messages)
    opts = Map.new(opts)
    options = options(Map.merge(state.options, opts))
    covered = min(state.covered, length(messages))
    keep = keep_indexes(messages, state.pins)
    calls = Map.get(opts, :calls) || calls(messages)
    region = region(messages, state, covered)
    items = item_map(state.items)

    {kept, statuses, elided, dropped} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0, 0}, fn {message, index}, {kept, statuses, elided, dropped} ->
        ctx = %{
          state: state,
          covered: covered,
          region: region,
          options: options,
          keep: keep,
          calls: calls,
          items: items
        }

        {status, kept_message, gone} = derive(message, index, ctx)
        kept = if kept_message, do: [kept_message | kept], else: kept
        dropped = if kept_message, do: dropped, else: dropped + 1
        {kept, Map.put(statuses, index, status), elided + gone, dropped}
      end)

    head = head_messages(state, elided, dropped)
    kept = Enum.reverse(kept)

    %{
      messages: head ++ kept,
      statuses: statuses,
      elided: elided,
      elided_messages: dropped,
      tokens: tokens(head ++ kept),
      head: length(head)
    }
  end

  @doc """
  One message's request-view status (COMPACT-25), for a UI that appends a
  message without rebuilding the whole view. Options may carry `:calls`, option
  overrides and `:messages` — the history the message belongs to, which is what
  tells a message of the turn being run's own older steps from one of the
  working set (COMPACT-31); without it the status is derived as if the turn
  being run had no older step elided.
  """
  @spec status(Message.t(), non_neg_integer(), t(), map() | keyword()) :: message_status()
  def status(message, index, state \\ %__MODULE__{}, opts \\ %{}) do
    state = from_map(state)
    opts = Map.new(opts)
    state = materialise(state, Map.get(opts, :messages) || [])

    # `min(state.covered, index + 1)` keeps the single-message path in step with
    # the view: a message is cold exactly when it lies before `covered`.
    ctx = %{
      state: state,
      covered: min(state.covered, index + 1),
      region: status_region(opts, state),
      options: options(Map.merge(state.options, opts)),
      keep: MapSet.new(),
      calls: Map.get(opts, :calls) || %{},
      items: item_map(state.items)
    }

    {status, _kept, _elided} = derive(message, index, ctx)
    status
  end

  defp status_region(opts, state) do
    case Map.get(opts, :messages) do
      messages when is_list(messages) -> region(messages, state, state.covered)
      _ -> nil
    end
  end

  @doc "A `tool_call_id => %{name, input}` index of the messages' tool calls."
  @spec calls([Message.t()]) :: %{binary() => map()}
  def calls(messages) do
    for %Message{role: :assistant, content: content} <- messages,
        call <- content,
        call.type == :tool_call,
        into: %{},
        do: {call.id, %{name: call.name, input: call.input}}
  end

  @doc "Estimated tokens of a list of messages."
  @spec tokens([Message.t()]) :: non_neg_integer()
  def tokens(messages), do: Enum.reduce(messages, 0, &(Tokens.estimate_message(&1) + &2))

  ## Compacting (COMPACT-5, COMPACT-6, COMPACT-8, COMPACT-14..COMPACT-18)

  @doc """
  Runs the ladder over the cold prefix and, when it cannot get to the target,
  folds the summary (COMPACT-17). Returns the new state.

  Options:

    * `:target` - the token target to reduce to; `nil` means "all the way down
      the ladder", which is the manual "compact now" (COMPACT-10);
    * `:overhead` - tokens the system prompt and tool definitions add to the
      request, so the target is compared against the whole request (CTX-1);
    * `:summarizer` - `(input -> {:ok, text} | {:error, term})`; injectable so
      tests never call a provider (COMPACT-20). Without one the configured
      provider is used.
    * `:llm` - extra provider request fields for the default summarizer.

  Pruning happens before summarizing, always: the summarizer's input is the
  previous summary plus the turns that newly aged out of the working set, so it
  is bounded by summary size + chunk and does not grow with the conversation
  (COMPACT-18). When summarizing fails the state is returned pruned and no
  error is raised (COMPACT-20).
  """
  @spec compact([Message.t()], t() | map(), map() | keyword()) :: t()
  def compact(messages, state \\ %__MODULE__{}, opts \\ %{}) do
    state = from_map(state)
    opts = Map.new(opts)
    options = options(Map.merge(state.options, opts))
    target = Map.get(opts, :target)
    overhead = Map.get(opts, :overhead, 0)

    # COMPACT-12, COMPACT-28: everything before the working set is the cold
    # prefix the ladder works on; the boundary becomes this chat's aged-out
    # marker.
    covered = max(state.covered, working_set_start(messages, options))
    state = %{state | covered: covered}

    # COMPACT-10, COMPACT-31: a manual pass (no target, from the "compact now"
    # action) reaches inside the last turn too — the chat is idle, so no turn is
    # being run — up to the boundary of that turn's most recent step
    # (COMPACT-32), which is where the rungs stop. Only the manual action passes
    # no target: the turn start always passes one (COMPACT-6, COMPACT-8), so a
    # completed turn the working set keeps is left whole there (COMPACT-12).
    state = if is_nil(target), do: put_turn_covered(state, step_boundary(messages)), else: state

    {state, reached?} = walk(messages, state, options, target, overhead)

    if not reached? or is_nil(target) do
      fold(messages, state, opts, options)
    else
      state
    end
  end

  @doc """
  The mid-turn pass (COMPACT-29): runs the ladder deeper when the request view's
  estimate exceeds `:trigger`, eliding the cold prefix and the turn being run's
  own older steps.

  Returns the state unchanged when the trigger is unknown or the estimate (the
  view's tokens plus `:overhead`) is already at or below it. Otherwise it takes
  the cold region towards `:target` with the same `walk/5` ladder as `compact/3`,
  so the two paths cannot drift, and returns the state with its advanced
  `covered`, `turn_covered` and `level`.

  It never folds a summary: a mid-turn pass is elision only, so no model call
  happens inside a step, and a ladder that cannot reach the target leaves the
  pruned view and no error (COMPACT-20). The turn being run is cold up to its
  most recent step (COMPACT-31), so its user message, its calls and that step's
  own calls and results stay intact (COMPACT-32) and approval state keyed by
  `call_id` is never invalidated (COMPACT-5).
  """
  @spec trim([Message.t()], t() | map(), map() | keyword()) :: t()
  def trim(messages, state \\ %__MODULE__{}, opts \\ %{}) do
    state = from_map(state)
    opts = Map.new(opts)
    options = options(Map.merge(state.options, opts))
    trigger = Map.get(opts, :trigger)
    overhead = Map.get(opts, :overhead, 0)

    if trigger != nil and view(messages, state, options).tokens + overhead > trigger do
      # COMPACT-12, COMPACT-28: the cold prefix is everything before the working
      # set, which never includes the turn being run.
      # COMPACT-31, COMPACT-33: the turn being run is taken cold up to its most
      # recent step (COMPACT-32) — the marker records the boundary, so what the
      # rungs elided inside the turn stays elided for the rest of it.
      advanced =
        %{state | covered: max(state.covered, working_set_start(messages, options))}
        |> put_turn_covered(step_boundary(messages))

      {elided, _reached?} = walk(messages, advanced, options, Map.get(opts, :target), overhead)

      # At level 0 the rungs are off and nothing was elided, so the marker does
      # not move: it records elision that happened.
      if elided.level >= 1, do: elided, else: state
    else
      state
    end
  end

  defp put_turn_covered(state, boundary),
    do: %{state | turn_covered: max(state.turn_covered, boundary)}

  # COMPACT-36, COMPACT-37, COMPACT-38: one pass of the ladder.

  # It collects the items it may take, orders them and takes them one at a time,
  # re-estimating the request view (CTX-1) after each — largest first — and stops
  # as soon as the estimate is at or below the target (COMPACT-8). It never takes
  # a rung whole and never elides more than reaching the target needs, and it
  # only adds to the items, so what an earlier pass elided stays elided. A manual
  # pass (no target) takes every item there is. Returns the state and whether the
  # target was reached.
  defp walk(messages, state, options, target, overhead) do
    {candidates, ctx} = candidates(messages, state, options)
    view = view(messages, state, options)

    # The marker (COMPACT-23) joins the view as soon as anything is elided and
    # names what was elided, so the estimate below is taken with neither: the
    # view's own elision added back, and the marker added after each item.
    step = %{
      state: state,
      ctx: ctx,
      held: MapSet.new(state.items),
      raw:
        view.tokens + overhead + view.elided -
          marker_tokens(state, view.elided, view.elided_messages),
      elided: view.elided,
      dropped: view.elided_messages
    }

    {taken, level, step} = take(candidates, step, target)

    # COMPACT-39: `level` is bookkeeping — the deepest rung the chat has gone to,
    # never less than before. What the view elides is `items`.
    state = %{
      state
      | items: minimal(state.items ++ taken),
        level: min(max(level, state.level), @top_level)
    }

    {state, is_nil(target) or estimate(step) <= target}
  end

  # COMPACT-8: take an item while the estimate is above the target, and stop as
  # soon as it is at or below it — so a pass stops exactly at the target and
  # never takes the next item. A manual pass (no target) takes every item there
  # is. The second element is the deepest rung taken.
  defp take(candidates, step, nil) do
    items = candidates |> Enum.map(&elem(&1, 3)) |> List.flatten()
    {items, level_of(candidates), step}
  end

  defp take(candidates, step, target) do
    {taken, level, step} =
      Enum.reduce_while(candidates, {[], 0, step}, fn {_tier, level, _gain, items},
                                                      {taken, deep, step} ->
        if estimate(step) <= target do
          {:halt, {taken, deep, step}}
        else
          # COMPACT-37: the gain is what the item still takes out of the view, not
          # what it would have taken at the start of the pass — a whole step
          # subsumes the block items of the same message taken before it.
          gain = remaining_gain(items, step.ctx, step.held)
          {:cont, {[items | taken], max(deep, level), take!(step, items, gain)}}
        end
      end)

    {taken |> Enum.reverse() |> List.flatten(), level, step}
  end

  # A block item whose whole message is elided too adds nothing: the view drops
  # the message whole (COMPACT-16), so the list keeps only the item that says so.
  defp minimal(items) do
    whole = for {index, nil} <- items, into: MapSet.new(), do: index

    Enum.reject(items, fn {index, block} ->
      not is_nil(block) and MapSet.member?(whole, index)
    end)
  end

  # COMPACT-37: re-estimating the request view (CTX-1) after an item, cheaply —
  # the gain is what the view counts as elided for it, and the marker that names
  # it comes along (COMPACT-23).
  defp take!(step, items, gain) do
    dropped = Enum.count(items, fn {_index, block} -> is_nil(block) end)

    %{
      step
      | elided: step.elided + gain,
        dropped: step.dropped + dropped,
        held: Enum.reduce(items, step.held, &MapSet.put(&2, &1))
    }
  end

  # What the items would still save, given what the pass has taken so far: a
  # block item counts once, and a whole step counts what is left of its message.
  defp remaining_gain(items, ctx, held) do
    Enum.sum(
      Enum.map(items, fn {index, block} = item ->
        cond do
          MapSet.member?(held, item) -> 0
          is_nil(block) -> whole_gain(index, ctx, held)
          true -> block_gain(message_at(index, ctx), block, ctx)
        end
      end)
    )
  end

  defp estimate(step) do
    step.raw - step.elided + marker_tokens(step.state, step.elided, step.dropped)
  end

  defp marker_tokens(_state, 0, _dropped), do: 0

  # The marker the view adds (COMPACT-23) is a harness message ("[Elia harness] "
  # and all), so it is sized as that message — the one `head_messages/3` builds.
  defp marker_tokens(state, elided, dropped),
    do: Tokens.estimate_message(Message.harness(marker_text(elided, dropped, state)))

  defp level_of(candidates) do
    candidates
    |> Enum.map(fn {_tier, level, _gain, _items} -> level end)
    |> Enum.max(fn -> 0 end)
  end

  # COMPACT-36, COMPACT-37: the items the pass may take, in the order it takes
  # them: items at or above the floor before items below it (COMPACT-36), then
  # the rungs in order — reasoning (COMPACT-14), then old tool results
  # (COMPACT-15), then whole old steps (COMPACT-16) — and within a tier and a
  # rung the largest first (COMPACT-37), so the fewest items reach the target.
  defp candidates(messages, state, options) do
    covered = min(state.covered, length(messages))

    ctx = %{
      messages: messages,
      covered: covered,
      region: region(messages, state, covered),
      keep: keep_indexes(messages, state.pins),
      calls: calls(messages),
      links: links(messages),
      items: item_map(state.items),
      held: MapSet.new(state.items),
      pins: state.pins,
      floor: options.elide_floor
    }

    candidates =
      messages
      |> Enum.with_index()
      |> Enum.flat_map(fn {_message, index} -> candidates_of(index, ctx) end)
      |> Enum.sort_by(fn {tier, level, gain, _items} -> {tier, level, -gain} end)

    {candidates, ctx}
  end

  # COMPACT-36: the floor splits the items into two tiers: one at or above
  # `elide_floor` estimated tokens goes before one below it.
  defp tier(level, gain, items, floor) do
    if gain >= floor,
      do: {@at_floor, level, gain, items},
      else: {@below_floor, level, gain, items}
  end

  # The items one message can still give, and what taking each would save. Only
  # the cold prefix and the turn being run's own older steps give anything; a
  # pinned message gives nothing (COMPACT-21) and neither does an item the state
  # already holds (COMPACT-38).
  defp candidates_of(index, ctx) do
    pins = pins_of(ctx.pins, index)
    held = MapSet.new(Map.get(ctx.items, index, []))

    cond do
      pins == :all or not eligible?(index, ctx) ->
        []

      true ->
        (rung_items(index, held, pins, ctx) ++ step_items(index, ctx))
        |> Enum.map(fn {level, gain, items} -> tier(level, gain, items, ctx.floor) end)
    end
  end

  defp eligible?(index, ctx), do: index < ctx.covered or in_region?(index, ctx.region)

  # COMPACT-14, COMPACT-15: an old step's reasoning blocks and its tool results,
  # each item one block, so a pass takes a few big ones rather than all of them.
  defp rung_items(index, held, pins, ctx) do
    message = message_at(index, ctx)

    for {block, i} <- Enum.with_index(message.content),
        rung = rung_of(block),
        is_integer(rung),
        not MapSet.member?(held, i),
        i not in pins,
        gain = block_gain(message, i, ctx),
        do: {rung, gain, [{index, i}]}
  end

  defp rung_of(%{type: :reasoning}), do: @reasoning_level
  defp rung_of(%{type: :tool_result}), do: @result_level
  defp rung_of(_block), do: nil

  # COMPACT-16, COMPACT-4: a whole old step — an assistant message with its text
  # and calls, and the tool results answering them — dropped together, never a
  # call without its result or a result without its call. Only the cold prefix
  # drops whole steps, so it is generated once per group, at the first message of
  # it, and only when every message of the group may go.
  defp step_items(index, ctx) do
    group = closure([index], ctx.links, MapSet.new([index]))

    if index < ctx.covered and Enum.min(group) == index and
         Enum.all?(group, &droppable?(&1, ctx)) and not Enum.any?(group, &dropped?(&1, ctx)) do
      items = for i <- group, do: {i, nil}
      [{@top_level, Enum.sum(Enum.map(group, &whole_gain(&1, ctx, ctx.held))), items}]
    else
      []
    end
  end

  defp dropped?(index, ctx), do: nil in Map.get(ctx.items, index, [])

  # A whole step may only be dropped if it is cold, is not a user message
  # (COMPACT-11), no pin touches it (COMPACT-21) and it is not in the working set
  # (COMPACT-12).
  defp droppable?(index, ctx) do
    case message_at(index, ctx) do
      %Message{role: role} ->
        role != :user and index < ctx.covered and pins_of(ctx.pins, index) == [] and
          not MapSet.member?(ctx.keep, index)

      nil ->
        false
    end
  end

  # COMPACT-4: the messages a step spans — a call and the message answering it,
  # in either direction — closed over, so one group is one take.
  defp closure(frontier, links, seen) do
    next =
      for i <- frontier,
          j <- Map.get(links, i, []),
          not MapSet.member?(seen, j),
          uniq: true,
          do: j

    case next do
      [] -> seen
      _ -> closure(next, links, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
    end
  end

  # What a whole step would save: the tokens its messages take in the view today,
  # less what is already elided in them, so an item taken after the block items
  # of the same message counts only what is left of it.
  defp whole_gain(index, ctx, held) do
    message = message_at(index, ctx)
    blocks = for {i, block} <- held, i == index, is_integer(block), do: block

    max(
      Tokens.estimate_message(message) -
        Enum.sum(Enum.map(blocks, &block_gain(message, &1, ctx))),
      0
    )
  end

  # What one block of a message would save (COMPACT-14, COMPACT-15, COMPACT-23).
  defp block_gain(message, block, ctx) when is_integer(block) do
    case Enum.at(message.content, block) do
      %{type: :reasoning} = reasoning -> Tokens.estimate_block(reasoning)
      %{type: :tool_result} = result -> result_gain(result, ctx.calls)
      _other -> 0
    end
  end

  defp block_gain(_message, _block, _ctx), do: 0

  defp result_gain(block, calls) do
    kept = %{block | content: elision_note(Map.get(calls, block.tool_call_id))}
    max(Tokens.estimate_block(block) - Tokens.estimate_block(kept), 0)
  end

  defp message_at(index, ctx), do: Enum.at(ctx.messages, index)

  # COMPACT-4: which messages answer whose calls, so a whole step can be dropped
  # with the results it calls for.
  defp links(messages) do
    indexed = Enum.with_index(messages)

    result_at =
      for {message, i} <- indexed,
          message.role == :tool,
          result <- message.content,
          result.type == :tool_result,
          into: %{},
          do: {result.tool_call_id, i}

    for {message, i} <- indexed,
        call <- message.content,
        call.type == :tool_call,
        is_integer(result_at[call.id]),
        reduce: %{} do
      acc ->
        j = result_at[call.id]

        acc
        |> Map.update(i, [j], &[j | &1])
        |> Map.update(j, [i], &[i | &1])
    end
  end

  # COMPACT-18: fold the previous summary together with the turns that newly
  # aged out. Never re-derive from the whole history.
  defp fold(messages, state, opts, options) do
    from = min(state.folded, state.covered)
    chunk = Enum.slice(messages, from, max(state.covered - from, 0))

    with true <- chunk != [],
         summarizer when is_function(summarizer, 1) <- summarizer(opts, options),
         {:ok, text} when is_binary(text) <- summarizer.(fold_input(state.summary, chunk)) do
      text = String.trim(text)
      if text == "", do: state, else: %{state | summary: text, folded: state.covered}
    else
      # COMPACT-20: summarization is best effort; the pruned view is enough.
      _ -> state
    end
  end

  defp summarizer(opts, options) do
    Map.get(opts, :summarizer) ||
      default_summarizer(Map.get(opts, :llm, %{}), options)
  end

  @doc """
  The default summarizer: one model call through `Elia.LLM.stream/2` with the
  same provider request as the turn (`:llm`).
  """
  @spec default_summarizer(map(), map()) :: (binary() -> {:ok, binary()} | {:error, term()})
  def default_summarizer(llm \\ %{}, _options \\ %{}) do
    fn input ->
      request =
        llm
        |> Map.new()
        |> Map.merge(%{system: @summary_system, messages: [Message.user(input)]})

      case Elia.LLM.stream(request) do
        {:ok, %{message: message}} ->
          case Message.text_content(message) do
            "" -> {:error, :empty_summary}
            text -> {:ok, text}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fold_input(previous, chunk) do
    previous =
      if is_binary(previous) and String.trim(previous) != "" do
        "The summary so far:\n\n#{previous}\n\nFold these newly aged-out turns into it:\n\n"
      else
        "Summarize these turns of an agent chat:\n\n"
      end

    previous <> render_chunk(chunk)
  end

  defp render_chunk(messages) do
    calls = calls(messages)
    Enum.map_join(messages, "\n\n", &render_message(&1, calls))
  end

  defp render_message(%Message{role: :user} = message, _calls),
    do: "USER:\n" <> cut(Message.text_content(message), @user_chunk_chars)

  defp render_message(%Message{role: :assistant, content: content}, _calls) do
    parts =
      for block <- content, block.type != :reasoning, into: [] do
        case block do
          %{type: :text, text: text} ->
            text

          %{type: :tool_call, name: name, input: input} ->
            "called #{name} #{input_summary(input)}"

          _other ->
            ""
        end
      end

    "ASSISTANT:\n" <> (parts |> Enum.reject(&(&1 == "")) |> Enum.join("\n"))
  end

  defp render_message(%Message{role: :tool, content: content}, calls) do
    notes =
      for %{type: :tool_result, tool_call_id: id} = block <- content, into: [] do
        label = note_label(Map.get(calls, id))

        case result_text(block) do
          text when is_binary(text) and text != "" ->
            "#{label} returned:\n#{cut(text, @chunk_chars)}"

          _ ->
            "#{label} returned nothing"
        end
      end

    "TOOL RESULTS:\n" <> Enum.join(notes, "\n\n")
  end

  ## Deriving one message

  defp derive(message, index, ctx) do
    pins = pins_of(ctx.state.pins, index)

    cond do
      pins == :all ->
        {%{status: :sent, blocks: sent_blocks(message), elided: 0, pinned: true}, message, 0}

      in_region?(index, ctx.region) ->
        # COMPACT-31, COMPACT-33: the turn being run is cold up to its most
        # recent step, so its own older steps take the items the ladder elided
        # there — its reasoning (COMPACT-14) and its tool results (COMPACT-15) —
        # and are never dropped whole (COMPACT-16).
        case Map.get(ctx.items, index, []) do
          [] -> prune(message, index, ctx, pins)
          items -> prune(message, index, ctx, pins, List.delete(items, nil))
        end

      index >= ctx.covered ->
        # Not cold: only the user-message cap applies (COMPACT-11).
        cap(message, index, ctx)

      true ->
        cold(message, index, ctx, pins)
    end
  end

  # COMPACT-38: what a message elides is exactly the items the state holds for
  # it: `{index, nil}` for the whole step (COMPACT-16, the cold prefix only) and
  # `{index, block}` for one of its blocks — its reasoning (COMPACT-14) and its
  # tool results (COMPACT-15). Nothing here reads `level`, so aging out of the
  # working set elides nothing by itself (COMPACT-39).
  defp cold(message, index, ctx, pins) do
    case Map.get(ctx.items, index, []) do
      [] ->
        prune(message, index, ctx, pins)

      items ->
        if nil in items do
          drop_whole(message, index, ctx)
        else
          prune(message, index, ctx, pins, items)
        end
    end
  end

  # COMPACT-16: a whole old step is dropped, and its tokens are counted as
  # elided (COMPACT-23).
  defp drop_whole(message, index, ctx) do
    status = if covered_by_summary?(ctx.state, index), do: :summarized, else: :elided
    tokens = Tokens.estimate_message(message)

    {%{status: status, blocks: all_elided(message), elided: tokens, pinned: false}, nil, tokens}
  end

  # COMPACT-14, COMPACT-15: only the named blocks go.
  defp prune(%Message{role: :assistant} = message, _index, _ctx, pins, items) do
    {content, blocks, elided} = drop_reasoning(message.content, pins, items)

    if content == [] do
      {%{status: :elided, blocks: blocks, elided: elided, pinned: false}, nil, elided}
    else
      status = if Enum.any?(blocks, fn {_, s} -> s == :elided end), do: :truncated, else: :sent

      {%{status: status, blocks: blocks, elided: elided, pinned: false},
       %{message | content: content}, elided}
    end
  end

  defp prune(%Message{role: :tool} = message, _index, ctx, pins, items) do
    {content, blocks, elided} = elide_results(message.content, pins, items, ctx.calls)
    status = if Enum.any?(blocks, fn {_, s} -> s == :elided end), do: :truncated, else: :sent

    {%{status: status, blocks: blocks, elided: elided, pinned: false},
     %{message | content: content}, elided}
  end

  # COMPACT-11: a user message is capped, never elided.
  defp prune(%Message{role: :user} = message, index, ctx, _pins, _items) do
    cap(message, index, ctx)
  end

  defp prune(message, _index, _ctx, _pins, _items), do: sent(message)

  # COMPACT-31, COMPACT-32, COMPACT-33: the turn being run's own older steps —
  # from the user message that begins it up to the marker the last pass elided
  # to, which is the boundary of its most recent step. `prune/4` is the rungs
  # only, so a step inside the turn is never dropped whole (COMPACT-16), and its
  # user message is capped, never elided (COMPACT-11, COMPACT-32).
  defp region(messages, state, covered) do
    marker = min(state.turn_covered, length(messages))

    case last_turn_start(messages) do
      turn when is_integer(turn) and turn >= covered and turn < marker -> {turn, marker}
      _turn -> nil
    end
  end

  defp in_region?(_index, nil), do: false
  defp in_region?(index, {from, to}), do: index >= from and index < to

  # The user message that begins the turn being run: the last turn of the
  # history. A harness message (COMPACT-19) is not a turn start.
  defp last_turn_start(messages), do: List.last(turn_starts(messages))

  # COMPACT-32: the boundary of the turn being run's most recent step — its last
  # assistant message, with everything from it on (its calls and their results)
  # sent in full. A turn with no assistant message yet has no older step.
  defp step_boundary(messages) do
    case last_turn_start(messages) do
      nil -> 0
      turn -> last_assistant(messages, turn) || 0
    end
  end

  defp last_assistant(messages, from) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Message{role: :assistant}, index}, _last when index >= from -> index
      _other, last -> last
    end)
  end

  defp prune(%Message{role: :user} = message, index, ctx, _pins), do: cap(message, index, ctx)

  defp prune(message, _index, _ctx, _pins), do: sent(message)

  defp sent(message),
    do: {%{status: :sent, blocks: sent_blocks(message), elided: 0, pinned: false}, message, 0}

  # COMPACT-11, COMPACT-13: every user message is kept; a huge one is truncated
  # with an explicit marker instead of dropped, and the first user message (the
  # task statement, and a sub-task's brief) is never cut.
  defp cap(%Message{role: :user} = message, index, ctx) do
    text = Message.text_content(message)
    limit = ctx.options.user_cap * 4

    if index == 0 or String.length(text) <= limit do
      sent(message)
    else
      kept = String.slice(text, 0, limit)
      elided = Tokens.estimate(text) - Tokens.estimate(kept)

      note =
        "\n\n[compaction: #{Tokens.estimate(text) - Tokens.estimate(kept)} tokens of this " <>
          "message were cut. Ask the user if you need the rest.]"

      message = %{message | content: [%{type: :text, text: kept <> note}]}

      {%{status: :truncated, blocks: %{0 => :truncated}, elided: elided, pinned: false}, message,
       elided}
    end
  end

  defp cap(message, _index, _ctx), do: sent(message)

  # COMPACT-14: drops the named reasoning blocks of a message — and only those,
  # so a message keeps everything the ladder has not taken.
  defp drop_reasoning(content, pins, blocks_to_go) do
    {content, blocks, elided} =
      content
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {block, i}, {content, blocks, elided} ->
        if block.type == :reasoning and i in blocks_to_go and not block_pinned?(pins, i) do
          {content, Map.put(blocks, i, :elided), elided + Tokens.estimate_block(block)}
        else
          {[block | content], Map.put(blocks, i, :sent), elided}
        end
      end)

    {Enum.reverse(content), blocks, elided}
  end

  # COMPACT-15: a result is replaced by a one-line note naming the call. Tool
  # call inputs are not elided: a call and its result go together (COMPACT-4).
  defp elide_results(content, pins, blocks_to_go, calls) do
    {content, blocks, elided} =
      content
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {block, i}, {content, blocks, elided} ->
        if block.type == :tool_result and i in blocks_to_go and not block_pinned?(pins, i) do
          note = elision_note(Map.get(calls, block.tool_call_id))
          kept = %{block | content: note}
          gone = max(Tokens.estimate_block(block) - Tokens.estimate_block(kept), 0)
          {[kept | content], Map.put(blocks, i, :elided), elided + gone}
        else
          {[block | content], Map.put(blocks, i, :sent), elided}
        end
      end)

    {Enum.reverse(content), blocks, elided}
  end

  defp all_elided(%Message{content: content}),
    do: Map.new(Enum.with_index(content), fn {_block, i} -> {i, :elided} end)

  defp sent_blocks(%Message{content: content}),
    do: Map.new(Enum.with_index(content), fn {_block, i} -> {i, :sent} end)

  defp result_text(%{content: content}), do: Tokens.result_text(content)

  @doc "The one-line note that replaces an elided tool result (COMPACT-15, COMPACT-23)."
  @spec elision_note(map() | nil) :: binary()
  def elision_note(nil) do
    "[output elided by compaction. Re-run the tool if you need it.]"
  end

  def elision_note(%{name: name, input: input}) do
    "[output elided by compaction: #{name} #{input_summary(input)}. " <>
      "Run it again if you need the output.]"
  end

  defp note_label(nil), do: "a tool"
  defp note_label(%{name: name, input: input}), do: "#{name} #{input_summary(input)}"

  defp input_summary(%{"command" => command}) when is_binary(command), do: "$ #{cut(command, 80)}"
  defp input_summary(%{"path" => path}) when is_binary(path), do: path
  defp input_summary(input) when input == %{} or is_nil(input), do: "(no input)"

  defp input_summary(input) do
    case Jason.encode(input) do
      {:ok, json} -> cut(json, 120)
      _ -> ""
    end
  end

  defp cut(text, limit) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  ## Pins (COMPACT-21)

  @doc "Whether `index` (and optionally `block`) is pinned."
  @spec pinned?(t(), non_neg_integer(), non_neg_integer() | nil) :: boolean()
  def pinned?(state, index, block \\ nil) do
    state = from_map(state)

    pinned_message?(state.pins, index) or
      (block != nil and pinned_block?(state.pins, index, block))
  end

  @doc "Pins a message (`block` nil) or one of its blocks."
  @spec pin(t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def pin(state, index, block \\ nil) do
    state = from_map(state)
    %{state | pins: Enum.uniq([{index, block} | state.pins])}
  end

  @doc "Unpins a message or block."
  @spec unpin(t(), non_neg_integer(), non_neg_integer() | nil) :: t()
  def unpin(state, index, block \\ nil) do
    state = from_map(state)
    %{state | pins: List.delete(state.pins, {index, block})}
  end

  defp pinned_message?(pins, index), do: {index, nil} in pins
  defp pinned_block?(pins, index, block), do: {index, block} in pins

  defp pins_of(pins, index) do
    cond do
      pinned_message?(pins, index) -> :all
      true -> for {i, block} <- pins, i == index, is_integer(block), do: block
    end
  end

  defp block_pinned?(blocks, i) when is_list(blocks), do: i in blocks
  defp block_pinned?(_blocks, _i), do: false

  # COMPACT-4: a call and its result go together, so a pin keeps the message it
  # touches and the message it is paired with, rather than splitting them.
  defp keep_indexes(messages, pins) do
    pinned = for {i, _} <- pins, is_integer(i), into: MapSet.new(), do: i

    if MapSet.size(pinned) == 0 do
      MapSet.new()
    else
      indexed = Enum.with_index(messages)

      Enum.reduce(pinned, pinned, fn i, keep ->
        case Enum.at(messages, i) do
          %Message{role: :assistant, content: content} ->
            ids = for call <- content, call.type == :tool_call, do: call.id
            pair(indexed, keep, &(&1.role == :tool and answers?(&1, ids)))

          %Message{role: :tool, content: content} ->
            ids = for result <- content, result.type == :tool_result, do: result.tool_call_id

            pair(indexed, keep, fn message ->
              message.role == :assistant and
                Enum.any?(message.content, &(&1.type == :tool_call and &1.id in ids))
            end)

          _message ->
            keep
        end
      end)
    end
  end

  defp pair(indexed, keep, match?) do
    Enum.reduce(indexed, keep, fn {message, j}, keep ->
      if match?.(message), do: MapSet.put(keep, j), else: keep
    end)
  end

  defp answers?(%Message{content: content}, ids),
    do: Enum.any?(content, &(&1.type == :tool_result and &1.tool_call_id in ids))

  @doc """
  The history index the working set starts at (COMPACT-12, COMPACT-28): the most
  recent `working_set` turns that fit in `working_set_tokens` estimated tokens.

  Never more than `working_set` turns and always at least the current (last)
  turn, so the last turn is never cold even when it alone exceeds the budget.
  The boundary is always the user message that begins a turn (COMPACT-4); a
  harness message (UI-9) is not a turn start.
  """
  @spec working_set_start([Message.t()], map() | keyword()) :: non_neg_integer()
  def working_set_start(messages, opts \\ %{}) do
    options = options(opts)

    case Enum.take(turn_starts(messages), -max(options.working_set, 1)) do
      [] ->
        0

      [first | rest] ->
        ends = rest ++ [length(messages)]

        [first | rest]
        |> Enum.zip(ends)
        |> Enum.map(fn {from, to} -> tokens(Enum.slice(messages, from, to - from)) end)
        |> keep_within_budget([first | rest], options.working_set_tokens)
    end
  end

  # COMPACT-12: the user messages that begin a turn; a harness message
  # (COMPACT-19) is placed at the head of a view, not a turn of the chat.
  defp turn_starts(messages) do
    for {%Message{role: :user} = message, i} <- Enum.with_index(messages),
        not Map.get(message.meta, :harness, false),
        do: i
  end

  # COMPACT-28: drop the oldest turns while the working set is over budget,
  # stopping at the current (last) turn, which is kept however big it is.
  defp keep_within_budget(_sizes, [start], _budget), do: start

  defp keep_within_budget(sizes, [start | rest], budget) do
    if Enum.sum(sizes) <= budget do
      start
    else
      keep_within_budget(tl(sizes), rest, budget)
    end
  end

  ## The head of the view (COMPACT-19, COMPACT-22, COMPACT-23)

  defp head_messages(state, elided, dropped) do
    summary =
      if is_binary(state.summary) and String.trim(state.summary) != "" do
        [harness(:summary, "Earlier context summary:\n\n#{String.trim(state.summary)}")]
      else
        []
      end

    marker =
      if elided > 0 do
        [harness(:marker, marker_text(elided, dropped, state))]
      else
        []
      end

    ledger =
      if state.ledger == [] do
        []
      else
        [
          harness(
            :ledger,
            "Ledger of exact facts (verbatim):\n\n" <>
              Enum.map_join(state.ledger, "\n", &"- #{&1}")
          )
        ]
      end

    summary ++ marker ++ ledger
  end

  # COMPACT-23: silent loss becomes a knowable gap.
  defp marker_text(elided, dropped, state) do
    covered =
      if is_binary(state.summary) and String.trim(state.summary) != "" do
        " The summary below stands in for them."
      else
        ""
      end

    "Context compacted: about #{elided} tokens across #{dropped} messages of earlier " <>
      "reasoning and tool output were not sent to you.#{covered} Re-read files and re-run " <>
      "commands rather than relying on memory."
  end

  defp covered_by_summary?(%{summary: summary, folded: folded}, index) do
    is_binary(summary) and String.trim(summary) != "" and index < folded
  end

  # COMPACT-19: a harness message, so the UI renders it as a notice (UI-9).
  defp harness(kind, text) do
    message = Message.harness(text)
    %{message | meta: Map.put(message.meta, :compaction, kind)}
  end

  ## The ledger (COMPACT-22)

  @doc """
  Appends `entries` of exact facts to the ledger. The ledger is append-and-trim
  only: never re-summarized, and once it fills the middle entries fall off — the
  newest ones and the founding ones stay (COMPACT-35).
  """
  @spec add_ledger(t(), [binary()] | binary()) :: t()
  def add_ledger(state, entries) do
    state = from_map(state)

    entries =
      entries |> List.wrap() |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == ""))

    ledger = trim_ledger(state.ledger ++ entries)
    %{state | ledger: ledger}
  end

  # COMPACT-35: the newest entries fill the cap and the oldest are kept beyond
  # it, up to a smaller founding cap, so a chat that writes a line per step does
  # not push out the decisions it was founded on.
  defp trim_ledger(ledger) do
    {founding, recent} = Enum.split(ledger, @ledger_founding_entries)

    keep_founding(founding) ++
      (recent |> Enum.take(-@ledger_entries) |> drop_oldest(0))
  end

  defp keep_founding(entries) do
    {kept, _size} =
      Enum.reduce_while(entries, {[], 0}, fn entry, {kept, size} ->
        size = size + String.length(entry)

        # The first entry stays however long it is, as `drop_oldest/2` keeps one.
        if kept != [] and size > @ledger_founding_chars do
          {:halt, {kept, size}}
        else
          {:cont, {[entry | kept], size}}
        end
      end)

    Enum.reverse(kept)
  end

  defp drop_oldest(ledger, size) do
    case ledger do
      [entry | rest] ->
        size = size + String.length(entry)

        if size > @ledger_chars and rest != [] do
          drop_oldest(rest, size - String.length(entry))
        else
          ledger
        end

      [] ->
        []
    end
  end

  @doc "The `:summary` text the head of a view would carry, for a UI that shows it as a notice."
  @spec summary_block(t()) :: {non_neg_integer(), binary()} | nil
  def summary_block(state) do
    state = from_map(state)

    if is_binary(state.summary) and String.trim(state.summary) != "" do
      {state.folded, state.summary}
    end
  end
end
