defmodule Elia.Agent.Loop do
  @moduledoc """
  The agentic loop: call the model, run requested tools, feed results back,
  repeat until the model stops asking for tools. When it stops, the turn is
  done: nothing is verified and nothing is rolled back
  (`specs/verification.md`).

  Runs inside a task owned by `Elia.Agent.Session` and reports to it with
  plain messages:

    * `{:loop_event, event}` - streaming `t:Elia.LLM.Provider.event/0`s
    * `{:loop_append, message}` - a message to append to the history
    * `{:loop_tool_status, call_id, status}` - `:running` or `:done`
    * `{:loop_await_approval, task_pid, calls}` - reply with
      `{:approval_decisions, %{call_id => :approve | :deny}}`
    * `{:loop_await_input, task_pid, calls}` - a tool that asks the user
      (LOOP-21); reply with `{:input_answers, %{call_id => answer}}
    * `{:loop_compaction, state}` - the compaction state advanced mid-turn,
      after the ladder elided more of the cold prefix (COMPACT-29)
    * `{:loop_retry, info}` - the step's model call failed transiently and is
      being tried again after a wait (RETRY-1, RETRY-3)
    * `{:loop_step_timing, record}` - the measurements of a finished step, for
      the session to record beside the chat (TIME-1, TIME-2)

  The loop is given the chat's **full** history and keeps it growing as the turn
  runs; the messages it *sends* are the request view of that history under the
  chat's compaction state, derived again at every step (COMPACT-2, COMPACT-5,
  COMPACT-29), so the view can shrink while the history does not.

  Options: `:session_id`, `:turn_id`, `:turn_started_at` (the chat's turn as it
  started, STORE-30: both go into a step's timing record, TIME-2), `:skills` (a
  fixed skill list, or a function returning one, instead of the project's),
  `:max_steps` (default 100),
  `:pause_on_limit` (a limit pauses the turn for the user instead of ending it,
  LOOP-19), `:budget_ms` (a wall-clock budget, LOOP-20), `:token_budget` (a
  token budget for the turn, LOOP-22, LIMIT-12), `:step_retry` (the waits before
  each retry of a failed model call, RETRY-4), `:llm` (extra request
  fields), `:project` (the chat's project),
  `:workspace` (the chat's workspace root: its own git
  worktree in Elia's own project, DEPLOY-1, else the project's folder, PROJ-12),
  `:jail` (the chat's jail setting for the tool context, ISOL-15) and, for the
  mid-turn pass, `:compaction` (the chat's
  `t:Elia.LLM.Compaction.t/0`, `nil` to send the history as it is),
  `:compaction_trigger`, `:compaction_target` and `:compaction_overhead`.
  """

  alias Elia.LLM.{Compaction, Context, Message}
  alias Elia.Tool

  @max_steps 100

  # RETRY-4: the waits before each retry of a model call that failed
  # transiently, unless the turn's option or `config :elia, :step_retry` says
  # otherwise. Its length is how many retries a step gets.
  @default_retry_delays [15_000, 30_000, 60_000]

  @type limit ::
          {:steps, pos_integer()} | {:time, non_neg_integer()} | {:tokens, non_neg_integer()}

  @type result :: :done | :refused | {:limit, limit()} | {:error, term()}

  @spec run(pid(), [Message.t()], keyword()) :: result()
  def run(session, history, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, Elia.Workspace.root())
    project = Keyword.get(opts, :project)

    ctx = %{
      session: session,
      # TIME-2: what identifies the turn a step's record belongs to.
      turn_id: opts[:turn_id],
      turn_started_at: opts[:turn_started_at],
      skills: Keyword.get(opts, :skills),
      max_steps: Keyword.get(opts, :max_steps, @max_steps),
      # LOOP-19, LOOP-20, LOOP-22: whether a limit pauses the turn, the
      # wall-clock budget it is measured against, and the token budget.
      pause_on_limit: Keyword.get(opts, :pause_on_limit, false),
      budget_ms: Keyword.get(opts, :budget_ms),
      token_budget: Keyword.get(opts, :token_budget),
      started_ms: now_ms(),
      approved_ms: 0,
      # LOOP-22, LIMIT-12: the tokens the provider has reported for this turn so
      # far — what its steps cost, input and output together.
      tokens: 0,
      # RETRY-1, RETRY-4: the waits before each retry of a failed model call;
      # [] retries nothing.
      retry_delays: retry_delays(Keyword.get(opts, :step_retry)),
      # COMPACT-29: the chat's compaction state and the trigger, target and
      # overhead of the mid-turn pass (COMPACT-6, COMPACT-8, CTX-1).
      compaction: Keyword.get(opts, :compaction),
      compaction_trigger: Keyword.get(opts, :compaction_trigger),
      compaction_target: Keyword.get(opts, :compaction_target),
      compaction_overhead: Keyword.get(opts, :compaction_overhead, 0),
      workspace: workspace,
      project: project,
      tool_ctx: %{
        session_id: opts[:session_id],
        turn_id: opts[:turn_id],
        workspace: workspace,
        project: project,
        # ISOL-15: the chat's jail setting, so a tool jails its call according
        # to the chat it runs in; nil (no chat) means the default, which is on.
        jail: opts[:jail],
        loop_opts: opts
      },
      llm_opts: Keyword.get(opts, :llm, %{})
    }

    step(ctx, history, 1)
  end

  # LOOP-3, LOOP-19, LOOP-20, LOOP-22: the limits are checked at the start of
  # every step.
  defp step(ctx, history, step) do
    cond do
      step > ctx.max_steps -> limit(ctx, history, {:steps, ctx.max_steps})
      over_budget?(ctx) -> limit(ctx, history, {:time, ctx.budget_ms})
      over_tokens?(ctx) -> limit(ctx, history, {:tokens, ctx.token_budget})
      true -> run_step(ctx, history, step)
    end
  end

  # LOOP-19: a limit pauses the turn when the option says so, else ends it. The
  # loop reports which limit it was, and the session says so (STOP-1, STOP-2).
  defp limit(%{pause_on_limit: true} = ctx, history, limit), do: pause(ctx, history, limit)
  defp limit(_ctx, _history, limit), do: {:limit, limit}

  # LOOP-19: ask the session to pause the turn and wait for the user's decision.
  # A resume starts the step count, the wall-clock budget and the token total
  # over (LOOP-20, LOOP-22).
  defp pause(ctx, history, limit) do
    send(ctx.session, {:loop_pause, self(), limit})

    receive do
      {:pause_decision, :continue} ->
        step(%{ctx | started_ms: now_ms(), approved_ms: 0, tokens: 0}, history, 1)

      {:pause_decision, :fail} ->
        {:limit, limit}
    end
  end

  # LOOP-20: the wall-clock budget, less the time spent waiting for approvals.
  defp over_budget?(%{budget_ms: nil}), do: false
  defp over_budget?(ctx), do: now_ms() - ctx.started_ms - ctx.approved_ms > ctx.budget_ms

  # LOOP-22, LIMIT-12: the turn's token budget, against what the provider has
  # reported for its steps so far. Without a budget the total is not a limit.
  defp over_tokens?(%{token_budget: nil}), do: false
  defp over_tokens?(ctx), do: ctx.tokens > ctx.token_budget

  defp now_ms, do: System.monotonic_time(:millisecond)

  # RETRY-4: the schedule this turn retries on — the `:step_retry` option's
  # `delays_ms` when the loop was given one, else the host's config, else the
  # default.
  defp retry_delays(nil) do
    :elia
    |> Application.get_env(:step_retry, [])
    |> Keyword.get(:delays_ms, @default_retry_delays)
  end

  defp retry_delays(step_retry) when is_list(step_retry),
    do: Keyword.get(step_retry, :delays_ms, @default_retry_delays)

  @doc "A duration in milliseconds as \"30 minutes\" (LOOP-20)."
  @spec minutes(number()) :: binary()
  def minutes(ms) do
    minutes = ms / 60_000

    text =
      if minutes == trunc(minutes), do: "#{trunc(minutes)}", else: "#{Float.round(minutes, 2)}"

    "#{text} #{if minutes == 1, do: "minute", else: "minutes"}"
  end

  defp run_step(ctx, history, step) do
    # Re-read every step so skills reloaded mid-turn are usable right away, and
    # so the chat's project's skills and AGENTS.md apply (LOOP-1, PROJ-15).
    skills = Elia.Skills.resolve(ctx.skills, ctx.project)
    tools = Map.new(Elia.Skills.tools(skills), &{&1.name, &1})

    # COMPACT-29: the request view is derived fresh every step, from the full
    # history and the chat's compaction state (COMPACT-2, COMPACT-3), and the
    # ladder may run deeper mid-turn.
    ctx = trim(ctx, history)

    request =
      Map.merge(ctx.llm_opts, %{
        system:
          Elia.Skills.system_prompt(skills, Elia.Skills.project_instructions(ctx.workspace)),
        tools: Enum.map(Map.values(tools), &Map.take(&1, [:name, :description, :input_schema])),
        messages: request_messages(ctx, history)
      })

    ask(ctx, request, history, step, tools, 0, 0)
  end

  # RETRY-1, LOOP-23, TIME-1 to TIME-3: the step's model call, measured. A
  # failure the provider marked transient (RETRY-6) is asked again after a wait,
  # until the turn's retry schedule is spent; anything else ends the turn with
  # the error. Nothing from a failed attempt is kept (RETRY-2): the request is
  # the same one, built from the history, and the step count doesn't move. Every
  # request is recorded — `retries` is the attempt's number, `retry_wait_ms` the
  # wait that preceded it (0 for the first).
  defp ask(ctx, request, history, step, tools, retries, retry_wait_ms) do
    attempt = retries + 1
    started_at = DateTime.utc_now()
    started_ms = now_ms()

    case Elia.LLM.stream(request, &send(ctx.session, {:loop_event, &1})) do
      {:error, %Elia.LLM.Error{transient: true} = error} ->
        elapsed = now_ms() - started_ms

        case Enum.at(ctx.retry_delays, retries) do
          nil ->
            record(ctx, step, attempt, :error, started_at, retry_wait_ms, elapsed)
            {:error, exhausted(error, retries)}

          delay ->
            record(ctx, step, attempt, :error, started_at, retry_wait_ms, elapsed)
            retry(ctx, request, history, step, tools, retries, delay, error)
        end

      {:error, reason} ->
        record(ctx, step, attempt, :error, started_at, retry_wait_ms, now_ms() - started_ms)
        {:error, to_string(reason)}

      # A refusal can cut a tool call off mid-input; never run that turn's tools.
      {:ok, %{stop_reason: :refusal}} ->
        record(ctx, step, attempt, :refused, started_at, retry_wait_ms, now_ms() - started_ms)
        :refused

      {:ok, %{message: message, stop_reason: stop_reason, usage: usage}} ->
        model_ms = now_ms() - started_ms
        # The provider's real input count for this request; the session keeps
        # the latest so the context indicator can show it (CTX-6).
        send(ctx.session, {:loop_usage, usage})
        # LOOP-22, LIMIT-12: what this request cost — input and output together —
        # added to the turn's total, which the next step's check is against.
        ctx = %{ctx | tokens: ctx.tokens + (Context.provider_tokens(usage) || 0)}
        append(ctx, message)
        history = history ++ [message]

        case Message.tool_calls(message) do
          [] when stop_reason == :max_tokens ->
            record(ctx, step, attempt, :ok, started_at, retry_wait_ms, model_ms, usage)
            {:error, "The response hit the output token limit"}

          [] ->
            record(ctx, step, attempt, :ok, started_at, retry_wait_ms, model_ms, usage)
            :done

          calls ->
            {results, waits} = run_tools(ctx, tools, calls, stop_reason)
            tool_message = %Message{role: :tool, content: results}

            append(ctx, tool_message)

            record(
              ctx,
              step,
              attempt,
              :ok,
              started_at,
              retry_wait_ms,
              model_ms,
              usage,
              waits
            )

            # LOOP-20: time spent waiting for the user's decisions doesn't count
            # against the wall-clock budget.
            step(
              %{ctx | approved_ms: ctx.approved_ms + waits.approval_ms + waits.answer_ms},
              history ++ [tool_message],
              step + 1
            )
        end
    end
  end

  # TIME-1 to TIME-5: the step's record — the identity of what it measured, its
  # wall-clock stamps, its monotonic durations (TIME-3), the calls that ran
  # (TIME-4) and the tokens the provider reported (TIME-5). `waits` is
  # `run_tools/4`'s report of a step with tools; a step without them has none.
  defp record(
         ctx,
         step,
         attempt,
         outcome,
         started_at,
         retry_wait_ms,
         model_ms,
         usage \\ nil,
         waits \\ nil
       ) do
    waits = waits || %{tool_ms: 0, approval_ms: 0, answer_ms: 0, calls: []}

    entry = %{
      turn: ctx.turn_id,
      turn_started_at: stamp(ctx.turn_started_at),
      step: step,
      attempt: attempt,
      outcome: outcome,
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      model_ms: model_ms,
      tool_ms: waits.tool_ms,
      approval_wait_ms: waits.approval_ms,
      answer_wait_ms: waits.answer_ms,
      retry_wait_ms: retry_wait_ms,
      tools: waits.calls
    }

    send(ctx.session, {:loop_step_timing, Map.merge(entry, usage_counts(usage))})
  end

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(other), do: other

  # TIME-5, CTX-6: input and output as the context indicator counts them, so the
  # same field means the same thing on any provider. A usage report that carries
  # neither records no counts (LOOP-22).
  defp usage_counts(usage) do
    counts =
      %{}
      |> put_count(:input_tokens, Context.provider_input_tokens(usage))
      |> put_count(:output_tokens, Context.provider_output_tokens(usage))

    if map_size(counts) == 0, do: %{}, else: counts
  end

  defp put_count(counts, _key, count) when not is_integer(count), do: counts
  defp put_count(counts, key, count), do: Map.put(counts, key, count)

  # RETRY-3: report the wait, then wait it and try the same step again. The
  # wait doesn't count against the wall-clock budget (RETRY-4, LOOP-20): the
  # loop wasn't working, and the schedule is what bounds the waiting. The next
  # attempt records the wait it followed (TIME-3).
  defp retry(ctx, request, history, step, tools, retries, delay, error) do
    send(ctx.session, {:loop_retry, retry_info(ctx, retries, delay, error)})
    if delay > 0, do: Process.sleep(delay)

    ask(
      %{ctx | approved_ms: ctx.approved_ms + delay},
      request,
      history,
      step,
      tools,
      retries + 1,
      delay
    )
  end

  # RETRY-3: what the session broadcasts and the page shows. `attempt` counts
  # the attempt about to be made, so the first retry is attempt 2.
  defp retry_info(ctx, retries, delay, error) do
    attempt = retries + 2
    of = length(ctx.retry_delays) + 1
    reason = error |> to_string() |> String.trim_trailing(".")

    %{
      attempt: attempt,
      of: of,
      delay_ms: delay,
      reason: reason,
      text: "#{reason}. Retrying #{wait_text(delay)} (attempt #{attempt} of #{of})."
    }
  end

  defp wait_text(0), do: "at once"

  defp wait_text(ms) when ms < 60_000 do
    seconds = div(ms + 999, 1000)
    "in #{seconds} #{if seconds == 1, do: "second", else: "seconds"}"
  end

  defp wait_text(ms), do: "in #{minutes(ms)}"

  # RETRY-5: the failure outlasted the schedule, so the turn ends with it —
  # saying what was done about it, unless nothing was.
  defp exhausted(error, 0), do: to_string(error)
  defp exhausted(error, retries), do: "#{error} (retried #{times(retries)})"

  defp times(1), do: "once"
  defp times(retries), do: "#{retries} times"

  # COMPACT-29: the mid-turn pass. The ladder may run deeper (COMPACT-14..16)
  # towards the target, eliding the cold prefix only — never the turn being run
  # and never a summary (COMPACT-5). Nothing happens under the trigger. When the
  # state advances, the session — the single source of truth — hears about it,
  # so it can save it and broadcast the new annotations and estimate
  # (COMPACT-24..COMPACT-27).
  defp trim(%{compaction: nil} = ctx, _history), do: ctx

  defp trim(ctx, history) do
    state =
      Compaction.trim(history, ctx.compaction,
        trigger: ctx.compaction_trigger,
        target: ctx.compaction_target,
        overhead: ctx.compaction_overhead
      )

    if state == ctx.compaction do
      ctx
    else
      send(ctx.session, {:loop_compaction, state})
      %{ctx | compaction: state}
    end
  end

  # COMPACT-2: the pure derivation of what the model is sent, from the full
  # history and the chat's compaction state. A loop without a compaction state
  # sends the history as it is.
  defp request_messages(%{compaction: nil}, history), do: history

  defp request_messages(ctx, history),
    do: Compaction.view(history, ctx.compaction).messages

  defp append(ctx, message), do: send(ctx.session, {:loop_append, message})

  # LOOP-10, LOOP-20, LOOP-21, TIME-3: returns the step's tool results and what
  # the step cost — how long the loop waited for the user (their approval
  # decisions and an answer to a question, which don't count against the
  # wall-clock budget) and how long running the tools took.
  defp run_tools(ctx, tools, calls, stop_reason) do
    checked = Enum.map(calls, &{&1, check(ctx, tools, &1, stop_reason)})

    needs_approval = for {call, {:ok, _tool, :required}} <- checked, do: call
    {decisions, approved_ms} = await_approval(ctx, needs_approval)

    # LOOP-21: a tool that asks the user is put to them before the step's tools
    # run, so the answer reaches it as `ctx[:answer]`. A call the user denied
    # (APPR-6) is not put to them.
    asking =
      for {call, {:ok, tool, _approval}} <- checked,
          tool.asks_user,
          Map.get(decisions, call.id, :approve) == :approve,
          do: call

    {answers, asked_ms} = await_input(ctx, asking)

    # TIME-3: the tools themselves, apart from the waiting above.
    started_ms = now_ms()

    ran =
      checked
      |> Task.async_stream(
        fn {call, checked_call} -> run_checked(ctx, call, checked_call, decisions, answers) end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.map(fn {:ok, ran} -> ran end)

    waits = %{
      tool_ms: now_ms() - started_ms,
      approval_ms: approved_ms,
      answer_ms: asked_ms,
      calls: for(%{timing: %{} = timing} <- ran, do: timing)
    }

    {Enum.map(ran, & &1.result), waits}
  end

  # LOOP-10, TIME-4: one of the step's calls. A call that runs is timed; a call
  # the user denied, or one that never got past its check (LOOP-4, LOOP-5,
  # LOOP-7, LOOP-8, APPR-6), records no duration.
  defp run_checked(ctx, call, {:ok, tool, _approval}, decisions, answers) do
    if Map.get(decisions, call.id, :approve) == :approve do
      started_ms = now_ms()

      result = execute(ctx, call, tool, Map.get(answers, call.id))

      %{
        result: result,
        timing: %{name: call.name, ms: now_ms() - started_ms, failed: failed?(result)}
      }
    else
      %{
        result: Message.tool_result(call.id, "The user denied this tool call.", true),
        timing: nil
      }
    end
  end

  defp run_checked(_ctx, call, {:error, reason}, _decisions, _answers) do
    %{result: Message.tool_result(call.id, reason, true), timing: nil}
  end

  # TIME-4: a call failed when its result is an error — what LOOP-12 answers a
  # crash with, and what a tool that returns `{:error, output}` gives.
  defp failed?(%{is_error: is_error}), do: is_error == true
  defp failed?(_result), do: false

  defp check(_ctx, _tools, _call, :max_tokens) do
    {:error, "Not run: your output hit the token limit, so this tool call may be incomplete."}
  end

  defp check(_ctx, _tools, %{invalid_input: raw}, _) when is_binary(raw) do
    {:error, Jason.encode!(%{"INVALID_JSON" => raw})}
  end

  defp check(ctx, tools, call, _) do
    with {:ok, tool} <- Map.fetch(tools, call.name) |> or_error("Unknown tool: #{call.name}"),
         :ok <- Tool.validate(tool, call.input) do
      case Tool.approval(tool, call.input, ctx.tool_ctx) do
        {:deny, reason} -> {:error, reason}
        approval -> {:ok, tool, approval}
      end
    end
  end

  defp or_error(:error, message), do: {:error, message}
  defp or_error(ok, _message), do: ok

  defp await_approval(_ctx, []), do: {%{}, 0}

  defp await_approval(ctx, calls) do
    send(ctx.session, {:loop_await_approval, self(), calls})
    started = now_ms()

    receive do
      {:approval_decisions, decisions} -> {decisions, now_ms() - started}
    end
  end

  # LOOP-21, ASK-6: the step's questions, all put to the user at once (APPR-3);
  # the session releases the loop once every one of them has an answer.
  defp await_input(_ctx, []), do: {%{}, 0}

  defp await_input(ctx, calls) do
    send(ctx.session, {:loop_await_input, self(), calls})
    started = now_ms()

    receive do
      {:input_answers, answers} -> {answers, now_ms() - started}
    end
  end

  defp execute(ctx, call, tool, answer) do
    send(ctx.session, {:loop_tool_status, call.id, :running})

    context = ctx.tool_ctx |> Map.put(:call_id, call.id) |> Map.put(:answer, answer)

    {output, is_error} =
      try do
        case Tool.call(tool, call.input, context) do
          {:ok, output} -> {output, false}
          {:error, output} -> {output, true}
        end
      rescue
        e -> {"Tool crashed: " <> Exception.message(e), true}
      end

    send(ctx.session, {:loop_tool_status, call.id, :done})
    Message.tool_result(call.id, output, is_error)
  end
end
