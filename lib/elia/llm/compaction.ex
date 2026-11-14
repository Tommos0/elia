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

    * `level` - how far down the ladder the cold region has been taken: `0`
      nothing, `1` reasoning dropped (COMPACT-14), `2` old tool results elided
      too (COMPACT-15), `3` whole old turns dropped too (COMPACT-16);
    * `covered` - the history index the cold region ended at the last time it
      was compacted, i.e. the aged-out marker: rules apply to messages before
      it, so the view doesn't drift as the chat grows;
    * `folded` - the index the summary has already been folded from
      (COMPACT-18), so a new fold only reads what aged out since;
    * `summary` - the folded summary (COMPACT-17), sent as a harness message at
      the head of the view (COMPACT-19);
    * `ledger` - append-only exact facts, sent verbatim (COMPACT-22);
    * `pins` - `{message index, block index | nil}` items no rule may elide
      (COMPACT-21);
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
    :auto
  ]

  @defaults %{
    budget: 100_000,
    fraction: 0.6,
    target_fraction: 0.5,
    working_set: 6,
    working_set_tokens: 25_000,
    user_cap: 8_000,
    auto: true
  }

  # The ladder's top rung; a state at this level drops whole old turns.
  @top_level 3

  # COMPACT-22: the ledger is append-and-trim only. The newest entries are kept.
  @ledger_entries 200
  @ledger_chars 20_000

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
            summary: nil,
            ledger: [],
            pins: [],
            options: %{}

  @type pin :: {non_neg_integer(), non_neg_integer() | nil}
  @type t :: %__MODULE__{
          level: non_neg_integer(),
          covered: non_neg_integer(),
          folded: non_neg_integer(),
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

  @doc "The state as a plain map, for `Elia.Store`."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state), do: Map.from_struct(state)

  @doc "Whether nothing has been compacted or pinned in this chat."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = state) do
    state.level == 0 and state.covered == 0 and state.folded == 0 and is_nil(state.summary) and
      state.ledger == [] and state.pins == [] and state.options == %{}
  end

  ## Options (COMPACT-9)

  @doc """
  The compaction options: the built-in defaults, over the app config
  (`config :elia, Elia.LLM.Compaction`), over `overrides`.

  `:budget` bounds cost and latency in tokens, `:fraction` is the share of the
  model's window to stay under, `:target_fraction` the share of the trigger to
  reduce to, `:working_set` the number of recent turns kept verbatim,
  `:working_set_tokens` the size cap on those turns, `:user_cap` the token cap
  for one user message and `:auto` whether a turn compacted on its own.
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
    state = from_map(state)
    opts = Map.new(opts)
    options = options(Map.merge(state.options, opts))
    covered = min(state.covered, length(messages))
    keep = keep_indexes(messages, state.pins)
    calls = Map.get(opts, :calls) || calls(messages)

    {kept, statuses, elided, dropped} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0, 0}, fn {message, index}, {kept, statuses, elided, dropped} ->
        ctx = %{state: state, covered: covered, options: options, keep: keep, calls: calls}
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
  message without rebuilding the whole view. Options may carry `:calls` and
  option overrides.
  """
  @spec status(Message.t(), non_neg_integer(), t(), map() | keyword()) :: message_status()
  def status(message, index, state \\ %__MODULE__{}, opts \\ %{}) do
    state = from_map(state)
    opts = Map.new(opts)

    # `min(state.covered, index + 1)` keeps the single-message path in step with
    # the view: a message is cold exactly when it lies before `covered`.
    ctx = %{
      state: state,
      covered: min(state.covered, index + 1),
      options: options(Map.merge(state.options, opts)),
      keep: MapSet.new(),
      calls: Map.get(opts, :calls) || %{}
    }

    {status, _kept, _elided} = derive(message, index, ctx)
    status
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

    {level, reached?} = walk(messages, state, options, target, overhead)
    state = %{state | level: level}

    if not reached? or is_nil(target) do
      fold(messages, state, opts, options)
    else
      state
    end
  end

  @doc """
  The mid-turn pass (COMPACT-29): runs the ladder deeper when the request view's
  estimate exceeds `:trigger`, eliding the cold prefix only.

  Returns the state unchanged when the trigger is unknown or the estimate (the
  view's tokens plus `:overhead`) is already at or below it. Otherwise it takes
  the cold region towards `:target` with the same `walk/5` ladder as `compact/3`,
  so the two paths cannot drift, and returns the state with its advanced
  `covered` and `level`.

  It never folds a summary: a mid-turn pass is elision only, so no model call
  happens inside a step, and a ladder that cannot reach the target leaves the
  pruned view and no error (COMPACT-20). The cold region always ends at or before
  the current turn's user message (COMPACT-28), so the turn being run is never
  cold and its calls and results stay intact (COMPACT-5).
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
      state = %{state | covered: max(state.covered, working_set_start(messages, options))}
      {level, _reached?} = walk(messages, state, options, Map.get(opts, :target), overhead)

      %{state | level: level}
    else
      state
    end
  end

  # COMPACT-8: stop as soon as the estimate is at or below the target. A manual
  # compaction (no target) goes all the way down the ladder.
  defp walk(messages, state, options, target, overhead) do
    from = max(state.level, 0)

    Enum.reduce_while(from..@top_level, {from, false}, fn level, _acc ->
      tokens = view(messages, %{state | level: level}, options).tokens + overhead

      cond do
        is_nil(target) and level < @top_level -> {:cont, {level, false}}
        is_nil(target) -> {:halt, {@top_level, true}}
        tokens <= target -> {:halt, {level, true}}
        true -> {:cont, {level, false}}
      end
    end)
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

      index >= ctx.covered ->
        # Not cold: only the user-message cap applies (COMPACT-11).
        cap(message, index, ctx)

      true ->
        cold(message, index, ctx, pins)
    end
  end

  # COMPACT-14, COMPACT-15, COMPACT-16
  defp cold(message, index, ctx, pins) do
    drop? =
      ctx.state.level >= @top_level and message.role != :user and not pinned_turn?(ctx, index)

    if drop? do
      status = if covered_by_summary?(ctx.state, index), do: :summarized, else: :elided
      tokens = Tokens.estimate_message(message)

      {%{status: status, blocks: all_elided(message), elided: tokens, pinned: false}, nil, tokens}
    else
      prune(message, index, ctx, pins)
    end
  end

  defp prune(%Message{role: :user} = message, index, ctx, _pins), do: cap(message, index, ctx)

  defp prune(%Message{role: :assistant} = message, _index, ctx, pins) do
    if ctx.state.level >= 1 do
      {content, blocks, elided} = drop_reasoning(message.content, pins)

      if content == [] do
        {%{status: :elided, blocks: blocks, elided: elided, pinned: false}, nil, elided}
      else
        status = if Enum.any?(blocks, fn {_, s} -> s == :elided end), do: :truncated, else: :sent

        {%{status: status, blocks: blocks, elided: elided, pinned: false},
         %{message | content: content}, elided}
      end
    else
      sent(message)
    end
  end

  defp prune(%Message{role: :tool} = message, _index, ctx, pins) do
    if ctx.state.level >= 2 do
      {content, blocks, elided} = elide_results(message.content, pins, ctx.calls)
      status = if Enum.any?(blocks, fn {_, s} -> s == :elided end), do: :truncated, else: :sent

      {%{status: status, blocks: blocks, elided: elided, pinned: false},
       %{message | content: content}, elided}
    else
      sent(message)
    end
  end

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

  defp drop_reasoning(content, pins) do
    {content, blocks, elided} =
      content
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {block, i}, {content, blocks, elided} ->
        if block.type == :reasoning and not block_pinned?(pins, i) do
          {content, Map.put(blocks, i, :elided), elided + Tokens.estimate_block(block)}
        else
          {[block | content], Map.put(blocks, i, :sent), elided}
        end
      end)

    {Enum.reverse(content), blocks, elided}
  end

  # COMPACT-15: a result is replaced by a one-line note naming the call. Tool
  # call inputs are not elided: a call and its result go together (COMPACT-4).
  defp elide_results(content, pins, calls) do
    {content, blocks, elided} =
      content
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, 0}, fn {block, i}, {content, blocks, elided} ->
        if block.type == :tool_result and not block_pinned?(pins, i) do
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

  defp pinned_turn?(ctx, index), do: MapSet.member?(ctx.keep, index)

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
  only: never re-summarized, and the oldest entries fall off past a cap.
  """
  @spec add_ledger(t(), [binary()] | binary()) :: t()
  def add_ledger(state, entries) do
    state = from_map(state)

    entries =
      entries |> List.wrap() |> Enum.map(&to_string/1) |> Enum.reject(&(String.trim(&1) == ""))

    ledger = trim_ledger(state.ledger ++ entries)
    %{state | ledger: ledger}
  end

  defp trim_ledger(ledger) do
    ledger
    |> Enum.take(-@ledger_entries)
    |> drop_oldest(0)
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
