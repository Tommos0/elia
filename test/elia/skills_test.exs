defmodule Elia.SkillsTest do
  use ExUnit.Case, async: true

  alias Elia.Skill
  alias Elia.Skills

  @skill %Skill{name: "lego", description: "Builds", instructions: "Use bricks."}

  @moduletag :tmp_dir

  defp write_agents(dir, content), do: File.write!(Path.join(dir, "AGENTS.md"), content)

  # SKILL-10, SKILL-5
  test "the project section sits between the base prompt and the skills" do
    prompt = Skills.system_prompt([@skill], "Be nice.")

    assert [base, project, skill] = String.split(prompt, "\n\n## ", parts: 3)
    assert base =~ "You are Elia"
    assert project == "Project instructions (AGENTS.md)\nBe nice."
    assert skill =~ "Skill: lego"

    assert [{:base, _}, {:project, _}, {{:skill, @skill}, _}] =
             Skills.system_sections([@skill], "Be nice.")
  end

  # SKILL-10
  test "no project section without project instructions" do
    refute Skills.system_prompt([@skill], nil) =~ "Project instructions"
    assert [{:base, _}, {{:skill, @skill}, _}] = Skills.system_sections([@skill], nil)
  end

  # SKILL-10, SKILL-11
  test "reads AGENTS.md from the root, fresh on every call", %{tmp_dir: dir} do
    write_agents(dir, "\n  First rule.\n\n")
    assert Skills.project_instructions(dir) == "First rule."

    write_agents(dir, "Second rule.")
    assert Skills.project_instructions(dir) == "Second rule."
  end

  # SKILL-11
  test "a missing or blank file adds nothing", %{tmp_dir: dir} do
    assert Skills.project_instructions(dir) == nil

    write_agents(dir, " \n\t\n")
    assert Skills.project_instructions(dir) == nil
  end

  # SKILL-11
  test "an unreadable file adds nothing", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "AGENTS.md"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:result, Skills.project_instructions(dir)})
      end)

    assert_received {:result, nil}
    assert log =~ "Could not read AGENTS.md"
  end

  # SKILL-12
  test "long files are truncated at a character boundary with a note", %{tmp_dir: dir} do
    # "é" is two bytes, so the 32,000 byte cut falls mid-character.
    write_agents(dir, "a" <> String.duplicate("é", 20_000))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        text = Skills.project_instructions(dir)
        send(self(), {:text, text})
      end)

    assert log =~ "truncated"
    assert_received {:text, text}
    assert String.valid?(text)
    assert text =~ "[AGENTS.md truncated"
    assert byte_size(text) < 32_200
  end

  # SKILL-12
  test "files at the cap are left alone", %{tmp_dir: dir} do
    write_agents(dir, String.duplicate("a", 32_000))
    assert Skills.project_instructions(dir) == String.duplicate("a", 32_000)
  end

  # SKILL-13
  test "only the root file is injected", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "docs/agents"))
    File.write!(Path.join(dir, "docs/agents/elixir.md"), "secret")
    write_agents(dir, "See docs/agents/elixir.md")

    assert Skills.project_instructions(dir) == "See docs/agents/elixir.md"
  end
end
