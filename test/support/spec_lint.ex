defmodule Elia.SpecLint do
  @moduledoc false

  # The corpus rules, decided from the tree and from nothing else (SPEC-17,
  # TRACE-8): `hygiene/1` for `specs/spec-hygiene.md` (SPEC) and
  # `traceability/1` for `specs/test-traceability.md` (TRACE). Each returns one
  # message per violation. Both read `specs/**/*.md` — and, for TRACE, the test
  # files' paths — so they run in `mix test`, `bin/test` and `mix precommit`.

  @statuses ~w(Implemented Draft Planned Retired)
  @sections [
    "Requirements",
    "Configuration",
    "Terms",
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
  # A range's separator is `to`, `..` or a hyphen: an em dash is how the corpus
  # punctuates prose, and reading `ISOL-27 — ISOL-1` as a range would swallow the
  # range that follows it.
  @range ~r/\b([A-Z]+)-(\d+)\s*(?:to|\.\.|-)\s*(?:([A-Z]+)-)?(\d+)\b/
  @test_path ~r/\btest\/[\w.\-\/]+/

  ## Hygiene (SPEC)

  @doc """
  Every violation of the corpus rules under `root`, as one message each.
  """
  def hygiene(root) do
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

  @doc """
  The specs under `root`, read: each one's path, lines, title, status, `##`
  sections and requirement entries.
  """
  def spec_files(root) do
    root
    |> Path.join("specs/*.md")
    |> files("README.md")
    |> Enum.map(&read(&1, root))
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
        for id <- ids(line),
            prefix = String.split(id, "-") |> hd(),
            Map.has_key?(defined, prefix),
            not MapSet.member?(defined[prefix], id) do
          "#{file.path}:#{n} cites #{id}, which no spec defines (SPEC-15)"
        end
      end)
    end)
  end

  ## Traceability (TRACE)

  @doc """
  Every violation of the traceability rules under `root`, as one message each.
  """
  def traceability(root) do
    specs = spec_files(root)
    sections = Map.new(specs, &{&1.path, tests_section(&1)})

    named_file_violations(root, specs, sections) ++
      no_test_violations(specs, sections) ++
      accounting_violations(specs, sections)
  end

  @doc """
  A spec's `## Tests` section: its lines as `{text, line number}`, or `nil` when
  the spec has none.
  """
  def tests_section(file) do
    case Enum.find(file.sections, fn {name, _} -> name == "Tests" end) do
      nil ->
        nil

      {_, at} ->
        stop =
          file.sections
          |> Enum.filter(fn {_, line} -> line > at end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.min(fn -> length(file.lines) + 1 end)

        for {text, n} <- Enum.with_index(file.lines, 1), n > at, n < stop, do: {text, n}
    end
  end

  @doc "The `PREFIX-n` tokens in a text, with a range like `LOCAL-1 to LOCAL-4` expanded."
  def ids(text) do
    expanded =
      for [_, prefix, from, other, to] <- Regex.scan(@range, text),
          prefix == if(other == "", do: prefix, else: other),
          first = String.to_integer(from),
          last = String.to_integer(to),
          last > first and last - first < 200,
          n <- first..last,
          do: "#{prefix}-#{n}"

    plain = for [_, prefix, number] <- Regex.scan(@cite, text), do: "#{prefix}-#{number}"

    MapSet.new(expanded ++ plain)
  end

  @doc "Whether a line records, rather than tests, a requirement: `No test: …`."
  def no_test?(text) do
    text
    |> String.trim()
    |> String.replace_prefix("- ", "")
    |> String.starts_with?("No test:")
  end

  defp section_ids(section) do
    # One text, so a range whose two ends are on different lines — `CSET-1 to`
    # then `CSET-7` — is still read as the range it is.
    text =
      section
      |> Kernel.||([])
      |> Enum.reject(fn {text, _} -> no_test?(text) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.join("\n")

    ids(text)
  end

  # TRACE-3, TRACE-4: a `No test:` line names IDs the spec defines, before an em
  # dash, and says after it why they are not tested.
  defp no_test_violations(specs, sections) do
    Enum.flat_map(specs, fn file ->
      defined = MapSet.new(file.entries, & &1.id)

      List.flatten(
        for {text, n} <- sections[file.path],
            no_test?(text) do
          {named, reason} =
            case String.split(text, "—", parts: 2) do
              [named, reason] -> {ids(named), reason}
              [named] -> {ids(named), ""}
            end

          cond do
            MapSet.size(named) == 0 ->
              ["#{file.path}:#{n} a No test: line names no requirement (TRACE-3)"]

            not String.match?(reason, ~r/[A-Za-z]{3}/) ->
              [
                "#{file.path}:#{n} No test: for #{list(named)} does not say why, after an " <>
                  "em dash (TRACE-3)"
              ]

            true ->
              for id <- Enum.sort(named), id not in defined do
                "#{file.path}:#{n} No test: names #{id}, which #{file.path} does not define (TRACE-4)"
              end
          end
        end
      )
    end)
  end

  # TRACE-6: every path a Tests section names is in the tree.
  defp named_file_violations(root, specs, sections) do
    Enum.flat_map(specs, fn file ->
      for {text, n} <- sections[file.path],
          [path] <- Regex.scan(@test_path, text),
          not File.exists?(Path.join(root, path)) do
        "#{file.path}:#{n} names #{path}, which is not in the tree (TRACE-6)"
      end
    end)
  end

  # TRACE-2: every requirement is accounted for by a Tests section, or by a
  # `No test:` line of its own spec. TRACE-5: a retired one is exempt.
  defp accounting_violations(specs, sections) do
    cited =
      specs
      |> Enum.map(fn file -> section_ids(sections[file.path]) end)
      |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    Enum.flat_map(specs, fn file ->
      own =
        for {text, _} <- sections[file.path] || [], no_test?(text), id <- ids(text), do: id

      for entry <- file.entries,
          not entry.retired,
          not MapSet.member?(cited, entry.id),
          entry.id not in own do
        "#{file.path}:#{entry.line} #{entry.id} is not accounted for: no ## Tests section " <>
          "cites it and its own spec has no No test: line for it (TRACE-2)"
      end
    end)
  end

  defp list(ids), do: ids |> Enum.sort() |> Enum.join(", ")
end
