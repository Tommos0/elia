defmodule Elia.SpecHygiene.Lint do
  @moduledoc false

  # The corpus rules of `specs/spec-hygiene.md`, decided from the text of
  # `specs/` alone: no app, no browser, no network, no live workspace (SPEC-17).
  # `lint/1` returns one message per violation (SPEC-16).

  @statuses ~w(Implemented Draft Planned Retired)
  @sections [
    "Requirements",
    "Configuration",
    "Out of scope",
    "Stored data",
    "Implementation",
    "Tests"
  ]
  @entry ~r/^- (~~)?\*\*([A-Z]+)-(\d+)\*\*/
  @heading ~r/^## (.+?)\s*$/
  @row ~r/^\| \[[^\]]+\]\(([^)]+)\)\s*\|\s*`([A-Z]+)`\s*\|/
  @plan ~r/^- \[[^\]]+\]\(([^)]+)\)/
  @cite ~r/\b([A-Z]+)-(\d+)\b/

  @doc """
  Every violation of the corpus rules under `root`, as one message each.
  """
  def lint(root) do
    specs = files(Path.join(root, "specs/*.md"), "README.md")
    plans = files(Path.join(root, "specs/plans/*.md"), nil)
    spec_files = Enum.map(specs, &read(&1, root))
    plan_files = Enum.map(plans, &read(&1, root))

    Enum.flat_map(spec_files, &spec_violations/1) ++
      duplicate_violations(spec_files) ++
      index_violations(root, specs, plans, spec_files) ++
      citation_violations(spec_files ++ plan_files, defined(spec_files))
  end

  defp files(pattern, skip) do
    pattern
    |> Path.wildcard()
    |> Enum.reject(&(skip && Path.basename(&1) == skip))
    |> Enum.sort()
  end

  defp read(file, root) do
    lines = file |> File.read!() |> String.split("\n")

    %{
      path: Path.relative_to(file, root),
      lines: lines,
      title: title(lines),
      status: status(lines),
      sections: sections(lines),
      entries: entries(lines)
    }
  end

  # SPEC-10: the first line that says something is the title, `# <name>`.
  defp title(lines) do
    with i when i != nil <- Enum.find_index(lines, &(String.trim(&1) != "")),
         true <- String.starts_with?(String.trim(Enum.at(lines, i)), "# ") do
      i + 1
    else
      _ -> nil
    end
  end

  defp status(lines) do
    case Enum.find_index(lines, &String.starts_with?(&1, "Status:")) do
      nil -> nil
      i -> {String.trim(String.replace_prefix(Enum.at(lines, i), "Status:", "")), i + 1}
    end
  end

  defp sections(lines) do
    for {line, i} <- Enum.with_index(lines, 1),
        match = Regex.run(@heading, line),
        do: {Enum.at(match, 1), i}
  end

  defp entries(lines) do
    for {line, i} <- Enum.with_index(lines, 1), Regex.match?(@entry, line) do
      [_, retired, prefix, number] = Regex.run(@entry, line)

      %{
        id: "#{prefix}-#{number}",
        prefix: prefix,
        line: i,
        retired: retired == "~~",
        text: entry_text(lines, i)
      }
    end
  end

  # An entry runs to the next one, the next section, or the end of the file.
  defp entry_text(lines, line) do
    [
      Enum.at(lines, line - 1)
      | lines |> Enum.drop(line) |> Enum.take_while(&(not block_start?(&1)))
    ]
    |> Enum.join("\n")
  end

  defp block_start?(line), do: String.starts_with?(line, "- ") or String.starts_with?(line, "#")

  defp spec_violations(file) do
    title_violations(file) ++
      status_violations(file) ++
      section_violations(file) ++
      entry_violations(file)
  end

  defp title_violations(%{title: nil, path: path}), do: ["#{path} has no title (SPEC-10)"]
  defp title_violations(_file), do: []

  defp status_violations(%{status: nil, path: path}),
    do: ["#{path} has no Status: line (SPEC-10)"]

  defp status_violations(%{status: {value, line}, path: path}) do
    if value in @statuses do
      []
    else
      [
        "#{path}:#{line} Status: must be exactly one of #{Enum.join(@statuses, ", ")}, " <>
          "not #{inspect(value)} (SPEC-6)"
      ]
    end
  end

  defp section_violations(file) do
    unknown =
      for {name, line} <- file.sections, name not in @sections do
        "#{file.path}:#{line} ## #{name} is not a section a spec uses (SPEC-10)"
      end

    if Enum.any?(file.sections, fn {name, _} -> name == "Requirements" end) do
      unknown
    else
      ["#{file.path} has no ## Requirements section (SPEC-10)" | unknown]
    end
  end

  defp entry_violations(file) do
    prefixes = file.entries |> Enum.map(& &1.prefix) |> Enum.uniq()

    two_prefixes =
      if length(prefixes) > 1 do
        ["#{file.path} numbers its requirements under #{Enum.join(prefixes, " and ")} (SPEC-1)"]
      else
        []
      end

    two_prefixes ++ Enum.flat_map(file.entries, &entry_scope_violations(file, &1))
  end

  defp entry_scope_violations(file, entry) do
    retired =
      if entry.retired and not retired_reason?(entry.text) do
        ["#{file.path}:#{entry.line} #{entry.id} is retired without a reason (SPEC-5)"]
      else
        []
      end

    scoped =
      if section_at(file.sections, entry.line) == "Out of scope" do
        ["#{file.path}:#{entry.line} #{entry.id} is defined under Out of scope (SPEC-14)"]
      else
        []
      end

    retired ++ scoped
  end

  # SPEC-5: the reason follows one of the markers the corpus uses.
  defp retired_reason?(text) do
    Enum.any?(["Retired:", "Removed:", "Superseded by"], &String.contains?(text, &1))
  end

  defp section_at(sections, line) do
    sections
    |> Enum.filter(fn {_, at} -> at < line end)
    |> List.last()
    |> case do
      nil -> nil
      {name, _} -> name
    end
  end

  # SPEC-2, SPEC-3, SPEC-4: an ID names exactly one requirement, and a retired
  # number is spent.
  defp duplicate_violations(spec_files) do
    spec_files
    |> Enum.flat_map(fn file -> Enum.map(file.entries, &{&1.id, file.path, &1}) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn
      {_id, [_one]} ->
        []

      {id, [first | rest]} ->
        Enum.map(rest, fn {_, path, entry} ->
          if entry.retired or elem(first, 2).retired do
            "#{path}:#{entry.line} #{id} reuses the number of a retired requirement (SPEC-3, SPEC-4)"
          else
            "#{path}:#{entry.line} #{id} is defined twice, also at " <>
              "#{elem(first, 1)}:#{elem(first, 2).line} (SPEC-2)"
          end
        end)
    end)
  end

  defp index_violations(root, specs, plans, spec_files) do
    lines = root |> Path.join("specs/README.md") |> File.read!() |> String.split("\n")

    rows =
      for {line, i} <- Enum.with_index(lines, 1),
          match = Regex.run(@row, line),
          do: {Enum.at(match, 1), Enum.at(match, 2), i}

    listed = MapSet.new(rows, fn {link, _, _} -> Path.basename(link) end)

    missing =
      for spec <- specs, Path.basename(spec) not in listed do
        "specs/#{Path.basename(spec)} has no row in the index (SPEC-8)"
      end

    dead =
      for {link, _, line} <- rows, not File.exists?(Path.join(root, "specs/" <> link)) do
        "specs/README.md:#{line} links to #{link}, which is not there (SPEC-9)"
      end

    prefix =
      for {link, said, line} <- rows,
          file = Enum.find(spec_files, &(Path.basename(&1.path) == Path.basename(link))),
          file != nil,
          used = prefix_of(file),
          used != nil,
          used != said do
        "specs/README.md:#{line} says #{said}, but #{file.path} numbers its requirements #{used} (SPEC-9)"
      end

    retired =
      for file <- spec_files,
          match?({"Retired", _}, file.status),
          {link, _, line} <- rows,
          Path.basename(link) == Path.basename(file.path),
          not String.contains?(Enum.at(lines, line - 1), "Retired") do
        "specs/README.md:#{line} is #{file.path}, which is Retired, and does not say so (SPEC-7)"
      end

    missing ++ dead ++ prefix ++ retired ++ plan_violations(root, plans, lines)
  end

  defp prefix_of(file) do
    case Enum.uniq(Enum.map(file.entries, & &1.prefix)) do
      [prefix] -> prefix
      _ -> nil
    end
  end

  defp plan_violations(root, plans, lines) do
    start = Enum.find_index(lines, &Regex.match?(~r/^## Plans\s*$/, &1))

    listed =
      case start do
        nil ->
          []

        i ->
          lines
          |> Enum.drop(i + 1)
          |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
          |> Enum.flat_map(fn line ->
            case Regex.run(@plan, line) do
              nil -> []
              match -> [Enum.at(match, 1)]
            end
          end)
      end

    names = MapSet.new(listed, &Path.basename/1)

    missing =
      for plan <- plans, Path.basename(plan) not in names do
        "specs/plans/#{Path.basename(plan)} is not in the plans list (SPEC-8)"
      end

    dead =
      for link <- listed,
          not File.exists?(Path.join(root, "specs/plans/" <> Path.basename(link))) do
        "specs/README.md's plans list links to #{link}, which is not there (SPEC-9)"
      end

    no_section =
      if start == nil and plans != [] do
        ["specs/README.md has no ## Plans section (SPEC-8)"]
      else
        []
      end

    missing ++ dead ++ no_section
  end

  defp defined(spec_files) do
    spec_files
    |> Enum.flat_map(& &1.entries)
    |> Enum.group_by(& &1.prefix, & &1.id)
    |> Map.new(fn {prefix, ids} -> {prefix, MapSet.new(ids)} end)
  end

  # SPEC-15: a `PREFIX-n` whose prefix is a spec's own names a requirement that
  # spec defines — a retired one counts.
  defp citation_violations(files, defined) do
    Enum.flat_map(files, fn file ->
      file.lines
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, n} ->
        for [_, prefix, number] <- Regex.scan(@cite, line),
            Map.has_key?(defined, prefix),
            not MapSet.member?(defined[prefix], "#{prefix}-#{number}") do
          "#{file.path}:#{n} cites #{prefix}-#{number}, which no spec defines (SPEC-15)"
        end
      end)
    end)
  end
end

defmodule Elia.SpecHygieneTest do
  use ExUnit.Case, async: true

  alias Elia.SpecHygiene.Lint

  # The corpus rules of `specs/spec-hygiene.md`: the lint decides what the text
  # can (SPEC-16), from the tree and nothing else (SPEC-17).

  @root Path.expand("../..", __DIR__)

  @readme """
  # Specs

  ## Index

  | Spec | Prefix | Summary |
  | --- | --- | --- |
  | [Thing](thing.md) | `THING` | A thing |

  ## Plans
  """

  @thing """
  # Thing

  Status: Implemented

  A thing that is a thing.

  ## Requirements

  - **THING-1** It is a thing.

  ## Implementation

  `Elia.Thing`

  ## Tests

  `test/elia/thing_test.exs`
  """

  test "the specs follow the corpus rules (SPEC-16)" do
    violations = Lint.lint(@root)

    assert violations == [],
           "the specs break the corpus rules of specs/spec-hygiene.md:\n" <>
             Enum.join(violations, "\n")
  end

  test "an ID defined twice in one prefix fails the lint (SPEC-2)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - **THING-1** It is a thing.
             - **THING-1** It is another thing.

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "THING-1 is defined twice"
  end

  test "a retired number reused fails the lint (SPEC-3, SPEC-4)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - ~~**THING-1** It was a thing.~~ Retired: it is gone.
             - **THING-1** It is a thing.

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "reuses the number of a retired requirement"
  end

  test "a retirement without a reason fails the lint (SPEC-5)" do
    assert lint_tree(
             spec: """
             # Thing

             Status: Implemented

             A thing.

             ## Requirements

             - ~~**THING-1** It was a thing.~~

             ## Tests

             `test/elia/thing_test.exs`
             """
           ) =~ "THING-1 is retired without a reason"
  end

  test "a retirement with a reason passes the lint (SPEC-5)" do
    assert lint_tree(
             spec:
               thing(
                 requirements: """
                 - ~~**THING-1** It was a thing.~~ Superseded by THING-2.
                 - **THING-2** It is a thing.
                 """
               )
           ) == ""
  end

  test "prose on the Status: line fails the lint (SPEC-6)" do
    assert lint_tree(spec: thing(status: "Status: Implemented (phases 1 to 3)")) =~
             "Status: must be exactly one of"
  end

  test "a Status: word outside the four fails the lint (SPEC-6)" do
    assert lint_tree(spec: thing(status: "Status: Done")) =~ "Status: must be exactly one of"
  end

  test "a retired spec whose index row does not say so fails the lint (SPEC-7)" do
    assert lint_tree(
             spec:
               thing(
                 status: "Status: Retired",
                 requirements: "- ~~**THING-1** It was a thing.~~ Retired: it is gone."
               )
           ) =~ "which is Retired, and does not say so"
  end

  test "a spec missing from the index fails the lint (SPEC-8)" do
    assert lint_tree(readme: "# Specs\n\n## Index\n\n| Spec | Prefix | Summary |\n") =~
             "has no row in the index"
  end

  test "a plan missing from the plans list fails the lint (SPEC-8)" do
    assert lint_tree(plans: %{"plan.md" => "# Plan\n"}) =~ "is not in the plans list"
  end

  test "an index row whose file is gone fails the lint (SPEC-9)" do
    assert lint_tree(readme: String.replace(@readme, "(thing.md)", "(gone.md)")) =~
             "links to gone.md, which is not there"
  end

  test "an index prefix that differs from the file's IDs fails the lint (SPEC-9)" do
    assert lint_tree(readme: String.replace(@readme, "`THING`", "`OTHER`")) =~
             "numbers its requirements THING"
  end

  test "a ## section outside the shape fails the lint (SPEC-10)" do
    assert lint_tree(spec: thing() <> "\n## Data\n\nNothing is stored.\n") =~
             "## Data is not a section a spec uses"
  end

  test "a requirement defined under Out of scope fails the lint (SPEC-14)" do
    assert lint_tree(
             spec:
               thing(
                 extra: """
                 ## Out of scope

                 - **THING-2** It is not a thing.
                 """
               )
           ) =~ "THING-2 is defined under Out of scope"
  end

  test "a citation of an ID no spec defines fails the lint (SPEC-15)" do
    assert lint_tree(
             spec:
               thing(
                 extra: """
                 ## Out of scope

                 Another thing (THING-9) is not covered here.
                 """
               )
           ) =~ "cites THING-9, which no spec defines"
  end

  test "a fixture tree with no app and no workspace is enough (SPEC-17)" do
    # Nothing but Markdown is read: the lint takes a directory and returns the
    # violations in it, which is what these fixtures lint.
    assert lint_tree() == ""
  end

  defp thing(options \\ []) do
    """
    # Thing

    #{Keyword.get(options, :status, "Status: Implemented")}

    A thing that is a thing.

    ## Requirements

    #{Keyword.get(options, :requirements, "- **THING-1** It is a thing.")}

    ## Tests

    `test/elia/thing_test.exs`
    #{Keyword.get(options, :extra, "")}
    """
  end

  defp lint_tree(options \\ []) do
    dir = Path.join(System.tmp_dir!(), "spec-hygiene-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "specs/plans"))
    File.write!(Path.join(dir, "specs/README.md"), Keyword.get(options, :readme, @readme))
    File.write!(Path.join(dir, "specs/thing.md"), Keyword.get(options, :spec, @thing))

    for {name, body} <- Keyword.get(options, :plans, %{}) do
      File.write!(Path.join(dir, "specs/plans/#{name}"), body)
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    Lint.lint(dir) |> Enum.join("\n")
  end
end
