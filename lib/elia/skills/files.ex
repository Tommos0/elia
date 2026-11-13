defmodule Elia.Skills.Files do
  @moduledoc """
  Read, write, edit, list, search and delete files in the workspace.

  Approval follows `Elia.Workspace` classes: changes under `skills/` run
  without asking, other workspace files need approval, protected paths and
  paths outside the workspace are refused (reading outside needs approval).
  Paths are resolved against the chat's project folder (PROJ-12), or the
  chat's own git worktree in Elia's own project (DEPLOY-1).

  With the jail on — the default (ISOL-16) — the tools reach the workspace and
  nothing else (FILE-12, FILE-13): a path outside it is refused instead of
  being offered for approval, and a path that resolves through a symlink out of
  the workspace is refused too, so the file tools reach no further than a
  jailed command does (ISOL-25).
  """

  @behaviour Elia.Skill

  alias Elia.Workspace

  @max_read_lines 2000
  # FILE-16
  @max_list_entries 200
  # FILE-25
  @default_context 2
  @max_context 20
  @default_matches 40
  @max_matches 200
  # FILE-27: a very long line — a minified bundle, say — is cut rather than
  # returned whole.
  @max_line_chars 400

  @impl true
  def name, do: "files"

  @impl true
  def description, do: "Read, create, edit, list, search and delete files in the workspace."

  @impl true
  def instructions do
    """
    Always use these tools, never shell commands (`cat`, `sed`, `echo >`, \
    scripts), to read, create and edit files: they apply the workspace policy. \
    Paths are relative to the workspace root, which is the chat's project folder \
    (PROJ-12). Read a file \
    before editing it. `edit_file` tries the exact string first — include enough \
    surrounding lines to make it unique — and if it is not there it retries \
    ignoring indentation, trailing whitespace and line endings, using that match \
    only when it is unique. An `old_string` that matches more than once is an \
    error, never a guess: add context or set `replace_all`. `new_string` is \
    required, and an empty one removes `old_string`. Changes under `skills/` \
    apply without asking; other files need the user's approval.

    `list_files` names one level of a directory — directories first, a file with \
    its size, a symlink with where it points — and `delete_file` removes a file, \
    a symlink or an empty directory, with the same approvals as a write (other \
    files in the workspace need the user's approval, `skills/` doesn't, and \
    protected or outside paths are refused).

    `search_files` finds text in the tree and returns the matched regions: a \
    `path:line` header and the lines around each match, the matched ones marked, \
    so one call replaces a search followed by reading the file. Use it instead \
    of `grep -n` through the shell. `pattern` is literal text, not a regular \
    expression; `glob` picks the files (`*.ex`, `lib/**/*.exs`); binary files and \
    the directories the tools can't change (`.git`, `_build`, `deps`, `.elia`) \
    are skipped.

    With the jail on — the default — these tools reach this chat's workspace and \
    nothing else (FILE-12): a path outside it is refused, not offered for the \
    user's approval, and a symlink is followed no further than the workspace \
    (FILE-13), so a link out of it is refused as well. In a chat whose jail the \
    user turned off, reading outside the workspace needs their approval, as \
    before. A refusal is the policy, not a broken path: don't look for another \
    way to reach the same file.
    """
  end

  @impl true
  def tools do
    [
      %Elia.Tool{
        name: "read_file",
        description:
          "Read a text file. Returns up to #{@max_read_lines} lines starting at `offset` (1-based).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "offset" => %{
              "type" => "integer",
              "description" => "First line to return (default 1)"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Number of lines (default #{@max_read_lines})"
            }
          },
          "required" => ["path"]
        },
        approval: &read_policy/2,
        run: &read_file/2
      },
      %Elia.Tool{
        name: "write_file",
        description: "Create or overwrite a file with `content`. Creates parent directories.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}, "content" => %{"type" => "string"}},
          "required" => ["path", "content"]
        },
        approval: &write_policy/2,
        run: &write_file/2
      },
      %Elia.Tool{
        name: "edit_file",
        # FILE-38: what the model needs to know to get a match first time, and
        # what to do when it cannot.
        description:
          "Replace `old_string` with `new_string` in a file. The exact string is tried " <>
            "first; if it is not there, a match ignoring indentation, trailing whitespace " <>
            "and line endings is used, and only when it is unique. An `old_string` that " <>
            "matches more than once is an error, never a guess: add context or set " <>
            "`replace_all`. An empty `new_string` removes `old_string`.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "old_string" => %{"type" => "string"},
            # FILE-37: required, and deliberately without a default: a call that
            # omitted it sent its text under another name often enough that an
            # empty default would delete what its caller meant to keep.
            "new_string" => %{
              "type" => "string",
              "description" => "Replacement text; an empty string removes `old_string`"
            },
            "replace_all" => %{"type" => "boolean", "description" => "Replace every occurrence"}
          },
          "required" => ["path", "old_string", "new_string"]
        },
        approval: &write_policy/2,
        run: &edit_file/2
      },
      %Elia.Tool{
        name: "list_files",
        description:
          "List one level of a directory (the workspace root by default): directories first, " <>
            "a file with its size in bytes, a symlink with its target. At most " <>
            "#{@max_list_entries} entries.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Directory (default the workspace root)"
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Number of entries (default #{@max_list_entries})"
            }
          },
          "required" => []
        },
        approval: &read_policy/2,
        run: &list_files/2
      },
      %Elia.Tool{
        name: "search_files",
        description:
          "Find `pattern` — literal, case-sensitive text, not a regular expression — in " <>
            "the workspace and return the matched regions: a `path:line` header and the " <>
            "lines around each match, the matched ones marked, so one call replaces a " <>
            "search followed by reading the file. `context` (default #{@default_context}) " <>
            "lines are shown around each match, and at most `limit` (default " <>
            "#{@default_matches}) matched lines are returned. `glob` picks the files " <>
            "(`*.ex`, `lib/**/*.exs`). Binary files, and the directories the tools can't " <>
            "change (`.git`, `_build`, `deps`, `.elia`), are skipped.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{"type" => "string", "description" => "Literal text to find"},
            "path" => %{
              "type" => "string",
              "description" => "File or directory (default the workspace root)"
            },
            "glob" => %{
              "type" => "string",
              "description" => "File filter, e.g. `*.ex` or `lib/**/*.exs`"
            },
            "context" => %{
              "type" => "integer",
              "description" =>
                "Lines shown around each match (default #{@default_context}, the most " <>
                  "#{@max_context})"
            },
            "limit" => %{
              "type" => "integer",
              "description" =>
                "Most matched lines reported (default #{@default_matches}, the most " <>
                  "#{@max_matches})"
            }
          },
          "required" => ["pattern"]
        },
        approval: &read_policy/2,
        run: &search_files/2
      },
      %Elia.Tool{
        name: "delete_file",
        description: "Delete a file, a symlink or an empty directory.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        },
        approval: &delete_policy/2,
        run: &delete_file/2
      }
    ]
  end

  ## Policies

  # FILE-4, FILE-18: `list_files` with no path means the workspace root, which
  # is inside the workspace like any other.
  def read_policy(input, ctx) do
    {abs, class} = Workspace.resolve(input["path"] || ".", root(ctx))

    cond do
      unreachable?(abs, ctx) -> {:deny, refusal(abs)}
      class == :outside -> :required
      true -> :never
    end
  end

  def write_policy(%{"path" => path}, ctx) do
    {abs, class} = Workspace.resolve(path, root(ctx))

    cond do
      unreachable?(abs, ctx) ->
        {:deny, refusal(abs)}

      class == :extension ->
        :never

      class == :core ->
        :required

      class == :protected ->
        {:deny,
         "#{Workspace.relative(abs, root(ctx))} is protected and cannot be changed by tools."}

      class == :outside ->
        {:deny, "#{abs} is outside the workspace."}
    end
  end

  # FILE-21: deleting is a change to the workspace, so it follows the write
  # policy (FILE-5) exactly: extension → no approval, core → approval, and a
  # protected or outside path refused.
  def delete_policy(input, ctx), do: write_policy(input, ctx)

  # FILE-12, FILE-13: with the jail on, the tools reach what a jailed command in
  # this workspace reaches and nothing else (ISOL-25). It follows the jail
  # decision, not bubblewrap (ISOL-12): a host that can't build one is confined
  # all the same, and the chat's own switch is what turns it off.
  defp unreachable?(abs, ctx), do: confined?(ctx) and not reachable?(abs, ctx)

  defp confined?(ctx), do: Elia.Shell.wanted?(jail: ctx[:jail])

  defp reachable?(abs, ctx), do: Elia.Shell.reachable?(abs, root(ctx))

  # FILE-13: a path that only looks inside the workspace says where it goes.
  defp refusal(abs) do
    real = Workspace.real_location(abs)

    where =
      if real == abs,
        do: "#{abs} is outside the workspace",
        else: "#{abs} resolves to #{real}, outside the workspace"

    where <> "; this chat's jail confines the file tools to it (FILE-12)."
  end

  # The refusal is a policy, not an approval prompt, so the run enforces it too:
  # what the tools may touch doesn't depend on anything else checking first.
  defp allowed(abs, ctx) do
    if unreachable?(abs, ctx), do: {:error, refusal(abs)}, else: :ok
  end

  ## Tools

  def read_file(%{"path" => path} = input, ctx \\ %{}) do
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx) do
      case File.read(abs) do
        {:ok, text} ->
          lines = String.split(text, "\n")
          offset = max(input["offset"] || 1, 1)
          limit = min(input["limit"] || @max_read_lines, @max_read_lines)
          slice = Enum.slice(lines, offset - 1, limit)
          last = offset + length(slice) - 1

          header =
            if offset > 1 or last < length(lines),
              do: "[lines #{offset}-#{last} of #{length(lines)}]\n",
              else: ""

          {:ok, header <> Enum.join(slice, "\n")}

        {:error, reason} ->
          {:error, "Cannot read #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  def write_file(%{"path" => path, "content" => content}, ctx) do
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx) do
      with_file_lock(abs, fn ->
        with :ok <- File.mkdir_p(Path.dirname(abs)),
             :ok <- File.write(abs, content) do
          {:ok, "Wrote #{Workspace.relative(abs, root(ctx))} (#{byte_size(content)} bytes)"}
        else
          {:error, reason} when is_atom(reason) ->
            {:error, "Cannot write #{path}: #{:file.format_error(reason)}"}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  def edit_file(%{"path" => path, "old_string" => old, "new_string" => new} = input, ctx) do
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx) do
      # The whole read-modify-write runs under the file's lock (FILE-11), so
      # concurrent edits of one file each see the previous edit's result.
      with_file_lock(abs, fn ->
        with {:ok, text} <- File.read(abs) |> file_error(path),
             {:ok, updated, count, matched} <-
               replace(text, old, new, input["replace_all"] == true),
             :ok <- File.write(abs, updated) |> file_error(path) do
          {:ok,
           "Edited #{Workspace.relative(abs, root(ctx))} " <>
             "(#{count} replacement#{plural(count)}#{how(matched)})"}
        end
      end)
    end
  end

  # FILE-9, FILE-32: the count, and which match it was when the whitespace
  # tolerant one (FILE-31) did the work — the caller then knows its `old_string`
  # was not exact, which matters where indentation is code.
  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp how(:exact), do: ""
  defp how(:whitespace), do: ", whitespace-tolerant match"

  # FILE-15, FILE-16, FILE-17: one level of a directory, directories first, at
  # most @max_list_entries entries.
  def list_files(input, ctx \\ %{}) do
    path = input["path"] || "."
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx),
         {:ok, names} <- ls(abs, path) do
      entries = names |> Enum.map(&entry(abs, root(ctx), &1)) |> order()
      limit = min(input["limit"] || @max_list_entries, @max_list_entries)
      {shown, rest} = Enum.split(entries, max(limit, 0))

      more = if rest == [], do: [], else: ["[+#{length(rest)} more entries]"]
      label = Workspace.relative(abs, root(ctx))

      lines = ["[#{label} (#{length(entries)} entries)]" | Enum.map(shown, & &1.line)] ++ more

      {:ok, Enum.join(lines, "\n")}
    end
  end

  # FILE-24..FILE-30: find text in the workspace and return the matched
  # regions, so a search doesn't need a `grep -n` and a `read_file` after it.
  def search_files(%{"pattern" => pattern} = input, ctx \\ %{}) do
    path = input["path"] || "."
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx),
         :ok <- non_empty(pattern),
         {:ok, files} <- targets(abs, path, input["glob"], root(ctx)) do
      context = clamp(input["context"] || @default_context, 0, @max_context)
      limit = clamp(input["limit"] || @default_matches, 1, @max_matches)

      found =
        files
        |> Enum.map(&file_matches(&1, pattern, root(ctx)))
        |> Enum.reject(&is_nil/1)

      {:ok, render(found, pattern, context, limit)}
    end
  end

  # FILE-25: an empty pattern matches every line, which is never what was meant.
  defp non_empty(""), do: {:error, "pattern must not be empty"}
  defp non_empty(_pattern), do: :ok

  # FILE-25, FILE-28, FILE-30: what a search starts from — one file, or every
  # file under a directory.
  defp targets(abs, path, glob, root) do
    cond do
      File.dir?(abs) -> {:ok, walk(abs, abs, root, glob, []) |> order(root)}
      File.regular?(abs) -> {:ok, [abs]}
      true -> {:error, "Cannot search #{path}: #{why(abs)}"}
    end
  end

  defp why(abs) do
    case File.stat(abs) do
      {:ok, _} -> "it is not a file or a directory"
      {:error, reason} -> to_string(:file.format_error(reason))
    end
  end

  # FILE-28: only regular files are collected, a symlink is never followed (so a
  # search can't leave the workspace, FILE-13), a protected directory (WS-1) is
  # not walked into, and a directory that can't be listed is skipped.
  defp walk(dir, base, root, glob, acc) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, acc, fn name, acc ->
          abs = Path.join(dir, name)

          case File.lstat(abs) do
            {:ok, %File.Stat{type: :regular}} ->
              if glob?(glob, Path.relative_to(abs, base)), do: [abs | acc], else: acc

            {:ok, %File.Stat{type: :directory}} ->
              if Workspace.classify(abs, root) == :protected,
                do: acc,
                else: walk(abs, base, root, glob, acc)

            _ ->
              acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  # FILE-25: a glob with no `/` in it is matched against the file's name, any
  # other against its path relative to the search root.
  defp glob?(nil, _rel), do: true

  defp glob?(glob, rel) do
    subject = if String.contains?(glob, "/"), do: rel, else: Path.basename(rel)
    Regex.match?(glob_regex(glob), subject)
  end

  # `*` and `?` stop at a `/`, `**` doesn't, and `**/` also matches no
  # directory at all, so `lib/**/*.ex` finds `lib/a.ex` as well.
  defp glob_regex(glob) do
    body = glob |> String.graphemes() |> compile_glob([]) |> Enum.reverse() |> Enum.join()
    Regex.compile!("^" <> body <> "$")
  end

  defp compile_glob([], acc), do: acc
  defp compile_glob(["*", "*", "/" | rest], acc), do: compile_glob(rest, ["(?:.*/)?" | acc])
  defp compile_glob(["*", "*" | rest], acc), do: compile_glob(rest, [".*" | acc])
  defp compile_glob(["*" | rest], acc), do: compile_glob(rest, ["[^/]*" | acc])
  defp compile_glob(["?" | rest], acc), do: compile_glob(rest, ["[^/]" | acc])
  defp compile_glob([char | rest], acc), do: compile_glob(rest, [Regex.escape(char) | acc])

  # FILE-26: files in the order of their paths relative to the workspace root,
  # case-insensitively, the path itself breaking a tie.
  defp order(paths, root) do
    Enum.sort_by(paths, fn abs ->
      rel = Workspace.relative(abs, root)
      {String.downcase(rel), rel}
    end)
  end

  # FILE-26, FILE-28: the matched lines of one file, with its lines for the
  # context around them. A file that isn't valid UTF-8 is binary, and one that
  # can't be read is skipped: neither is an error.
  defp file_matches(abs, pattern, root) do
    with {:ok, text} <- File.read(abs),
         true <- String.valid?(text) do
      lines = String.split(text, "\n")

      matches =
        for {line, number} <- Enum.with_index(lines, 1),
            String.contains?(line, pattern),
            do: number

      if matches == [], do: nil, else: {Workspace.relative(abs, root), lines, matches}
    else
      _ -> nil
    end
  end

  # FILE-26: matches whose context regions overlap or touch are one region, so
  # no line is shown twice.
  defp regions({rel, lines, matches}, context) do
    last = length(lines)

    matches
    |> Enum.reduce([], fn number, regions ->
      case regions do
        [%{to: to} = region | rest] when number - context <= to + 1 ->
          [%{region | matches: region.matches ++ [number], to: number + context} | rest]

        _ ->
          [
            %{
              rel: rel,
              lines: lines,
              first: number,
              matches: [number],
              from: max(number - context, 1),
              to: number + context
            }
            | regions
          ]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | to: min(&1.to, last)})
  end

  # FILE-26, FILE-27: the header, then a block per region as far as the budget
  # of `limit` matched lines allows.
  defp render([], pattern, _context, _limit), do: "[no matches for #{inspect(pattern)}]"

  defp render(found, _pattern, context, limit) do
    total = found |> Enum.map(fn {_, _, matches} -> length(matches) end) |> Enum.sum()

    {blocks, shown} =
      found
      |> Enum.flat_map(&regions(&1, context))
      |> Enum.reduce({[], 0}, fn region, {blocks, shown} ->
        case min(length(region.matches), limit - shown) do
          take when take > 0 -> {[block(region, take, context) | blocks], shown + take}
          _ -> {blocks, shown}
        end
      end)

    more = if total - shown > 0, do: ["[+#{total - shown} more matches not shown]"], else: []

    header = "[#{total} matches in #{length(found)} files]"
    Enum.join([header | Enum.reverse(blocks) ++ more], "\n")
  end

  # FILE-27: a region is reported only as far as the budget allows, so its end
  # is the last reported match plus the context.
  defp block(region, take, context) do
    matches = Enum.take(region.matches, take)
    to = min(region.to, List.last(matches) + context)
    width = String.length(Integer.to_string(to))

    body =
      for number <- region.from..to//1 do
        marker = if number in matches, do: "> ", else: "  "
        label = String.pad_leading(Integer.to_string(number), width)
        "#{marker}#{label} | #{cut(Enum.at(region.lines, number - 1))}"
      end

    Enum.join(["#{region.rel}:#{region.first}" | body], "\n")
  end

  defp cut(line) do
    if String.length(line) > @max_line_chars,
      do: String.slice(line, 0, @max_line_chars - 1) <> "…",
      else: line
  end

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, min, _max), do: min

  # FILE-19, FILE-20, FILE-22: delete a file, a symlink or an empty directory,
  # under the same lock as a write (FILE-11) so the two can't race.
  def delete_file(%{"path" => path}, ctx \\ %{}) do
    {abs, _} = Workspace.resolve(path, root(ctx))

    with :ok <- allowed(abs, ctx) do
      with_file_lock(abs, fn ->
        with {:ok, type} <- type_of(abs, path),
             :ok <- remove(abs, type, path) do
          {:ok, "Deleted #{Workspace.relative(abs, root(ctx))}"}
        end
      end)
    end
  end

  defp ls(abs, path) do
    case File.ls(abs) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, "Cannot list #{path}: #{:file.format_error(reason)}"}
    end
  end

  # FILE-15: an entry is named by its path relative to the workspace root, a
  # directory with a trailing slash, a file with its size, a symlink with the
  # target it points at and anything else by name alone.
  defp entry(dir, root, name) do
    abs = Path.join(dir, name)
    rel = Workspace.relative(abs, root)

    case File.lstat(abs) do
      {:ok, %File.Stat{type: :directory}} ->
        %{name: name, type: :dir, line: rel <> "/"}

      {:ok, %File.Stat{type: :regular, size: size}} ->
        %{name: name, type: :file, line: "#{rel} (#{size} bytes)"}

      {:ok, %File.Stat{type: :symlink}} ->
        %{name: name, type: :symlink, line: "#{rel} -> #{target(abs)}"}

      _ ->
        %{name: name, type: :other, line: rel}
    end
  end

  defp target(abs) do
    case File.read_link(abs) do
      {:ok, target} -> target
      {:error, _} -> "?"
    end
  end

  # FILE-15: directories before the rest, each group by name, case-insensitively
  # (the name itself breaks a tie between names differing in case only).
  defp order(entries),
    do: Enum.sort_by(entries, &{&1.type != :dir, String.downcase(&1.name), &1.name})

  defp type_of(abs, path) do
    case File.lstat(abs) do
      {:ok, %File.Stat{type: type}} -> {:ok, type}
      {:error, reason} -> {:error, "Cannot delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  # FILE-19: only an empty directory goes; FILE-20: a symlink is removed as a
  # link, so `File.rm` never touches what it points at.
  defp remove(abs, :directory, path) do
    case File.rmdir(abs) do
      :ok ->
        :ok

      # OTP reports a directory that isn't empty as :eexist on Linux
      # (ENOTEMPTY on some hosts).
      {:error, reason} when reason in [:eexist, :enotempty] ->
        {:error, "#{path} is not empty"}

      {:error, reason} ->
        {:error, "Cannot delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp remove(abs, _type, path) do
    case File.rm(abs) do
      :ok -> :ok
      {:error, reason} -> {:error, "Cannot delete #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Serialises writers of one absolute path across processes (FILE-11).
  defp with_file_lock(abs, fun) do
    :global.trans({{__MODULE__, abs}, self()}, fun, [node()])
  end

  defp replace(_text, "", _new, _all?), do: {:error, "old_string must not be empty"}

  # FILE-7, FILE-31: the exact string is the first and preferred match, and the
  # whitespace-tolerant retry runs only when there is no exact occurrence. An
  # exact match that isn't unique is an error, not a reason to retry.
  defp replace(text, old, new, all?) do
    case :binary.matches(text, old) do
      [] ->
        tolerant_replace(text, old, new, all?)

      [_one] when not all? ->
        {:ok, String.replace(text, old, new), 1, :exact}

      positions when all? ->
        {:ok, String.replace(text, old, new), length(positions), :exact}

      positions ->
        # FILE-36: which lines they are on, so the caller can add the context
        # that tells them apart.
        lines = Enum.map(positions, fn {offset, _} -> line_at(text, offset) end)
        {:error, ambiguous("old_string occurs #{length(positions)} times", lines)}
    end
  end

  # FILE-31..FILE-34: the whitespace-tolerant retry. Lines are compared whole,
  # each with its own leading indentation and trailing whitespace removed (the
  # `\r` of a `\r\n` ending included), so a match covers the same lines with the
  # same text: it can never cover part of a line, or a line that differs by more
  # than whitespace, and it is used only when it is unique.
  defp tolerant_replace(text, old, new, all?) do
    file = text |> file_lines() |> List.to_tuple()
    wanted = old |> String.split("\n") |> Enum.map(&line_core/1) |> trim_blank_ends()
    size = length(wanted)
    total = tuple_size(file)

    candidates =
      if size == 0 or size > total,
        do: [],
        else: for(i <- 0..(total - size)//1, run_matches?(file, wanted, i), do: i)

    case candidates do
      [] ->
        # FILE-35: both attempts, since the caller reads why it failed.
        {:error,
         "old_string not found in file (no exact match, and no match ignoring " <>
           "indentation, trailing whitespace and line endings)"}

      [index] ->
        # FILE-32: the matched lines' own text goes; `new` is written exactly as
        # the caller gave it, the match never rewriting it.
        {:ok, apply_spans(text, [span(file, index, size)], new), 1, :whitespace}

      several when all? ->
        # FILE-34: every candidate, left to right, non-overlapping.
        spans = disjoint(file, several, size)
        {:ok, apply_spans(text, spans, new), length(spans), :whitespace}

      several ->
        # FILE-33: never one of several. The lines are the file's own, so two
        # candidates at different indentation are named as the two they are.
        {:error,
         ambiguous(
           "old_string occurs #{length(several)} times ignoring indentation, " <>
             "trailing whitespace and line endings",
           Enum.map(several, &(&1 + 1))
         )}
    end
  end

  defp ambiguous(prefix, lines) do
    "#{prefix} (at #{line_list(lines)}); add context to make it unique or set replace_all"
  end

  defp line_list([one]), do: "line #{one}"

  defp line_list(lines) do
    {last, rest} = List.pop_at(lines, -1)
    "lines #{Enum.join(rest, ", ")} and #{last}"
  end

  # The 1-based line an offset falls on.
  defp line_at(text, offset), do: 1 + length(:binary.matches(binary_part(text, 0, offset), "\n"))

  # A file's lines, each as `{content, start, finish}`: the content that is
  # compared, the byte where the line begins (its indentation included) and the
  # byte where its content ends (its trailing whitespace and line ending left
  # out) — the span FILE-32 replaces.
  defp file_lines(text) do
    {lines, _} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(0, fn line, start ->
        size = byte_size(line)
        {lead, trail} = bounds(line)
        core = binary_part(line, lead, size - lead - trail)
        {{core, start, start + size - trail}, start + size + 1}
      end)

    lines
  end

  defp line_core(line) do
    size = byte_size(line)
    {lead, trail} = bounds(line)
    binary_part(line, lead, size - lead - trail)
  end

  @whitespace [?\s, ?\t, ?\v, ?\f, ?\r]

  # How much of a line is indentation and how much is trailing whitespace.
  defp bounds(line) do
    size = byte_size(line)
    lead = leading_bytes(line, 0, size)
    {lead, trailing_bytes(line, lead, size)}
  end

  defp leading_bytes(_line, index, size) when index >= size, do: index

  defp leading_bytes(line, index, size) do
    if :binary.at(line, index) in @whitespace,
      do: leading_bytes(line, index + 1, size),
      else: index
  end

  defp trailing_bytes(_line, size, size), do: 0

  defp trailing_bytes(line, lead, size) do
    if :binary.at(line, size - 1) in @whitespace,
      do: 1 + trailing_bytes(line, lead, size - 1),
      else: 0
  end

  defp run_matches?(file, wanted, index) do
    wanted
    |> Enum.with_index()
    |> Enum.all?(fn {core, offset} -> elem(elem(file, index + offset), 0) == core end)
  end

  defp span(file, index, size) do
    {_, start, _} = elem(file, index)
    {_, _, finish} = elem(file, index + size - 1)
    {start, finish}
  end

  # FILE-34: candidates as they appear, skipping the ones a replaced span has
  # already covered (as String.replace does, left to right).
  defp disjoint(file, candidates, size) do
    {spans, _} =
      Enum.reduce(candidates, {[], nil}, fn index, {spans, previous_end} ->
        {start, finish} = span(file, index, size)

        if previous_end != nil and start < previous_end,
          do: {spans, previous_end},
          else: {[{start, finish} | spans], finish}
      end)

    Enum.reverse(spans)
  end

  # FILE-32: each span's own text goes and `new`, exactly as given, takes its
  # place; last span first, so the earlier offsets still hold.
  defp apply_spans(text, spans, new) do
    spans
    |> Enum.sort(:desc)
    |> Enum.reduce(text, fn {start, finish}, acc ->
      binary_part(acc, 0, start) <> new <> binary_part(acc, finish, byte_size(acc) - finish)
    end)
  end

  # A blank line at either end of `old_string` isn't significant to the tolerant
  # comparison, so `"one\ntwo\n"` matches the two lines `one` and `two`.
  defp trim_blank_ends(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  # The workspace root of the turn (PROJ-12): the chat's own worktree for a chat
  # in Elia's own project (DEPLOY-1), Elia's own root when unset.
  defp root(ctx), do: ctx[:workspace] || Workspace.root()

  defp file_error({:error, reason}, path) when is_atom(reason),
    do: {:error, "#{path}: #{:file.format_error(reason)}"}

  defp file_error(result, _path), do: result
end
