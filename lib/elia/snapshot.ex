defmodule Elia.Snapshot do
  @moduledoc """
  A git snapshot of a work tree, taken beside a `shell` tool call so the chat can
  show what that call changed (SNAP).

  A snapshot is a commit of the tree as it stands — untracked files included,
  what the tree's own ignore rules exclude left out (SNAP-3) — built through a
  temporary index, so the tree's real index, HEAD, current branch, stash and
  working files are as they were (SNAP-1). It is reachable from one ref of its
  own, `refs/elia/snapshots/<milliseconds>-<short sha>`, and from nothing else,
  so `git log`, `git branch` and `git status` show nothing of it while git keeps
  the objects it holds (SNAP-2).

  Nothing here fails a call. A directory that is not in a git work tree, a git
  that fails and a snapshot that takes longer than `timeout` all answer `nil`,
  and the call that asked for one runs on unaltered (SNAP-9).

      config :elia, Elia.Snapshot,
        max_diff: 20_000,   # characters of a pair's diff a card shows (SNAP-11)
        timeout: 30_000     # milliseconds one snapshot may take (SNAP-9)
  """

  @refs "refs/elia/snapshots"

  @doc """
  The newest snapshot of the tree `dir` is in, taking one first when the tree has
  none — so the chat's first call in a tree is compared with the tree as the chat
  found it (SNAP-5). `nil` where no snapshot can be taken (SNAP-9).
  """
  @spec current(binary()) :: binary() | nil
  def current(dir) do
    with {:ok, root} <- root(dir) do
      case newest(root) do
        {:ok, ref} -> ref
        :none -> take_now(root)
      end
    else
      _none -> nil
    end
  end

  @doc """
  The pair of snapshots bracketing a call: `from` is what `current/1` answered as
  the call started, and `to` is taken now — the same ref where the tree hasn't
  moved since (SNAP-4). Answers the pair with the files that differ between them
  and their diff, both read from the two snapshots now (SNAP-6, SNAP-12), or
  `nil` where there is no pair to record (SNAP-9).
  """
  @spec record(binary(), binary() | nil) :: map() | nil
  def record(dir, from) when is_binary(from) do
    with {:ok, root} <- root(dir),
         {:ok, ref} <- take(root) do
      %{
        root: root,
        from: from,
        to: ref,
        files: files(root, from, ref),
        diff: diff(root, from, ref)
      }
    else
      _none -> nil
    end
  end

  def record(_dir, _from), do: nil

  ## A pair's diff, per file

  @doc """
  Each of a pair's files with its own part of the pair's diff: `%{status:,
  path:, diff:, added:, removed:}` per file, where a file the diff holds no
  part of has `diff: nil` and no lines of its own (SNAP-15, SNAP-16). Both come
  from the diff the pair carries, so a chat saved before this reads it too and
  no git is read.
  """
  @spec files_with_diffs(map()) :: [map()]
  def files_with_diffs(%{files: files, diff: diff}) do
    parts = parts(diff || "", files)

    files
    |> Enum.with_index()
    |> Enum.map(fn {file, index} -> Map.merge(file, change(parts, file.path, index)) end)
  end

  def files_with_diffs(_pair), do: []

  defp change(parts, path, index) do
    case part_for(parts, path, index) do
      nil -> %{diff: nil, added: 0, removed: 0}
      part -> %{diff: part.text, added: part.added, removed: part.removed}
    end
  end

  # SNAP-15: a part is the chunk of the diff that changes one path — the one
  # whose header names it — or, where the cut at `max_diff` left the header
  # unreadable (SNAP-11), the chunk at the same position, which is what is left
  # of that file's own part. A file neither names has no part.
  defp part_for(parts, path, index) do
    Enum.find(parts, &(&1.path == path)) ||
      case Enum.at(parts, index) do
        %{path: nil} = part -> part
        _other -> nil
      end
  end

  # A part runs from a `diff --git ` line to the one before the next. What comes
  # before the first such line is a part too, with no path of its own: it is
  # what a cut inside the first header left behind.
  defp parts(diff, files) do
    paths = Enum.map(files, & &1.path)

    diff
    |> String.split("\n")
    |> Enum.chunk_while([], &chunk/2, fn acc -> {:cont, Enum.reverse(acc), []} end)
    |> Enum.map(fn lines ->
      %{
        text: Enum.join(lines, "\n"),
        path: named_path(hd(lines), paths),
        added: count(lines, "+"),
        removed: count(lines, "-")
      }
    end)
  end

  defp chunk(line, acc) do
    cond do
      acc == [] -> {:cont, [line]}
      String.starts_with?(line, "diff --git ") -> {:cont, Enum.reverse(acc), [line]}
      true -> {:cont, [line | acc]}
    end
  end

  # The path a part's header names: git writes `diff --git a/<old> b/<new>`, so
  # it is the longest of the pair's paths the header ends in ` b/<path>` with.
  defp named_path(header, paths) do
    with true <- String.starts_with?(header, "diff --git ") do
      paths
      |> Enum.filter(&String.ends_with?(header, " b/" <> &1))
      |> Enum.sort_by(&byte_size/1)
      |> List.last()
    else
      _none -> nil
    end
  end

  # SNAP-16: the lines of one part that a patch adds and removes. Only what
  # comes after the part's first hunk header counts, so its own `---` and `+++`
  # lines are not lines it adds or removes, and a part with fewer than one hunk
  # — a mode change, a binary file — counts none.
  defp count(lines, prefix) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
    |> Enum.count(&String.starts_with?(&1, prefix))
  end

  ## Taking one

  defp take_now(root) do
    case take(root) do
      {:ok, ref} -> ref
      _none -> nil
    end
  end

  # SNAP-1: the tree's own index is never written — a temporary one is built
  # fresh, `git add -A` fills it and `git write-tree` turns it into a tree, all
  # inside one run, so the temporary index lives and dies with it. SNAP-2: the
  # commit is reached by its own ref and by nothing else, so the tree's log,
  # branches and status are as they were. SNAP-4: a tree equal to the newest
  # snapshot's is that snapshot, and no ref is added for it. The author is set
  # here rather than read from a configuration a jailed command cannot see.
  defp take(root) do
    ms = System.system_time(:millisecond)

    script = """
    set -e
    git() { command git #{Enum.join(Elia.Shell.harness_git_flags(), " ")} "$@"; }
    export GIT_AUTHOR_NAME=Elia GIT_AUTHOR_EMAIL=elia@localhost
    export GIT_COMMITTER_NAME=Elia GIT_COMMITTER_EMAIL=elia@localhost
    idx=$(mktemp)
    rm -f "$idx"
    export GIT_INDEX_FILE=$idx
    git add -A
    tree=$(git write-tree)
    unset GIT_INDEX_FILE
    rm -f "$idx"
    newest=$(git for-each-ref --sort=-refname --format='%(refname)' #{@refs} | head -n 1)
    if [ -n "$newest" ] && [ "$(git rev-parse "$newest^{tree}")" = "$tree" ]; then
      echo "$newest"
      exit 0
    fi
    ref="#{@refs}/#{ms}-$(git rev-parse --short=12 "$tree")"
    git update-ref "$ref" "$(git commit-tree "$tree" -m 'shell snapshot')"
    echo "$ref"
    """

    case run(script, root) do
      {:ok, output, 0} -> ref(output)
      {:ok, output, status} -> {:error, "git exited #{status}: #{output}"}
      {:timeout, _output} -> {:error, "timed out"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ref(output) do
    case output |> String.split("\n", trim: true) |> List.last() do
      ref when is_binary(ref) -> {:ok, String.trim(ref)}
      _none -> {:error, "no snapshot"}
    end
  end

  ## Reading one

  # SNAP-10, SNAP-12: the files a pair differs in, with the status of each, read
  # from the two snapshots. A rename is reported as the path it became, and a
  # typechange, a copy or anything else git names is a modification.
  defp files(root, from, to) do
    with {:ok, output} <- git_diff(root, ["diff", "--name-status", from, to]) do
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&file/1)
    else
      _none -> []
    end
  end

  defp file(line) do
    case String.split(line, "\t", trim: true) do
      [status, path] -> [%{status: status_name(status), path: path}]
      [status, _from, to] -> [%{status: status_name(status), path: to}]
      _none -> []
    end
  end

  defp status_name(<<letter::binary-size(1), _rest::binary>>) do
    case letter do
      "A" -> "added"
      "D" -> "deleted"
      "R" -> "renamed"
      _other -> "modified"
    end
  end

  defp status_name(_status), do: "modified"

  # SNAP-11, SNAP-12: the pair's diff, read from its two snapshots while the
  # call is still the newest thing that happened, and cut at `max_diff`
  # characters with a marker saying how many were left out.
  defp diff(root, from, to) do
    case git_diff(root, ["diff", "--no-color", from, to]) do
      {:ok, patch} -> cut(patch)
      {:error, reason} -> "The diff could not be read: #{reason}"
    end
  end

  defp cut(patch) do
    max = config(:max_diff)

    if String.length(patch) > max do
      String.slice(patch, 0, max) <>
        "\n... [#{String.length(patch) - max} more characters not shown] ..."
    else
      patch
    end
  end

  ## git

  defp root(dir) do
    case git(dir, ["rev-parse", "--show-toplevel"]) do
      {:ok, ""} -> :none
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> :none
    end
  end

  defp newest(root) do
    case git(root, ["for-each-ref", "--sort=-refname", "--format=%(refname)", @refs]) do
      {:ok, output} ->
        case String.split(output, "\n", trim: true) do
          [ref | _rest] -> {:ok, ref}
          [] -> :none
        end

      {:error, _reason} ->
        :none
    end
  end

  defp git(dir, args, opts \\ []) do
    command = "git " <> Enum.map_join(Elia.Shell.harness_git_flags() ++ args, " ", &quote_arg/1)

    case run(command, dir, opts) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, output, _status} -> {:error, output}
      {:timeout, _output} -> {:error, "timed out"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # `git diff` reports a difference in its exit status as diff(1) does, so a
  # non-zero one is a diff and not a failure (SNAP-9).
  defp git_diff(dir, args, opts \\ []) do
    command = "git " <> Enum.map_join(Elia.Shell.harness_git_flags() ++ args, " ", &quote_arg/1)

    case run(command, dir, opts) do
      {:ok, output, status} when status in [0, 1] -> {:ok, output}
      {:ok, output, _status} -> {:error, output}
      {:timeout, _output} -> {:error, "timed out"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ISOL-1: the harness's own git calls go through `Elia.Shell.run/2` like
  # everything else, jailed to the tree they work in (ISOL-13), with `timeout`
  # as the longest one of them may take.
  defp run(command, dir, opts \\ []) do
    opts = Keyword.merge([cd: dir, workspace: dir, timeout: timeout()], opts)

    case Elia.Shell.run(command, opts) do
      {:ok, output, status} -> {:ok, Elia.Shell.strip_notices(output) |> String.trim(), status}
      {:timeout, output} -> {:timeout, Elia.Shell.strip_notices(output)}
    end
  end

  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp timeout, do: config(:timeout)

  defp config(key) do
    Keyword.merge([max_diff: 20_000, timeout: 30_000], Application.get_env(:elia, __MODULE__, []))[
      key
    ]
  end
end
