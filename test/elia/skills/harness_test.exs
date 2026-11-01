defmodule Elia.Skills.HarnessTest do
  use ExUnit.Case, async: true

  # SKILL-8, PROJ-16
  test "instructions apply in every project: a folder skill over changing code" do
    instructions = Elia.Skills.Harness.instructions()
    assert instructions =~ "skills/<name>/SKILL.md"
    assert instructions =~ "reload_skills"
    assert instructions =~ "run_tests"
    assert instructions =~ "Folder skills need no approval"
    # The spec workflow and the code-change guardrails are self-modification's.
    refute instructions =~ "specs/README.md"
    refute instructions =~ "hot_reload"
  end

  # SKILL-7, PROJ-16, COMPACT-22
  test "tools are reload_skills, run_tests and update_ledger" do
    assert Elia.Skills.Harness.tools() |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(reload_skills run_tests update_ledger)
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
