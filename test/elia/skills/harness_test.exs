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

  # SKILL-7, PROJ-16
  test "tools are reload_skills and run_tests" do
    assert Elia.Skills.Harness.tools() |> Enum.map(& &1.name) |> Enum.sort() ==
             ~w(reload_skills run_tests)
  end
end
