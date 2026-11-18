defmodule Elia.Specs do
  @moduledoc """
  The spec corpus a workspace holds (`specs/spec-citations.md`): the requirement
  IDs its `specs/*.md` define, and what each one says (CITE-1, CITE-2).

  A chat's corpus is the one its own workspace has (CITE-4, PROJ-12) — the same
  workspace a file mention resolves in (FLINK-5) — so a citation shows the
  requirement as that chat has it. A workspace with no `specs/`, or one nothing
  there can be read from, simply has an empty corpus: a citation is then text,
  never an error. Reading is cheap after the first time, since the parsed corpus
  is kept while the files it was made from are unchanged (`Elia.Specs.Cache`).
  """

  alias Elia.Specs.Cache

  # CITE-2: a requirement is an entry, `- **ID** text`, wrapped across as many
  # lines as it needs, and a retired one is struck through (SPEC-5). Its text
  # runs to the next entry, heading or unindented line, so the spec's own
  # paragraphs stay with the requirement they belong to.
  @entry ~r/^- (~~)?\*\*([A-Z]+)-(\d+)\*\*(.*?)(?=\n(?:- |#|\S)|\z)/ms

  @doc """
  Every requirement the workspace `root` holds, by ID (CITE-1, CITE-2).
  """
  @spec requirements(binary()) :: %{binary() => binary()}
  def requirements(root) when is_binary(root) do
    files = files(root)
    stamps = for path <- files, do: {path, stamp(path)}
    written_at = newest_mtime(stamps)

    case Cache.fetch(root, stamps) do
      # CITE-4: reused only while the files are the same ones *and* the read
      # happened in a later second than the newest of them — see `newest_mtime/1`.
      {read_at, requirements} when read_at > written_at -> requirements
      _ -> read(root, files, stamps)
    end
  end

  @doc """
  What the requirement `id` says in `root`'s corpus, or `nil` when no spec there
  defines it (CITE-4).
  """
  @spec text(binary(), binary()) :: binary() | nil
  def text(root, id) when is_binary(root) and is_binary(id), do: Map.get(requirements(root), id)

  defp read(root, files, stamps) do
    requirements = files |> Enum.flat_map(&entries/1) |> Map.new()
    Cache.put(root, stamps, {System.system_time(:second), requirements})
    requirements
  end

  # The corpus is `specs/*.md` and nothing else: a plan defines no requirement
  # (SPEC-8), and a directory inside `specs/` is not part of the corpus either.
  defp files(root) do
    case File.ls(Path.join(root, "specs")) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join([root, "specs", &1]))

      _ ->
        []
    end
  end

  defp entries(path) do
    case File.read(path) do
      {:ok, content} ->
        for [_, retired, prefix, number, text] <- Regex.scan(@entry, content) do
          {"#{prefix}-#{number}", statement(text, retired)}
        end

      _ ->
        []
    end
  end

  # CITE-2: the entry's own markers are not part of the statement — not the
  # bullet, not the `**` around the ID, and not the `~~` of a retirement, whose
  # reason the statement keeps (SPEC-5) — and the spec's line wrapping collapses
  # to single spaces.
  defp statement(text, "~~"), do: text |> String.replace("~~", "", global: false) |> clean()
  defp statement(text, _retired), do: clean(text)

  defp clean(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # CITE-4: what a corpus is reused against — each spec's name, size, inode and
  # modification time, which is what `Elia.Store.Cache` keeps for a saved chat
  # too. An edit that leaves the size alone is still seen, because writing a file
  # moves its modification time on.
  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {size, mtime, inode}
      _ -> nil
    end
  end

  # The newest modification time among the corpus's files. A file written in the
  # same second as the read that took it carries that second as its mtime, and a
  # second write in that same second would leave the stamp looking unchanged, so
  # an entry read in a second no later than this one is not trusted: it is read
  # again until a read lands in a later second, after which any write moves the
  # mtime and is seen.
  defp newest_mtime(stamps) do
    stamps
    |> Enum.map(fn
      {_path, {_size, mtime, _inode}} -> mtime
      _ -> 0
    end)
    |> Enum.max(fn -> 0 end)
  end
end
