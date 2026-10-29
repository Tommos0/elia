defmodule Elia.LLM.Context do
  @moduledoc """
  Tracks the token breakdown of the request context a chat would send to the
  model: the system prompt (agent instructions + skill instructions), the tool
  definitions and every message.

  The struct is an accumulator: `new/2` seeds it from skills and a message
  list, `add/2` folds in one more message, and `breakdown/1` turns it into a
  tree of buckets. Each piece of the context lands in exactly one bucket, so
  the bucket totals sum to the overall estimate shown by the context indicator
  (see `EliaWeb.ChatLive` and the `CTX` spec).

  Buckets:

    * `:system` "System prompt" - children "Agent instructions" and one
      "Skill: <name>" per skill
    * `:tools` "Tool definitions"
    * `:messages` "Messages" - children "User", "Assistant", "Reasoning"
    * `:files` "Files" - `read_file`/`write_file`/`edit_file` calls & results
    * `:shell` "Shell" - `shell` calls & results
    * `:other_tools` "Other tools" - any other tool calls & results
  """

  alias Elia.LLM.{Message, Tokens}
  alias Elia.Skills

  @file_tools ~w(read_file write_file edit_file)
  @message_parts [user: "User", assistant: "Assistant", reasoning: "Reasoning"]
  @tool_parts [files: "Files", shell: "Shell", other_tools: "Other tools"]

  # system/tools: the fixed buckets derived from skills; messages: message
  # count; names: tool_call_id => tool name, so results land with their call;
  # tally: bucket id => {count, tokens}.
  defstruct system: nil, tools: nil, messages: 0, names: %{}, tally: %{}

  @type t :: %__MODULE__{}

  @type bucket :: %{
          id: atom() | binary(),
          label: binary(),
          count: non_neg_integer(),
          tokens: non_neg_integer(),
          children: [bucket()]
        }

  @type breakdown :: %{total: non_neg_integer(), buckets: [bucket()]}

  @doc "A context of `messages` under `skills` (default: current skills)."
  @spec new([Message.t()], [Elia.Skill.t()]) :: t()
  def new(messages \\ [], skills \\ Skills.current()) do
    %__MODULE__{}
    |> put_skills(skills)
    |> add_messages(messages)
  end

  @doc "Token breakdown for `messages` under `skills` (default: current skills)."
  @spec build([Message.t()], [Elia.Skill.t()]) :: breakdown()
  def build(messages, skills \\ Skills.current()), do: messages |> new(skills) |> breakdown()

  @doc "Replaces the system-prompt and tool-definition buckets for `skills`."
  @spec put_skills(t(), [Elia.Skill.t()]) :: t()
  def put_skills(%__MODULE__{} = context, skills) do
    [base | sections] = Skills.system_sections(skills)

    skill_children =
      Enum.zip_with(skills, sections, fn skill, text ->
        %{
          id: "skill:#{skill.name}",
          label: "Skill: #{skill.name}",
          count: 1,
          tokens: Tokens.estimate(text)
        }
      end)

    children = [
      %{id: :base, label: "Agent instructions", count: 1, tokens: Tokens.estimate(base)}
      | skill_children
    ]

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
    %{total: buckets |> Enum.map(&bucket_tokens/1) |> Enum.sum(), buckets: buckets}
  end

  @doc "A bucket's tokens, summing its children when it has any."
  @spec bucket_tokens(bucket()) :: non_neg_integer()
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

  defp add_block(context, %{type: :reasoning, text: text}),
    do: tally(context, :reasoning, Tokens.estimate(text))

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
