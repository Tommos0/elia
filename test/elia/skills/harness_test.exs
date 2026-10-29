defmodule Elia.Skills.HarnessTest do
  use ExUnit.Case, async: true

  # SKILL-9
  test "instructions point the model at the specs" do
    instructions = Elia.Skills.Harness.instructions()
    assert instructions =~ "specs/README.md"
    assert instructions =~ "requirement IDs"
  end
end
