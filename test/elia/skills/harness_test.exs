defmodule Elia.Skills.HarnessTest do
  use ExUnit.Case, async: true

  # SKILL-8, PROJ-16, VERIFY-11
  test "instructions apply in every project: a folder skill over changing code" do
    instructions = Elia.Skills.Harness.instructions()
    assert instructions =~ "skills/<name>/SKILL.md"
    assert instructions =~ "reload_skills"
    # VERIFY-11: a test run is the shell tool's, not this skill's.
    assert instructions =~ "mix test"
    assert instructions =~ "mix precommit"
    refute instructions =~ "run_tests"
    assert instructions =~ "Folder skills need no approval"
    # The spec workflow and the code-change guardrails are self-modification's.
    refute instructions =~ "specs/README.md"
    refute instructions =~ "hot_reload"
  end

  # SKILL-7, PROJ-16, COMPACT-22, VERIFY-11
  test "tools are reload_skills and update_ledger, with no test runner" do
    assert Elia.Skills.Harness.tools() |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(reload_skills update_ledger)
  end

  # COMPACT-34
  test "the ledger guidance says to write facts as you go, not at the end" do
    instructions = Elia.Skills.Harness.instructions()

    assert instructions =~ "update_ledger"
    assert instructions =~ "as you work, not at the end"
    assert instructions =~ "reasoning is the first thing compaction drops"

    tool = Enum.find(Elia.Skills.Harness.tools(), &(&1.name == "update_ledger"))

    assert tool.description =~ "as you go, not at the end"
    assert tool.description =~ "reasoning is the first thing compaction drops"
  end

  # COMPACT-22, COMPACT-21
  test "update_ledger appends exact facts to the chat's compaction ledger" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    {:ok, pid} = Elia.Agent.ensure_started(id, persist: true)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    tool = Enum.find(Elia.Skills.Harness.tools(), &(&1.name == "update_ledger"))

    assert {:ok, message} =
             Elia.Tool.call(tool, %{"entries" => ["lib/elia/llm/compaction.ex"]}, %{
               session_id: id
             })

    assert message =~ "ledger"
    assert Elia.Agent.snapshot(id).compaction.ledger == ["lib/elia/llm/compaction.ex"]

    # A tool call with no chat to record in says so, rather than crashing.
    assert {:error, _} = Elia.Tool.call(tool, %{"entries" => ["x"]}, %{})
  end
end
