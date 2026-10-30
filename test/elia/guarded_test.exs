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

  # GUARD-8: the reloader never reloads, whichever file changed.
  test "GUARD-8: never reloads, even when only unguarded files changed" do
    File.write!(in_root("lib/elia/agent.ex"), "changed")
    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    refute_received {:reloaded, _}
  end

  # GUARD-9, GUARD-10
  test "GUARD-10: unguarded code files are pending too" do
    assert Guarded.changed() == []
    File.write!(in_root("lib/elia/agent.ex"), "changed")
    File.write!(in_root("lib/elia/harness.ex"), "weakened")
    File.write!(in_root("lib/elia/skills/sneaky.ex"), "new")

    assert Guarded.changed() ==
             ["lib/elia/agent.ex", "lib/elia/harness.ex", "lib/elia/skills/sneaky.ex"]

    assert :ok = Guarded.reload(:endpoint, delegate: delegate())
    refute_received {:reloaded, _}
  end

  # GUARD-12
  test "GUARD-12: restoring the files clears the pending changes" do
    File.write!(in_root("lib/elia/agent.ex"), "changed")
    File.write!(in_root("lib/elia/skills/sneaky.ex"), "new")
    assert length(Guarded.changed()) == 2

    File.write!(in_root("lib/elia/agent.ex"), "original")
    File.rm!(in_root("lib/elia/skills/sneaky.ex"))
    assert Guarded.changed() == []
  end

  test "GUARD-10, GUARD-12: a deleted file is pending until it is loaded" do
    File.rm!(in_root("lib/elia/harness.ex"))
    assert Guarded.changed() == ["lib/elia/harness.ex"]

    # A successful hot_reload marks the current state as loaded.
    Guarded.mark_loaded()
    assert Guarded.changed() == []
  end

  test "GUARD-9: files outside the code files are not tracked" do
    File.mkdir_p!(in_root("skills/x"))
    File.write!(in_root("skills/x/SKILL.md"), "hi")
    assert Guarded.changed() == []
  end

  # GUARD-11
  test "GUARD-11: warns once per distinct set of pending files" do
    File.write!(in_root("lib/elia/agent.ex"), "changed")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Guarded.reload(:endpoint)
        Guarded.reload(:endpoint)
      end)

    assert [_] = Regex.scan(~r/held until hot_reload \(lib\/elia\/agent\.ex\)/, log)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        File.write!(in_root("lib/elia/harness.ex"), "weakened")
        Guarded.reload(:endpoint)
      end)

    assert log =~ "lib/elia/agent.ex, lib/elia/harness.ex"
  end

  # GUARD-13
  test "GUARD-13: live reload doesn't watch lib files" do
    {config, _} = Config.Reader.read_imports!("config/runtime.exs", env: :dev)
    live_reload = config[:elia][EliaWeb.Endpoint][:live_reload]
    refute Enum.any?(live_reload[:patterns], &Regex.match?(&1, "lib/elia_web/live/chat_live.ex"))
    assert Enum.any?(live_reload[:patterns], &Regex.match?(&1, "priv/static/assets/app.css"))
  end
end
