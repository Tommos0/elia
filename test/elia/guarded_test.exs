defmodule Elia.GuardedTest do
  use ExUnit.Case, async: false

  alias Elia.{Guarded, Workspace}

  defp in_root(path), do: Path.join(Workspace.root(), path)

  setup do
    File.mkdir_p!(in_root("lib/elia/skills"))
    File.write!(in_root("lib/elia/harness.ex"), "original")
    File.write!(in_root("lib/elia/agent.ex"), "original")
    Guarded.mark_loaded()

    on_exit(fn ->
      File.rm_rf!(in_root("lib"))
      Guarded.mark_loaded()
    end)
  end

  defp delegate do
    test = self()
    fn endpoint, _opts -> send(test, {:reloaded, endpoint}) && :ok end
  end

  test "classifies guarded paths" do
    assert Guarded.guarded?("lib/elia/harness.ex")
    assert Guarded.guarded?("lib/elia/skills/new_builtin.ex")
    assert Guarded.guarded?("config/dev.exs")
    assert Guarded.guarded?("test/elia/self_modification_test.exs")
    assert Guarded.guarded?(in_root("lib/elia/workspace.ex"))
    refute Guarded.guarded?("lib/elia/agent.ex")
    refute Guarded.guarded?("lib/elia_web/live/chat_live.ex")
    refute Guarded.guarded?("lib/elia/skills/nested/x.ex")
    refute Guarded.guarded?("skills/harness/SKILL.md")
    refute Guarded.guarded?("/etc/passwd")
  end

  test "reloads automatically when only unguarded files changed" do
    File.write!(in_root("lib/elia/agent.ex"), "changed")
    assert Guarded.changed() == []
    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    assert_received {:reloaded, :endpoint}
  end

  test "pauses automatic reloads while guarded files have unloaded changes" do
    File.write!(in_root("lib/elia/harness.ex"), "weakened")
    File.write!(in_root("lib/elia/skills/sneaky.ex"), "new")
    assert Guarded.changed() == ["lib/elia/harness.ex", "lib/elia/skills/sneaky.ex"]

    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    refute_received {:reloaded, _}

    # Restoring the files (e.g. a rollback) resumes automatic reloading.
    File.write!(in_root("lib/elia/harness.ex"), "original")
    File.rm!(in_root("lib/elia/skills/sneaky.ex"))
    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    assert_received {:reloaded, :endpoint}
  end

  test "deleting a guarded file also pauses reloads until it is loaded" do
    File.rm!(in_root("lib/elia/harness.ex"))
    assert Guarded.changed() == ["lib/elia/harness.ex"]

    # A successful hot_reload marks the current state as loaded.
    Guarded.mark_loaded()
    assert Guarded.changed() == []
    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    assert_received {:reloaded, :endpoint}
  end
end
