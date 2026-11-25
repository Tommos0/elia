defmodule Elia.Skills.SettingsTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Skills, Tool}

  setup do
    start_supervised!(Elia.FakeLLM)

    id = Agent.new_id()
    project = Elia.Projects.default()
    {:ok, _pid} = Agent.ensure_started(id, project: project)
    on_exit(fn -> Agent.delete(id) end)

    %{id: id, project: project}
  end

  # CSET-14, CSET-16: the tool's answer, decoded — one JSON object.
  defp read_settings(id) do
    assert {:ok, json} = tool().run.(%{}, %{session_id: id})
    assert is_binary(json)
    assert %{} = report = Jason.decode!(json)
    report
  end

  defp tool do
    {skills, _errors} = Skills.for_project(nil)
    skill = Enum.find(skills, &(&1.name == "settings"))
    assert skill, "the settings skill is not loaded"
    assert [tool] = skill.tools
    tool
  end

  # CSET-14: a built-in skill of every project, with one tool, a sub-task's too.
  test "the settings skill is built in and offers get_chat_settings" do
    {skills, _errors} = Skills.for_project(nil)
    skill = Enum.find(skills, &(&1.name == "settings"))

    assert %Elia.Skill{} = skill
    assert skill.description =~ "get_chat_settings"
    assert skill.instructions =~ "get_chat_settings"

    assert [%Tool{name: "get_chat_settings"} = tool] = skill.tools

    # CSET-15, APPR-7: reading a chat's settings never needs approval.
    assert Tool.approval(tool, %{}, %{}) == :never

    # SUBTASK-1: a child chat has it as well, minus the tasks skill.
    child = Skills.for_child(nil)
    assert Enum.any?(child, &(&1.name == "settings"))
  end

  # CSET-14, CSET-16, CSET-17
  test "a chat that has set nothing reports the settings that apply", %{id: id} do
    report = read_settings(id)

    # CSET-14: the chat's identity.
    assert report["id"] == id
    assert report["title"] == nil
    assert report["done"] == false
    assert %{"id" => project_id, "name" => name, "folder" => folder} = report["project"]
    assert project_id == Agent.snapshot(id).project.id
    assert is_binary(name) and is_binary(folder)

    # CSET-16: one entry per kind of setting, and nothing else.
    assert Enum.sort(Map.keys(report)) ==
             Enum.sort([
               "id",
               "title",
               "done",
               "project",
               "model",
               "effort",
               "auto_approve",
               "jail",
               "network",
               "limits",
               "compaction"
             ])

    # MODEL-1, MODEL-15, MODEL-2, CTX-7: a model resolves for a chat that never
    # picked one, and the report says it is not the chat's own.
    assert %{
             "provider" => provider,
             "id" => model,
             "name" => model_name,
             "context_window" => window,
             "own" => false
           } = report["model"]

    assert is_binary(provider) and is_binary(model) and is_binary(model_name)
    assert is_integer(window) or is_nil(window)
    assert {provider, model} != {nil, nil}

    # LLM-38, CSET-13: no effort of its own, so the provider's default applies.
    assert report["effort"] == %{"value" => nil, "own" => false}

    # APPR-8, APPR-14: the tool names the chat auto-approves.
    assert is_list(report["auto_approve"])

    # ISOL-16, ISOL-12: the setting, and whether this host can build one at all.
    assert report["jail"]["on"] == true
    assert is_boolean(report["jail"]["available"])

    # NET-1, NET-36: one of the three modes, naming nothing of its own yet.
    assert report["network"]["mode"] in ["allowlist", "unrestricted", "none"]
    assert report["network"]["hosts"] == []
    assert is_list(report["network"]["project_hosts"])

    # LIMIT-1, LIMIT-9, LOOP-16: the chat has no limit of its own, so the
    # loop's own step default (300) stands, with no time or token budget, and a
    # turn that reaches a limit pauses.
    assert report["limits"] == %{
             "max_steps" => %{"value" => 300, "own" => false},
             "max_minutes" => %{"value" => nil, "own" => false},
             "max_tokens" => %{"value" => nil, "own" => false},
             "pause_on_limit" => true
           }

    # COMPACT-9: the chat's compaction options, the configured defaults filled
    # in.
    options = Elia.LLM.Compaction.options(Agent.snapshot(id).compaction.options)

    assert report["compaction"] ==
             Map.new(options, fn {key, value} ->
               {Atom.to_string(key), value}
             end)
  end

  # CSET-15, CSET-16, CSET-17
  test "it reports each setting as the chat's own, as it stands", %{id: id, project: project} do
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)
    {:ok, _project} = Elia.Projects.set_allowlist(project, ["api.example.com"])

    {:ok, _title} = Agent.set_title(id, "A chat about cats")
    :ok = Agent.set_settings(id, %{model: %{provider: "anthropic", model: "claude-opus-5-5"}})
    :ok = Agent.set_effort(id, "low")
    :ok = Agent.set_auto_approve(id, "shell", false)
    :ok = Agent.set_jail(id, false)
    :ok = Agent.set_network(id, %{mode: :none, hosts: ["chat.example.com"]})
    :ok = Agent.set_limits(id, %{max_steps: 5, pause_on_limit: false})
    :ok = Agent.set_compaction(id, %{auto: false})
    Agent.set_done(id, true)

    report = read_settings(id)

    assert report["title"] == "A chat about cats"
    assert report["done"] == true

    # MODEL-1: the chat's own selection is what applies.
    assert %{
             "provider" => "anthropic",
             "id" => "claude-opus-5-5",
             "context_window" => window,
             "own" => true
           } = report["model"]

    assert is_integer(window)

    assert report["effort"] == %{"value" => "low", "own" => true}
    refute "shell" in report["auto_approve"]
    assert report["jail"]["on"] == false

    # NET-1, NET-36, NET-28: the mode, the entries the chat names of its own and
    # the ones its project's allowlist names.
    assert report["network"] == %{
             "mode" => "none",
             "hosts" => ["chat.example.com"],
             "project_hosts" => ["api.example.com"]
           }

    # LIMIT-1, LIMIT-9: the values the chat set, each its own.
    assert report["limits"]["max_steps"] == %{"value" => 5, "own" => true}
    assert report["limits"]["pause_on_limit"] == false

    assert report["compaction"]["auto"] == false

    # CSET-15: a setting changed since the last call is what the next call
    # reports, and the tool changes nothing of the chat's own.
    :ok = Agent.set_limits(id, %{max_steps: 7})
    assert read_settings(id)["limits"]["max_steps"] == %{"value" => 7, "own" => true}
  end

  # CSET-15
  test "a call with no chat to read is an error result" do
    assert {:error, message} = tool().run.(%{}, %{})
    assert message =~ "chat"
  end
end
