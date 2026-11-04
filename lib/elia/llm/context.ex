defmodule Elia.LLM.Context do
  @moduledoc """
  Tracks the token breakdown of the request context a chat would send to the
  model: the system prompt (agent instructions + project instructions + skill instructions), the tool
  definitions and every message.

  The struct is an accumulator: `new/2` seeds it from skills and a message
  list, `add/2` folds in one more message, and `breakdown/1` turns it into a
  tree of buckets. Each piece of the context lands in exactly one bucket, so
  the bucket totals sum to the overall estimate shown by the context indicator
  (see `EliaWeb.ChatLive` and the `CTX` spec).

  Buckets:

    * `:system` "System prompt" - children "Agent instructions", "Project
      instructions" (when `AGENTS.md` is injected) and one "Skill: <name>"
      per skill
    * `:tools` "Tool definitions"
    * `:messages` "Messages" - children "User", "Assistant", "Reasoning"
    * `:files` "Files" - `read_file`/`write_file`/`edit_file`/`list_files`/
      `delete_file` calls & results
    * `:shell` "Shell" - `shell` calls & results
    * `:other_tools` "Other tools" - any other tool calls & results
    * `:adjustment` "Provider adjustment" - the gap to the provider's last
      reported figure, when there is one (may be negative)
  """

  alias Elia.LLM.{Message, Tokens}
  alias Elia.Skills

  @file_tools ~w(read_file write_file edit_file list_files delete_file)
  @message_parts [user: "User", assistant: "Assistant", reasoning: "Reasoning"]
  @tool_parts [files: "Files", shell: "Shell", other_tools: "Other tools"]

  # system/tools: the fixed buckets derived from skills; messages: message
  # count; names: tool_call_id => tool name, so results land with their call;
  # tally: bucket id => {count, tokens}; adjustment: provider figure minus our
  # estimate for the last reported request (CTX-10).
  defstruct system: nil, tools: nil, messages: 0, names: %{}, tally: %{}, adjustment: 0

  @type t :: %__MODULE__{}

  @type bucket :: %{
          id: atom() | binary(),
          label: binary(),
          count: non_neg_integer(),
          tokens: integer(),
          children: [bucket()]
        }

  @type breakdown :: %{total: non_neg_integer(), buckets: [bucket()]}

  @doc "A context of `messages` under `skills` (default: current skills) and project instructions."
  @spec new([Message.t()], [Elia.Skill.t()], binary() | nil) :: t()
  def new(messages \\ [], skills \\ Skills.current(), project \\ Skills.project_instructions()) do
    %__MODULE__{}
    |> put_skills(skills, project)
    |> add_messages(messages)
  end

  @doc "Token breakdown for `messages` under `skills` (default: current skills) and project instructions."
  @spec build([Message.t()], [Elia.Skill.t()], binary() | nil) :: breakdown()
  def build(messages, skills \\ Skills.current(), project \\ Skills.project_instructions()),
    do: messages |> new(skills, project) |> breakdown()

  @doc """
  Replaces the system-prompt and tool-definition buckets for `skills` and the
  project instructions (default: the workspace's `AGENTS.md`, if any).
  """
  @spec put_skills(t(), [Elia.Skill.t()], binary() | nil) :: t()
  def put_skills(
        %__MODULE__{} = context,
        skills,
        project \\ Skills.project_instructions()
      ) do
    children =
      skills
      |> Skills.system_sections(project)
      |> Enum.map(fn {kind, text} ->
        {id, label} = section_label(kind)
        %{id: id, label: label, count: 1, tokens: Tokens.estimate(text)}
      end)

    # Deduplicated by name, as `Elia.Agent.Loop` sends them.
    tools = skills |> Skills.tools() |> Map.new(&{&1.name, &1}) |> Map.values()

    %{
      context
      | system: %{
          id: :system,
          label: "System prompt",
          count: length(children),
          children: children
        },
        tools: %{
          id: :tools,
          label: "Tool definitions",
          count: length(tools),
          tokens: tools |> Enum.map(&tool_tokens/1) |> Enum.sum()
        }
    }
  end

  defp section_label(:base), do: {:base, "Agent instructions"}
  defp section_label(:project), do: {:project, "Project instructions"}
  defp section_label({:skill, skill}), do: {"skill:#{skill.name}", "Skill: #{skill.name}"}

  @doc "Folds `messages` into the context, in order."
  @spec add_messages(t(), [Message.t()]) :: t()
  def add_messages(context, messages), do: Enum.reduce(messages, context, &add(&2, &1))

  @doc "Folds one more message into the context."
  @spec add(t(), Message.t()) :: t()
  def add(%__MODULE__{} = context, %Message{} = message) do
    context = %{context | messages: context.messages + 1}

    case message do
      %Message{role: :user} ->
        tally(context, :user, Tokens.estimate_message(message))

      %Message{role: :assistant, content: content} ->
        Enum.reduce(content, context, &add_block(&2, &1))

      %Message{role: :tool, content: content} ->
        Enum.reduce(content, context, &add_result(&2, &1))

      _ ->
        context
    end
  end

  @doc "The bucket tree and the overall estimate."
  @spec breakdown(t()) :: breakdown()
  def breakdown(%__MODULE__{} = context) do
    messages = %{
      id: :messages,
      label: "Messages",
      count: context.messages,
      children: parts(context, @message_parts)
    }

    buckets = [context.system, context.tools, messages | parts(context, @tool_parts)]
    estimate = buckets |> Enum.map(&bucket_tokens/1) |> Enum.sum()

    # CTX-10: the total never drops below zero, so a large negative
    # adjustment (e.g. after skills shrank) is capped.
    adjustment = max(context.adjustment, -estimate)

    buckets =
      if adjustment == 0,
        do: buckets,
        else:
          buckets ++
            [%{id: :adjustment, label: "Provider adjustment", count: 0, tokens: adjustment}]

    %{total: estimate + adjustment, buckets: buckets}
  end

  @doc """
  Calibrates the estimate against the provider's report of the last request
  (CTX-10). `usage` carries the provider's counts and the session's
  `"estimated_input_tokens"` for the same request; the difference becomes the
  adjustment. Without both (or with `nil`), the adjustment is cleared.
  """
  @spec calibrate(t(), map() | nil) :: t()
  def calibrate(%__MODULE__{} = context, usage) do
    adjustment =
      with provider when is_integer(provider) <- provider_input_tokens(usage),
           estimate when is_integer(estimate) <- usage["estimated_input_tokens"] do
        provider - estimate
      else
        _ -> 0
      end

    %{context | adjustment: adjustment}
  end

  @doc "A bucket's tokens, summing its children when it has any."
  @spec bucket_tokens(bucket()) :: integer()
  def bucket_tokens(%{children: children}),
    do: children |> Enum.map(&bucket_tokens/1) |> Enum.sum()

  def bucket_tokens(%{tokens: tokens}), do: tokens

  @doc """
  Input tokens the provider reported for the last request. Anthropic's
  `input_tokens` excludes prompt-cache reads and writes, which are still part
  of the context, so they are added back.
  """
  @spec provider_input_tokens(map() | nil) :: non_neg_integer() | nil
  def provider_input_tokens(%{"input_tokens" => input} = usage) when is_integer(input) do
    input + (usage["cache_read_input_tokens"] || 0) + (usage["cache_creation_input_tokens"] || 0)
  end

  def provider_input_tokens(%{"prompt_tokens" => prompt}) when is_integer(prompt), do: prompt
  def provider_input_tokens(_usage), do: nil

  @doc """
  Output tokens the provider reported for the last request: Anthropic's
  `output_tokens`, OpenRouter's `completion_tokens`.
  """
  @spec provider_output_tokens(map() | nil) :: non_neg_integer() | nil
  def provider_output_tokens(%{"output_tokens" => output}) when is_integer(output), do: output
  def provider_output_tokens(%{"completion_tokens" => output}) when is_integer(output), do: output
  def provider_output_tokens(_usage), do: nil

  @doc """
  What the provider reported this request cost in tokens: input
  (`provider_input_tokens/1`) and output (`provider_output_tokens/1`) together.
  `nil` when it reported neither, so nothing is added to a turn's total by a
  report that carries no counts — and a report with only one of the two counts
  what it does carry (LOOP-22, LIMIT-12).
  """
  @spec provider_tokens(map() | nil) :: non_neg_integer() | nil
  def provider_tokens(usage) do
    values = [provider_input_tokens(usage), provider_output_tokens(usage)]

    if Enum.any?(values, &is_integer/1), do: Enum.sum(Enum.filter(values, &is_integer/1))
  end

  ## Tally

  defp tool_tokens(tool) do
    spec = %{name: tool.name, description: tool.description, input_schema: tool.input_schema}

    case Jason.encode(spec) do
      {:ok, json} -> Tokens.estimate(json)
      _ -> 0
    end
  end

  defp add_block(context, %{type: :text, text: text}),
    do: tally(context, :assistant, Tokens.estimate(text))

  defp add_block(context, %{type: :reasoning} = block),
    do: tally(context, :reasoning, Tokens.estimate_block(block))

  defp add_block(context, %{type: :tool_call, id: id, name: name} = block) do
    %{context | names: Map.put(context.names, id, name)}
    |> tally(tool_bucket(name), Tokens.estimate_block(block))
  end

  # Opaque blocks still occupy context; count them with the assistant text.
  defp add_block(context, block), do: tally(context, :assistant, Tokens.estimate_block(block))

  defp add_result(context, %{type: :tool_result, tool_call_id: id} = block) do
    tally(context, tool_bucket(Map.get(context.names, id)), Tokens.estimate_block(block))
  end

  defp add_result(context, _block), do: context

  defp tally(context, id, tokens) do
    tally =
      Map.update(context.tally, id, {1, tokens}, fn {count, total} ->
        {count + 1, total + tokens}
      end)

    %{context | tally: tally}
  end

  defp parts(context, parts) do
    for {id, label} <- parts, {count, tokens} <- [context.tally[id]] do
      %{id: id, label: label, count: count, tokens: tokens}
    end
  end

  defp tool_bucket(name) when name in @file_tools, do: :files
  defp tool_bucket("shell"), do: :shell
  defp tool_bucket(_name), do: :other_tools
end
