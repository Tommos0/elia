defmodule Elia.PriorityTest do
  use ExUnit.Case, async: true

  alias Elia.Priority

  # PRIO-1, PRIO-5: the default is a positive `nice` below the server's own 0.
  # The suite runs with the default configuration, which is what PRIO-1 names.
  test "a command is started below the server's own CPU priority by default" do
    assert Priority.settings() == [nice: 10, ionice: 6]
  end

  # PRIO-1, PRIO-7: the priority is a prefix on the executable and the arguments,
  # `nice` first, so the command itself starts with the value set.
  test "the prefix is nice, then the arguments of the command" do
    case System.find_executable("nice") do
      nil -> assert Priority.prefix(nice: 10, ionice: nil) == []
      exe -> assert Priority.prefix(nice: 10, ionice: nil) == [exe, "-n", "10"]
    end
  end

  # PRIO-4: the I/O half is best-effort at the configured level, or the idle
  # class, and `-t` is what keeps a refused priority from failing the command.
  test "the I/O half is a low class, whose refusal is ignored" do
    case System.find_executable("ionice") do
      nil ->
        assert Priority.prefix(nice: nil, ionice: 6) == []

      exe ->
        assert Priority.prefix(nice: nil, ionice: 6) == [exe, "-t", "-c2", "-n", "6"]
        assert Priority.prefix(nice: nil, ionice: :idle) == [exe, "-t", "-c3"]
    end
  end

  # PRIO-6: only the children are lowered and never raised, so nothing asks for
  # a value a process couldn't set for itself: no negative nice, no realtime I/O
  # class, and an unusable value leaves that half out rather than guessing one.
  test "a value that could not be set is left out rather than forced" do
    refute "-c1" in Priority.prefix(ionice: :realtime)
    refute "-c1" in Priority.prefix(ionice: 1)

    assert Priority.prefix(nice: -5, ionice: nil) == []
    assert Priority.prefix(nice: nil, ionice: :realtime) == []
    assert Priority.prefix(nice: nil, ionice: 40) == []
    assert Priority.prefix(nice: :high, ionice: nil) == []

    # 19 is the most there is, and 0 is what a process has anyway.
    assert Priority.settings(nice: 40)[:nice] == 19
    assert Priority.settings(nice: 0)[:nice] == nil
    assert Priority.settings(nice: nil)[:nice] == nil
  end

  # PRIO-5: one call's own settings override the configured ones, and a call
  # that names neither half keeps the other one's configuration.
  test "a call overrides the configuration, and only what it names" do
    assert Priority.settings(nice: 3) == [nice: 3, ionice: 6]
    assert Priority.settings(ionice: :idle) == [nice: 10, ionice: :idle]
    assert Priority.settings(nice: 0, ionice: nil) == [nice: nil, ionice: nil]

    assert Priority.prefix(nice: 0, ionice: nil) == []
  end

  # PRIO-7: an empty prefix changes nothing about how a program is spawned, and
  # the program is still the one that runs where there is one.
  test "the program runs through the prefix, or as itself when there is none" do
    assert Priority.spawn_argv("/bin/sh", ["-c", "echo hi"], nice: 0, ionice: nil) ==
             {"/bin/sh", ["-c", "echo hi"]}

    case System.find_executable("nice") do
      nil ->
        assert Priority.spawn_argv("/bin/sh", ["-c", "echo hi"], nice: 5, ionice: nil) ==
                 {"/bin/sh", ["-c", "echo hi"]}

      exe ->
        assert {^exe, ["-n", "5", "/bin/sh", "-c", "echo hi"]} =
                 Priority.spawn_argv("/bin/sh", ["-c", "echo hi"], nice: 5, ionice: nil)
    end
  end
end
