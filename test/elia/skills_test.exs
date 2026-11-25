defmodule Elia.SkillsTest do
  use ExUnit.Case, async: true

  alias Elia.Skill
  alias Elia.Skills

  @skill %Skill{name: "lego", description: "Builds", instructions: "Use bricks."}

  @moduletag :tmp_dir

  defp write_agents(dir, content), do: File.write!(Path.join(dir, "AGENTS.md"), content)

  # SKILL-1, SKILL-5, SKILL-10
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

  # SECRET-12, SKILL-5, PROJ-15: a project's secrets are named — never valued —
  # between the project instructions and the skills, and there is no such section
  # for a project that has none.
  test "the secrets section names a project's secrets and carries no value" do
    sections = Skills.system_sections([@skill], "Be nice.", ["STRIPE_KEY", "DB_PASSWORD"])

    assert [{:base, _}, {:project, _}, {:secrets, secrets}, {{:skill, @skill}, _}] = sections
    assert secrets =~ "## Project secrets"
    assert secrets =~ "`STRIPE_KEY`, `DB_PASSWORD`"

    prompt = Skills.system_prompt([@skill], "Be nice.", ["STRIPE_KEY"])
    assert prompt =~ "## Project secrets"
    assert [_, _, secrets, _] = String.split(prompt, "\n\n## ", parts: 4)
    assert secrets =~ "STRIPE_KEY"

    assert [{:base, _}, {:project, _}, {{:skill, @skill}, _}] =
             Skills.system_sections([@skill], "Be nice.", [])

    refute Skills.system_prompt([@skill], "Be nice.", []) =~ "Project secrets"
  end

  # SKILL-15, SKILL-16
  test "the base prompt asks for occasional progress notes" do
    [{:base, base}] = Skills.system_sections([], nil)

    # SKILL-15: an occasional, short note in its normal reply on what it is
    # doing at the moment — occasional, not one per tool call.
    assert base =~ "every so often"
    assert base =~ "one-sentence note"
    assert base =~ "not one per tool call"

    # SKILL-16: it says what it is about to run when a step will take a while.
    assert base =~ "about to run"
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

  # SKILL-18: a marker standing in for whatever a refused file could hold. It
  # must not appear in the log — which is only possible if the file was never
  # read at all.
  @sentinel "SENTINEL-never-in-the-prompt"

  defp refused(dir) do
    ExUnit.CaptureLog.capture_log(fn ->
      send(self(), {:instructions, Skills.project_instructions(dir)})
    end)
  end

  # SKILL-17, SKILL-18, WS-8: a `AGENTS.md` that is a link resolving out of the
  # folder adds no section, is named with where it goes, and its target is never
  # read — so none of what it holds can reach the prompt or the log.
  test "an AGENTS.md link out of the folder adds nothing", %{tmp_dir: dir} do
    outside = Path.join(System.tmp_dir!(), "elia-agents-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    target = Path.join(outside, "secrets.md")
    File.write!(target, @sentinel)
    File.ln_s!(target, Path.join(dir, "AGENTS.md"))

    on_exit(fn -> File.rm_rf!(outside) end)

    log = refused(dir)

    assert_received {:instructions, nil}
    assert log =~ "Refusing AGENTS.md"
    assert log =~ Path.join(dir, "AGENTS.md")
    assert log =~ target
    refute log =~ @sentinel
  end

  # SKILL-17, SKILL-18, WS-7: a link into a protected location is refused as
  # protected, and its target is never read either.
  test "an AGENTS.md link into a protected location adds nothing", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))
    target = Path.join([dir, ".git", "AGENTS.md"])
    File.write!(target, @sentinel)
    File.ln_s!(target, Path.join(dir, "AGENTS.md"))

    log = refused(dir)

    assert_received {:instructions, nil}
    assert log =~ "Refusing AGENTS.md"
    assert log =~ target
    assert log =~ "protected"
    refute log =~ @sentinel
  end

  # SKILL-17, WS-9: one that can't be resolved — a loop, or a chain past the
  # bound — is refused too, rather than read as the file it stops at.
  test "an AGENTS.md that cannot be resolved adds nothing", %{tmp_dir: dir} do
    File.ln_s!("AGENTS.md-b", Path.join(dir, "AGENTS.md"))
    File.ln_s!("AGENTS.md", Path.join(dir, "AGENTS.md-b"))

    log = refused(dir)

    assert_received {:instructions, nil}
    assert log =~ "Refusing AGENTS.md"
    assert log =~ "more symlinks than can be followed"
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

  # PREVIEW-9
  test "the preview instruction names the dark, mobile default" do
    agents = File.read!("AGENTS.md")

    assert agents =~ "bin/preview"
    assert agents =~ "ELIA_PREVIEW_THEME=dark"
    assert agents =~ "ELIA_PREVIEW_WIDTH=430"
  end

  # SKILL-7, PROJ-18
  test "a chat's built-in skills are the same in every project", %{tmp_dir: dir} do
    {own, _errors} = Skills.for_project(nil)
    {other, _errors} = Skills.for_project(project(dir))

    assert names(other) == names(own)
    assert "harness" in names(own)
    assert "chats" in names(own)
  end

  # SKILL-2, PROJ-16, PROJ-18
  test "for_project/1 is Elia's skills plus the project's own", %{tmp_dir: dir} do
    write_skill(dir, "project-skill")

    {skills, errors} = Skills.for_project(project(dir))

    assert "project-skill" in names(skills)
    # Elia's own folder skills and built-ins are still there.
    assert "shell" in names(skills)
    assert "harness" in names(skills)
    refute Enum.any?(errors, fn {folder, _} -> folder =~ "project-skill" end)

    # FOLDER-3: the skill's folder is relative to the project it was loaded from.
    project_skill = Enum.find(skills, &(&1.name == "project-skill"))
    assert project_skill.instructions =~ "Skill folder: skills/project-skill"
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

    # The same skills, once: the folder is not scanned a second time, and the
    # built-in skills do not vary with the project (SKILL-7).
    assert names(same) == names(own)
    assert names(same) == Enum.uniq(names(same))
  end

  # SKILL-4, PROJ-19
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
    # The built-ins are the same for every project (SKILL-7).
    assert "harness" in names(Skills.resolve(nil, project))
  end

  # SKILL-14
  test "resolve/1 defaults the project to Elia's own" do
    assert Skills.resolve([@skill]) == [@skill]
    assert Skills.resolve(fn -> [@skill] end) == [@skill]
    assert "harness" in names(Skills.resolve(nil))
  end
end
