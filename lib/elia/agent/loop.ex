defmodule Elia.Agent.Loop do
  @moduledoc """
  The agentic loop: call the model, run requested tools, feed results back,
  repeat until the model stops asking for tools. When it stops, verify the
  turn's changes (`Elia.Harness.verify/1`) and, if they were rolled back,
  tell the model and keep going.

  Runs inside a task owned by `Elia.Agent.Session` and reports to it with
  plain messages:

    * `{:loop_event, event}` - streaming `t:Elia.LLM.Provider.event/0`s
    * `{:loop_append, message}` - a message to append to the history
    * `{:loop_tool_status, call_id, status}` - `:running` or `:done`
    * `{:loop_await_approval, task_pid, calls}` - reply with
      `{:approval_decisions, %{call_id => :approve | :deny}}`

  Options: `:session_id`, `:turn_id`, `:skills` (fixed skill list instead of
  the registry), `:verify` (default `true`), `:llm` (extra request fields).
  """

  alias Elia.LLM.Message
  alias Elia.Tool

  @max_steps 50
  @max_verify_failures 2

  @type result :: :done | :refused | {:error, term()}

  @spec run(pid(), [Message.t()], keyword()) :: result()
  def run(session, history, opts \\ []) do
    ctx = %{
      session: session,
      skills: Keyword.get(opts, :skills),
      verify: Keyword.get(opts, :verify, true),
      verify_failures: 0,
      tool_ctx: %{session_id: opts[:session_id], turn_id: opts[:turn_id]},
      llm_opts: Keyword.get(opts, :llm, %{})
    }

    step(ctx, history, 1)
  end

  defp step(_ctx, _history, step) when step > @max_steps do
    {:error, "Stopped after #{@max_steps} steps without finishing"}
  end

  defp step(ctx, history, step) do
    # Re-read every step so skills reloaded mid-turn are usable right away.
    skills = ctx.skills || Elia.Skills.current()
    tools = Map.new(Elia.Skills.tools(skills), &{&1.name, &1})

    request =
      Map.merge(ctx.llm_opts, %{
        system: Elia.Skills.system_prompt(skills),
        tools: Enum.map(Map.values(tools), &Map.take(&1, [:name, :description, :input_schema])),
        messages: history
      })

    case Elia.LLM.stream(request, &send(ctx.session, {:loop_event, &1})) do
      {:error, reason} ->
        {:error, reason}

      # A refusal can cut a tool call off mid-input; never run that turn's tools.
      {:ok, %{stop_reason: :refusal}} ->
        :refused

      {:ok, %{message: message, stop_reason: stop_reason}} ->
        append(ctx, message)
        history = history ++ [message]

        case Message.tool_calls(message) do
          [] when stop_reason == :max_tokens ->
            {:error, "The response hit the output token limit"}

          [] ->
            finish(ctx, history, step)

          calls ->
            tool_message = %Message{
              role: :tool,
              content: run_tools(ctx, tools, calls, stop_reason)
            }

            append(ctx, tool_message)
            step(ctx, history ++ [tool_message], step + 1)
        end
    end
  end

  defp finish(%{verify: false}, _history, _step), do: :done

  defp finish(ctx, history, step) do
    case Elia.Harness.verify(ctx.tool_ctx.turn_id) do
      result when result in [:ok, :unchanged] ->
        :done

      {:error, reason} ->
        {:error, reason}

      {:rolled_back, _output} when ctx.verify_failures + 1 >= @max_verify_failures ->
        {:error,
         "Tests kept failing after changes to Elixir code; the workspace was rolled back."}

      {:rolled_back, output} ->
        message =
          Message.harness("""
          `mix test` failed after your changes to Elixir files, so the workspace was \
          rolled back to the checkpoint taken at the start of this turn. Fix the \
          problem and redo the change, or explain the failure to the user.

          #{Elia.Shell.truncate(output, 20_000)}
          """)

        append(ctx, message)
        step(%{ctx | verify_failures: ctx.verify_failures + 1}, history ++ [message], step + 1)
    end
  end

  defp append(ctx, message), do: send(ctx.session, {:loop_append, message})

  defp run_tools(ctx, tools, calls, stop_reason) do
    checked = Enum.map(calls, &{&1, check(ctx, tools, &1, stop_reason)})

    needs_approval = for {call, {:ok, _tool, :required}} <- checked, do: call
    decisions = await_approval(ctx, needs_approval)

    checked
    |> Task.async_stream(
      fn
        {call, {:ok, tool, _approval}} ->
          if Map.get(decisions, call.id, :approve) == :approve do
            execute(ctx, call, tool)
          else
            Message.tool_result(call.id, "The user denied this tool call.", true)
          end

        {call, {:error, reason}} ->
          Message.tool_result(call.id, reason, true)
      end,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

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

  defp await_approval(_ctx, []), do: %{}

  defp await_approval(ctx, calls) do
    send(ctx.session, {:loop_await_approval, self(), calls})

    receive do
      {:approval_decisions, decisions} -> decisions
    end
  end

  defp execute(ctx, call, tool) do
    send(ctx.session, {:loop_tool_status, call.id, :running})

    {output, is_error} =
      try do
        case Tool.call(tool, call.input, ctx.tool_ctx) do
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
