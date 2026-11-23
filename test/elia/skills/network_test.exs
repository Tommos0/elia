defmodule Elia.Skills.NetworkTest do
  use ExUnit.Case, async: false

  alias Elia.Projects
  alias Elia.Skills.Network

  @skill Network

  setup do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    project = Projects.harness()
    on_exit(fn -> Projects.set_allowlist(project, []) end)
    %{project: project}
  end

  defp run(input, ctx), do: Enum.at(@skill.tools(), 0).run.(input, ctx)

  defp ctx(project, answer, mode \\ :allowlist, opts \\ []) do
    %{
      project: project,
      answer: answer,
      network: %{mode: mode, hosts: []},
      session_id: Keyword.get(opts, :session_id)
    }
  end

  # NET-30: the built-in network skill carries one tool, whose input is the host
  # and the reason, and which never needs approval (APPR-7).
  test "the skill carries one tool that asks the user" do
    assert @skill.name() == "network"
    assert @skill.description() =~ "host"

    assert [tool] = @skill.tools()
    assert tool.name == "request_network_host"
    assert tool.asks_user
    assert tool.approval == :never
    assert tool.input_schema["required"] == ["host", "reason"]
    assert tool.input_schema["properties"]["host"]["type"] == "string"
    assert tool.input_schema["properties"]["reason"]["type"] == "string"
  end

  # NET-35: the instructions say when to ask rather than give up or look for
  # another way out, and what the card offers the user — the host for this chat
  # or for its project (NET-32).
  test "the instructions say when to ask" do
    instructions = @skill.instructions()

    assert instructions =~ "request_network_host"
    assert instructions =~ "cannot reach a host"
    assert instructions =~ "project"
    assert instructions =~ "chat"
  end

  # NET-33, NET-32: the answer that names the project adds the host to the
  # project's list — one every chat of it reaches (NET-28) — and the result says
  # so and that the command may be run again.
  test "an answer that allows the host for the project adds it to the project", %{
    project: project
  } do
    assert {:ok, message} =
             run(
               %{"host" => "API.example.com", "reason" => "curl"},
               ctx(project, "Allow for project")
             )

    assert message =~ "api.example.com"
    assert message =~ "allowed"
    assert message =~ "run the command again"
    assert message =~ project.name
    assert Projects.allowlist(project) == ["api.example.com"]
  end

  # NET-33, NET-36: the answer that names the chat adds the host to the entries
  # the chat names of its own, which no other chat reaches — and the result says
  # which list it went into. The chat's own setting is read from the chat, so a
  # request answered with no running session allows nothing.
  test "an answer that allows the host for the chat needs the chat's own session", %{
    project: project
  } do
    assert {:error, message} =
             run(
               %{"host" => "api.example.com", "reason" => "curl"},
               ctx(project, "Allow for chat")
             )

    assert message =~ "no running session"
    assert message =~ "nothing was added"
    assert Projects.allowlist(project) == []
  end

  # NET-39: an answer that allows the host without naming a list is read as
  # allowing it for the chat, not for the project.
  test "an answer that names no list allows the host for the chat", %{project: project} do
    assert {:error, message} =
             run(%{"host" => "api.example.com", "reason" => "curl"}, ctx(project, "allow"))

    assert message =~ "no running session"
    assert Projects.allowlist(project) == []
  end

  # NET-33: any other answer changes nothing, and the result carries the answer
  # verbatim. NET-32: the card's own third button is one of them.
  test "an answer that doesn't allow the host changes nothing", %{project: project} do
    assert {:ok, message} =
             run(
               %{"host" => "api.example.com", "reason" => "curl"},
               ctx(project, "Ask me later?")
             )

    assert message =~ "did not allow api.example.com"
    assert message =~ ~s("Ask me later?")
    assert Projects.allowlist(project) == []

    assert {:ok, message} =
             run(%{"host" => "api.example.com", "reason" => "curl"}, ctx(project, "Deny"))

    assert message =~ "did not allow api.example.com"
    assert Projects.allowlist(project) == []
  end

  # NET-33: an answer that allows a host which is not one of NET-7's forms adds
  # nothing, and the result says so.
  test "a host that can't be one is named and nothing is allowed", %{project: project} do
    assert {:error, message} =
             run(
               %{"host" => "not a host", "reason" => "curl"},
               ctx(project, "Allow for project")
             )

    assert message =~ "not a host"
    assert Projects.allowlist(project) == []
  end

  # NET-34: a chat whose mode is not allowlist is told so — the host is in the
  # list the answer chose, and its own mode still limits what it reaches.
  test "a chat that isn't in allowlist mode is told its mode still limits it", %{
    project: project
  } do
    assert {:ok, message} =
             run(
               %{"host" => "api.example.com", "reason" => "curl"},
               ctx(project, "Allow for project", :none)
             )

    assert message =~ "api.example.com"
    assert message =~ ~s("none")
    assert Projects.allowlist(project) == ["api.example.com"]

    assert {:ok, message} =
             run(
               %{"host" => "other.example.com", "reason" => "curl"},
               ctx(project, "Allow for project", :unrestricted)
             )

    assert message =~ "reaches the whole network"
  end

  # NET-31: no answer at all — a call that wasn't put to the user — runs nothing.
  test "a call with no answer runs nothing", %{project: project} do
    assert {:error, message} =
             run(%{"host" => "api.example.com", "reason" => "curl"}, %{project: project})

    assert message =~ "No answer"
    assert Projects.allowlist(project) == []
  end
end
