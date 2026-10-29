defmodule Elia.LLM.ContextTest do
  use ExUnit.Case, async: true

  alias Elia.LLM.{Context, Message, Tokens}
  alias Elia.Skill

  defp skills do
    [
      %Skill{
        name: "lego",
        description: "Builds with bricks",
        instructions: "Use the `lego` tool."
      },
      %Skill{
        name: "draw",
        description: "Draws shapes",
        instructions: String.duplicate("circle ", 100)
      }
    ]
  end

  # CTX-3: bucket totals sum to the overall estimate, with each piece counted once.
  test "build returns buckets whose totals sum to the overall estimate" do
    messages = [
      Message.user("hello there"),
      %Message{
        role: :assistant,
        content: [
          %{type: :text, text: String.duplicate("hi ", 20)},
          %{type: :reasoning, text: String.duplicate("hmm ", 10)},
          %{type: :tool_call, id: "r1", name: "read_file", input: %{"path" => "a.txt"}}
        ]
      },
      %Message{
        role: :tool,
        content: [
          %{
            type: :tool_result,
            tool_call_id: "r1",
            content: String.duplicate("file body ", 50),
            is_error: false
          }
        ]
      },
      %Message{
        role: :assistant,
        content: [
          %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "ls"}}
        ]
      },
      %Message{
        role: :tool,
        content: [
          %{type: :tool_result, tool_call_id: "s1", content: "src\nlib\n", is_error: false}
        ]
      },
      %Message{role: :assistant, content: [%{type: :text, text: "done"}]}
    ]

    breakdown = Context.build(messages, skills())
    assert breakdown.total == Enum.sum(Enum.map(breakdown.buckets, &bucket_tokens(&1)))

    by_id = Map.new(breakdown.buckets, &{&1.id, &1})
    assert Map.has_key?(by_id, :system)
    assert Map.has_key?(by_id, :tools)
    assert Map.has_key?(by_id, :messages)
    assert Map.has_key?(by_id, :files)
    assert Map.has_key?(by_id, :shell)
    refute Map.has_key?(by_id, :other_tools)
  end

  # CTX-4: the system bucket lists agent instructions and one child per skill.
  test "system bucket has an agent-instructions child and one child per skill" do
    breakdown = Context.build([], skills())

    system = Enum.find(breakdown.buckets, &(&1.id == :system))
    assert system.label == "System prompt"
    assert [%{id: :base, label: "Agent instructions"} | skill_children] = system.children
    assert Enum.map(skill_children, & &1.label) == ["Skill: lego", "Skill: draw"]

    # CTX-3: the sized sections are exactly the system prompt the loop sends.
    sections = Elia.Skills.system_sections(skills())
    assert Enum.join(sections) == Elia.Skills.system_prompt(skills())
    assert Enum.map(system.children, & &1.tokens) == Enum.map(sections, &Tokens.estimate/1)
  end

  # CTX-4: tool definitions are sized once per name, as the loop sends them.
  test "duplicate tool names are counted once" do
    run = fn _ -> {:ok, ""} end
    tool = %Elia.Tool{name: "make", description: "Run", input_schema: %{}, run: run}

    skills = [
      %Skill{name: "a", description: "A", instructions: "", tools: [tool]},
      %Skill{name: "b", description: "B", instructions: "", tools: [tool]}
    ]

    assert %{count: 1} = Enum.find(Context.build([], skills).buckets, &(&1.id == :tools))
  end

  # CTX-8: folding messages in one at a time matches building from the list.
  test "add/2 incrementally matches build/2" do
    messages = [
      Message.user("hi"),
      %Message{
        role: :assistant,
        content: [%{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "ls"}}]
      },
      %Message{
        role: :tool,
        content: [%{type: :tool_result, tool_call_id: "s1", content: "lib", is_error: false}]
      }
    ]

    incremental =
      Enum.reduce(messages, Context.new([], skills()), &Context.add(&2, &1))

    assert Context.breakdown(incremental) == Context.build(messages, skills())
    assert %{count: 2} = Enum.find(Context.breakdown(incremental).buckets, &(&1.id == :shell))
  end

  # CTX-8: swapping skills replaces only the system and tool buckets.
  test "put_skills/2 keeps the message tally" do
    context = Context.new([Message.user("hello")], skills())
    swapped = Context.put_skills(context, [])

    assert [%{id: :base}] = hd(Context.breakdown(swapped).buckets).children

    assert Enum.at(Context.breakdown(swapped).buckets, 2) ==
             Enum.at(Context.breakdown(context).buckets, 2)
  end

  # CTX-5: file tools count under Files, shell under Shell.
  test "file and shell tool calls and results land in their own buckets" do
    messages = [
      %Message{
        role: :assistant,
        content: [
          %{
            type: :tool_call,
            id: "w1",
            name: "write_file",
            input: %{"path" => "a", "content" => "x"}
          },
          %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "echo x"}}
        ]
      },
      %Message{
        role: :tool,
        content: [
          %{type: :tool_result, tool_call_id: "w1", content: "wrote a", is_error: false},
          %{type: :tool_result, tool_call_id: "s1", content: "x", is_error: false}
        ]
      }
    ]

    breakdown = Context.build(messages, skills())
    by_id = Map.new(breakdown.buckets, &{&1.id, &1})

    assert %{count: 2, label: "Files"} = by_id.files
    assert %{count: 2, label: "Shell"} = by_id.shell
    assert by_id.files.tokens > 0
    assert by_id.shell.tokens > 0
  end

  # CTX-5: results without a known call fall back to Other tools.
  test "unrouted results and unknown tools go to Other tools" do
    messages = [
      %Message{
        role: :assistant,
        content: [%{type: :tool_call, id: "x1", name: "weird", input: %{}}]
      },
      %Message{
        role: :tool,
        content: [
          %{type: :tool_result, tool_call_id: "ghost", content: "orphan", is_error: false}
        ]
      }
    ]

    breakdown = Context.build(messages, skills())
    by_id = Map.new(breakdown.buckets, &{&1.id, &1})
    assert %{label: "Other tools", count: 2} = by_id.other_tools
  end

  # CTX-4: tool definitions are counted from the skills' tools.
  test "the tool-definitions bucket reflects the skills' tools" do
    run = fn _ -> {:ok, ""} end

    skills = [
      %Skill{
        name: "builder",
        description: "Builds",
        instructions: "Use the tools.",
        tools: [
          %Elia.Tool{
            name: "make",
            description: "Run a build",
            input_schema: %{"type" => "object"},
            run: run
          },
          %Elia.Tool{
            name: "sh",
            description: "Run a command",
            input_schema: %{"type" => "object"},
            run: run
          }
        ]
      }
    ]

    breakdown = Context.build([], skills)
    tools = Enum.find(breakdown.buckets, &(&1.id == :tools))
    assert %{label: "Tool definitions", count: 2} = tools
    assert tools.tokens > 0
  end

  # CTX-6: provider-reported input tokens include Anthropic's prompt-cache tokens.
  test "provider_input_tokens reads input_tokens plus cache tokens, or prompt_tokens" do
    assert Context.provider_input_tokens(%{"input_tokens" => 1234}) == 1234

    assert Context.provider_input_tokens(%{
             "input_tokens" => 5,
             "cache_read_input_tokens" => 12_000,
             "cache_creation_input_tokens" => 300
           }) == 12_305

    assert Context.provider_input_tokens(%{"prompt_tokens" => 42}) == 42
    assert Context.provider_input_tokens(%{"input_tokens" => 5, "prompt_tokens" => 7}) == 5
    assert Context.provider_input_tokens(%{}) == nil
    assert Context.provider_input_tokens(nil) == nil
  end

  defp bucket_tokens(bucket), do: Context.bucket_tokens(bucket)
end
