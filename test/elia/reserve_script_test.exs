defmodule Elia.ReserveScriptTest do
  use ExUnit.Case, async: true

  # specs/spec-hygiene.md (SPEC-19 … SPEC-25): `bin/reserve` hands a chat the
  # requirement numbers it is about to draft with, so two chats drafting at once
  # never take the same one. It keeps its reservations under the repository's
  # git directory, which the live tree and every worktree of the project share
  # (SPEC-21) and which git never reports (SPEC-22).
  @script Path.expand("../../bin/reserve", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "elia-reserve-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "specs"))
    File.cp!(@script, Path.join(dir, "bin/reserve"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # The script as a chat runs it: in the tree it belongs to, which is where the
  # corpus and the repository are read from.
  defp run(dir, args) do
    System.cmd("sh", [Path.join(dir, "bin/reserve") | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  # What it printed, without the note it writes beside the numbers.
  defp ids(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&Regex.match?(~r/^[A-Z]+-\d+$/, &1))
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  defp store(dir), do: Path.join([dir, ".git", "elia-reservations"])

  # A prefix's entries as a spec file defines them — a retired one spent
  # (SPEC-3, SPEC-4).
  defp define!(dir, file, entries) do
    body =
      Enum.map_join(entries, "", fn
        {prefix, n, :live} -> "- **#{prefix}-#{n}** A requirement.\n"
        {prefix, n, :retired} -> "- ~~**#{prefix}-#{n}** It was one.~~ Retired: gone.\n"
      end)

    File.write!(Path.join(dir, "specs/#{file}.md"), body)
  end

  test "prints the corpus' next free numbers, one per line (SPEC-23, SPEC-3)", %{dir: dir} do
    define!(dir, "one", [{"SPEC", 1, :live}, {"SPEC", 2, :retired}, {"SPEC", 3, :live}])

    assert {output, 0} = run(dir, ["SPEC", "2"])
    assert ids(output) == ["SPEC-4", "SPEC-5"]
  end

  test "a prefix nobody has used starts at 1, and one number is the default (SPEC-23)", %{
    dir: dir
  } do
    define!(dir, "one", [{"SPEC", 1, :live}])

    assert {output, 0} = run(dir, ["PROJ"])
    assert ids(output) == ["PROJ-1"]

    # A prefix typed in small letters is taken as the capitals it means
    # (SPEC-1, SPEC-23).
    assert {output, 0} = run(dir, ["spec"])
    assert ids(output) == ["SPEC-2"]
  end

  test "a reserved number is not handed out again and is not git's business (SPEC-19, SPEC-22)",
       %{dir: dir} do
    define!(dir, "one", [{"SPEC", 1, :live}])
    git!(dir, ["init", "-q"])

    assert {first, 0} = run(dir, ["SPEC", "2"])
    assert ids(first) == ["SPEC-2", "SPEC-3"]

    assert {second, 0} = run(dir, ["SPEC"])
    assert ids(second) == ["SPEC-4"]

    # A reservation holds nothing but its name (SPEC-22) …
    assert File.ls!(Path.join(store(dir), "SPEC-2")) == []

    # … and it is not a working-tree change: git reports neither the store nor
    # anything under it.
    refute git!(dir, ["status", "--porcelain"]) =~ "elia-reservations"
  end

  test "two chats reserving at once never take the same number (SPEC-20)", %{dir: dir} do
    define!(dir, "one", [{"SPEC", 1, :live}])
    git!(dir, ["init", "-q"])

    taken =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> run(dir, ["SPEC", "5"]) end) end)
      |> Enum.flat_map(fn task ->
        {output, 0} = Task.await(task, 30_000)
        ids(output)
      end)

    assert length(taken) == 10
    assert taken == Enum.uniq(taken)
  end

  test "every worktree of one repository reads the same reservations (SPEC-21)", %{dir: dir} do
    git!(dir, ["init", "-q"])
    define!(dir, "one", [{"SPEC", 1, :live}])
    git!(dir, ["add", "-A"])
    git!(dir, ["-c", "user.name=t", "-c", "user.email=t@e", "commit", "-qm", "corpus"])

    worktree = Path.join(dir, "tmp/worktrees/one")
    git!(dir, ["worktree", "add", "-q", "-b", "chat/one", worktree])

    # The tree the corpus is read from gives up its next number …
    assert {live, 0} = run(dir, ["SPEC"])
    assert ids(live) == ["SPEC-2"]

    # … and the worktree — a chat's own tree — sees that reservation, because
    # both read the one git directory behind its `.git` pointer file.
    assert {mine, 0} = run(worktree, ["SPEC"])
    assert ids(mine) == ["SPEC-3"]

    common = git!(worktree, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    assert String.trim(common) == Path.join(dir, ".git")
    assert File.dir?(Path.join(store(dir), "SPEC-3"))
  end

  test "without a store the corpus decides alone (SPEC-25)", %{dir: dir} do
    define!(dir, "one", [{"SPEC", 1, :live}])

    # No git repository at all: the numbers are still printed, and nothing is
    # reserved, so the next chat gets the same ones.
    assert {output, 0} = run(dir, ["SPEC", "2"])
    assert ids(output) == ["SPEC-2", "SPEC-3"]
    refute File.exists?(Path.join(dir, ".git"))

    assert {again, 0} = run(dir, ["SPEC", "2"])
    assert ids(again) == ["SPEC-2", "SPEC-3"]

    # A store that cannot be written is treated the same way.
    git!(dir, ["init", "-q"])
    File.mkdir_p!(store(dir))
    File.chmod!(store(dir), 0o500)
    on_exit(fn -> File.chmod(store(dir), 0o700) end)

    assert {output, 0} = run(dir, ["SPEC", "2"])
    assert ids(output) == ["SPEC-2", "SPEC-3"]
  end

  test "a call it cannot understand is refused and reserves nothing (SPEC-24)", %{dir: dir} do
    git!(dir, ["init", "-q"])

    assert {output, 2} = run(dir, [])
    assert output =~ "prefix"

    for count <- ["zero", "0", "-1", "1.5"] do
      assert {output, 2} = run(dir, ["SPEC", count])
      assert output =~ "positive whole number"
    end

    assert {output, 2} = run(dir, ["SPEC-2", "1"])
    assert output =~ "prefix"

    refute File.exists?(store(dir))
  end
end
