defmodule Elia.TestRun do
  @moduledoc """
  The directory a test run's own state lives in (SUITE-1, SUITE-12, SUITE-13).

  `config/test.exs` derives it: `ELIA_TEST_RUN` when a runner made one —
  `bin/test` does, with `mktemp -d`, one for each partition — otherwise a
  directory named for this process under the system temp dir. So every run has
  state no other run shares, and a run the harness starts for the deploy's own
  suite (`Elia.Shell`, which replaces the environment rather than extending it)
  is a run of its own too.

  `test/test_helper.exs` calls `prepare!/0` as the run starts: it makes the run's
  own directory and its `tmp/`, points `TMPDIR` at that `tmp/` so a test's own
  temp paths are the run's as well — a test names them with
  `System.unique_integer/1`, which is unique inside one BEAM node only — and
  prunes the run directories a killed run left behind.
  """

  @prefix "elia-test-"
  @max_age_seconds 24 * 60 * 60

  @doc "This run's own directory (SUITE-12)."
  @spec dir() :: binary()
  def dir, do: Application.fetch_env!(:elia, :test_run)

  @doc "The directory a run's own temp paths are named in: what `TMPDIR` is set to (SUITE-1)."
  @spec tmp_dir(binary()) :: binary()
  def tmp_dir(run \\ dir()), do: Path.join(run, "tmp")

  @doc "The directory run directories are made in, which is what `prune/2` looks through."
  @spec base_dir(binary()) :: binary()
  def base_dir(run \\ dir()), do: Path.dirname(run)

  @doc """
  Makes this run's own directories and clears away what runs that ended left
  behind, then points `TMPDIR` at the run's `tmp/` (SUITE-1, SUITE-13). Called
  once, as `test/test_helper.exs` starts, before anything names a temp path.
  """
  @spec prepare!() :: binary()
  def prepare! do
    run = dir()
    File.mkdir_p!(run)
    prune()
    tmp = tmp_dir(run)
    File.mkdir_p!(tmp)
    System.put_env("TMPDIR", tmp)
    run
  end

  @doc """
  Removes the run directories under `base` that no run can still be using: a run
  that was killed rather than exited could not clean up after itself, and a run
  that is going on has just made its own, so age is what tells the two apart
  (SUITE-13). A directory that is not old enough is left where it is.
  """
  @spec prune(binary(), non_neg_integer()) :: :ok
  def prune(base \\ base_dir(), max_age_seconds \\ @max_age_seconds) do
    now = System.os_time(:second)

    for entry <- File.ls!(base), String.starts_with?(entry, @prefix) do
      path = Path.join(base, entry)

      case File.stat(path, time: :posix) do
        {:ok, %{type: :directory, mtime: mtime}} when now - mtime > max_age_seconds ->
          File.rm_rf!(path)

        _ ->
          :ok
      end
    end

    :ok
  end
end
