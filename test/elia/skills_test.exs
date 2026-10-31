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

  defp project(folder), do: %{id: "prj-1", name: "Other", folder: folder, harness?: false}

  defp write_skill(root, name) do
    dir = Path.join([root, "skills", name])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{name} does things\n---\nUse it.\n"
    )

    dir
  end

  defp names(skills), do: Enum.map(skills, & &1.name)

  # SKILL-7, PROJ-17
  test "self-modification is a built-in skill of Elia's own project only", %{tmp_dir: dir} do
    assert "self-modification" in names(Skills.current())

    {own, _errors} = Skills.for_project(nil)
    assert "self-modification" in names(own)
    assert "hot_reload" in Enum.map(Skills.tools(own), & &1.name)

    {other, _errors} = Skills.for_project(project(dir))
    refute "self-modification" in names(other)
    refute "hot_reload" in Enum.map(Skills.tools(other), & &1.name)
  end

  # PROJ-16, PROJ-18
  test "for_project/1 is Elia's skills plus the project's own", %{tmp_dir: dir} do
    write_skill(dir, "project-skill")

    {skills, errors} = Skills.for_project(project(dir))

    assert "project-skill" in names(skills)
    # Elia's own folder skills and built-ins are still there.
    assert "shell" in names(skills)
    assert "harness" in names(skills)
    refute Enum.any?(errors, fn {folder, _} -> folder =~ "project-skill" end)
  end

  # PROJ-18
  test "a project whose folder is Elia's root loads its skills once" do
    {own, _errors} = Skills.for_project(Elia.Projects.harness())

    {same, _errors} =
      Skills.for_project(%{
        id: "same",
        name: "Same",
        folder: Elia.Workspace.root(),
        harness?: false
      })

    # The same folder skills, once, and no `self-modification` for the other
    # project: the folder is not scanned a second time.
    assert names(same) == Enum.reject(names(own), &(&1 == "self-modification"))
    assert names(same) == Enum.uniq(names(same))
  end

  # PROJ-19
  test "a broken project skill folder is reported and the rest still load", %{tmp_dir: dir} do
    write_skill(dir, "good-skill")
    File.mkdir_p!(Path.join([dir, "skills", "broken"]))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:skills, Skills.for_project(project(dir))})
      end)

    assert_received {:skills, {skills, errors}}
    assert "good-skill" in names(skills)

    assert Enum.any?(errors, fn {folder, reason} ->
             folder =~ "skills/broken" and reason =~ "SKILL.md"
           end)

    assert log =~ "broken"
  end

  # SKILL-3, PROJ-19
  test "a project skill that clashes with Elia's is left out", %{tmp_dir: dir} do
    write_skill(dir, "shell")
    write_skill(dir, "fine")

    {skills, errors} = Skills.for_project(project(dir))

    assert "fine" in names(skills)
    assert Enum.count(skills, &(&1.name == "shell")) == 1
    assert Enum.any?(errors, fn {_, reason} -> reason =~ "skill named shell already exists" end)
  end

  # PROJ-20
  test "a skill written into the project applies on the next call", %{tmp_dir: dir} do
    {before, _errors} = Skills.for_project(project(dir))
    refute "later" in names(before)

    write_skill(dir, "later")

    {after_, _errors} = Skills.for_project(project(dir))
    assert "later" in names(after_)
  end

  # SKILL-14, PROJ-21
  test "resolve/2 takes a list, a function or nil against a project", %{tmp_dir: dir} do
    write_skill(dir, "project-skill")
    project = project(dir)

    assert Skills.resolve([@skill], project) == [@skill]
    assert Skills.resolve(fn -> [@skill] end, project) == [@skill]

    assert "project-skill" in names(Skills.resolve(nil, project))
    refute "self-modification" in names(Skills.resolve(nil, project))
  end

  # SKILL-14
  test "resolve/1 defaults the project to Elia's own" do
    assert Skills.resolve([@skill]) == [@skill]
    assert Skills.resolve(fn -> [@skill] end) == [@skill]
    assert "self-modification" in names(Skills.resolve(nil))
  end
end
