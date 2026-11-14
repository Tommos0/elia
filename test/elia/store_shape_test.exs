defmodule Elia.StoreShapeTest do
  # Not async: the store writes the app's own data directory, as the other store
  # tests do.
  use ExUnit.Case, async: false

  # STORE-40, STORE-41, STORE-42: the two tables in `specs/persistence.md` are
  # the one statement of a saved chat's keys and of the fields a listed chat
  # carries. These tests read both tables out of the spec and compare them with
  # what `Elia.Store.save/3` writes and what a listing actually carries, so a key
  # or a field added, dropped or renamed without its table fails the suite — the
  # same enforcement `test/elia/tool_approval_test.exs` gives the APPR-7 table,
  # and what an unenforced table would otherwise drift from (STORE-40).
  #
  # What this keeps: every key the file carries has a row, every row's key is
  # written, and the `Dropped at its default` column is right. What it cannot
  # see: an option `save/3` learns later, whose key this test never passes — the
  # save it compares with gives the options it knows (STORE-42).

  alias Elia.LLM.Message
  alias Elia.Store

  @spec_path Path.expand("../../specs/persistence.md", __DIR__)
  @turn ~U[2026-01-01 00:00:00Z]

  ## The tables, read out of the spec (STORE-40, STORE-41)

  # STORE-40: the rows of the table under STORE-1, each a key of the saved chat.
  defp saved_rows do
    for raw <- rows_after("**STORE-1**"), do: saved_row(raw)
  end

  # STORE-41: the rows of the table under STORE-6, each a field of a listing.
  defp listed_rows do
    for raw <- rows_after("**STORE-6**"), do: listed_row(raw)
  end

  defp rows_after(marker) do
    case String.split(File.read!(@spec_path), marker, parts: 2) do
      [_, rest] ->
        rest
        |> String.split("\n")
        |> Enum.drop_while(&(not table_line?(&1)))
        |> Enum.take_while(&table_line?/1)
        # The header row and the `| --- |` row under it.
        |> Enum.drop(2)
        |> Enum.map(&%{cells: cells(&1), line: &1})

      _ ->
        []
    end
  end

  defp table_line?(line), do: String.starts_with?(String.trim(line), "|")

  defp cells(line) do
    line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
  end

  # A table row: `| `version` | `1` | every save | no — … |`.
  defp saved_row(%{cells: [key, type, written, dropped] = cells, line: line})
       when length(cells) == 4 do
    %{
      key: name(key),
      type: type,
      written: written,
      dropped: dropped,
      cells: 4,
      line: line
    }
  end

  defp saved_row(%{cells: cells, line: line}), do: %{key: nil, cells: length(cells), line: line}

  # A table row: ``| `title` | … | any | STORE-7, STORE-33 |``.
  defp listed_row(%{cells: [field, holds, chats, from] = cells, line: line})
       when length(cells) == 4 do
    %{field: name(field), holds: holds, chats: chats, from: from, cells: 4, line: line}
  end

  defp listed_row(%{cells: cells, line: line}),
    do: %{field: nil, cells: length(cells), line: line}

  # The key or field a row names: the first thing in backticks (STORE-40).
  defp name(cell) do
    ~r/`([^`]+)`/ |> Regex.scan(cell) |> Enum.map(&List.last/1) |> List.first()
  end

  defp first(text), do: text |> String.split() |> List.first()

  defp dropped?(row), do: first(row.dropped) == "yes"

  ## The save that writes each key (STORE-42)

  # STORE-42: the option that makes `save/3` write a key at its non-default
  # value, so that a save giving every option writes every key a row that is
  # dropped at its default names. A row marked `yes` with no clause here leaves
  # its key out of that save, which the comparison below reports.
  defp option("model"),
    do: [model: %{provider: "openrouter", model: "vendor/m", name: "Vendor M"}]

  defp option("auto_approve"), do: [auto_approve: ["shell", "edit_file"]]
  defp option("project_id"), do: [project: "proj-1"]

  defp option("task"),
    do: [
      task: %{
        parent_id: "p1",
        parent_call_id: "c1",
        title: "A task",
        brief: "Do it",
        started_at: @turn,
        status: "done",
        start_commit: "abc",
        result: "done"
      }
    ]

  defp option("compaction"),
    do: [compaction: %{level: 2, covered: 5, summary: "so far", pins: [{1, nil}], ledger: ["x"]}]

  defp option("jail"), do: [jail: false]
  defp option("limits"), do: [limits: %{max_steps: 5}]
  defp option("effort"), do: [effort: "high"]
  defp option("title"), do: [title: "A title of its own"]
  defp option("turn"), do: [turn: %{id: "turn-1", started_at: @turn}]
  defp option("done"), do: [done: true]
  # The keys every save writes carry no option.
  defp option(_key), do: []

  defp all_options(rows), do: Enum.flat_map(rows, &option(&1.key))

  ## The tables have the shape this test reads

  test "the two tables in specs/persistence.md have the shape this test reads" do
    violations = saved_violations(saved_rows()) ++ listed_violations(listed_rows())

    assert violations == [],
           "the tables in specs/persistence.md are not shaped as STORE-40 and " <>
             "STORE-41 say:\n" <> Enum.map_join(violations, "\n", &("- " <> &1))
  end

  defp saved_violations(rows) do
    no_key =
      for row <- rows,
          row.key == nil,
          do: "a row under STORE-1 names no key: #{String.trim(row.line)}"

    wrong_shape =
      for row <- rows,
          row.key != nil and row.cells != 4,
          do:
            "a row under STORE-1 has no Key, Type, When and Dropped cells: " <>
              String.trim(row.line)

    duplicated =
      for {key, count} <- Enum.frequencies(Enum.map(rows, & &1.key)),
          count > 1,
          do: "`#{key}` is named by #{count} rows under STORE-1"

    marker =
      for row <- rows,
          row.key != nil and first(row.dropped) not in ["yes", "no"],
          do: "`#{row.key}`'s Dropped cell is not `yes …` or `no …`: #{String.trim(row.line)}"

    unwritten =
      for row <- rows,
          row.key != nil,
          dropped?(row),
          option(row.key) == [],
          do: "`#{row.key}` is marked dropped at its default and this test writes no save for it"

    no_key ++ wrong_shape ++ duplicated ++ marker ++ unwritten
  end

  defp listed_violations(rows) do
    no_field =
      for row <- rows,
          row.field == nil,
          do: "a row under STORE-6 names no field: #{String.trim(row.line)}"

    wrong_shape =
      for row <- rows,
          row.field != nil and row.cells != 4,
          do:
            "a row under STORE-6 has no Field, What, Which chats and From cells: " <>
              String.trim(row.line)

    duplicated =
      for {field, count} <- Enum.frequencies(Enum.map(rows, & &1.field)),
          count > 1,
          do: "`#{field}` is named by #{count} rows under STORE-6"

    marker =
      for row <- rows,
          row.field != nil and row.chats not in ["any", "task only"],
          do:
            "`#{row.field}`'s Which-chats cell is not `any` or `task only`: " <>
              String.trim(row.line)

    # STORE-41: every row is the index of the requirement that derives it.
    no_from =
      for row <- rows,
          row.field != nil,
          not String.match?(row.from, ~r/STORE-\d+/),
          do: "`#{row.field}`'s row names no STORE requirement: #{String.trim(row.line)}"

    no_field ++ wrong_shape ++ duplicated ++ marker ++ no_from
  end

  ## The tables against what the code writes and lists (STORE-42)

  test "the STORE-1 table is every key a saved chat carries" do
    rows = saved_rows()
    id = chat()

    # A save that gives no option carries exactly the keys the table says are
    # never dropped.
    :ok = Store.save(id, [Message.user("hi")])
    keys = keys(id)
    never = MapSet.new(for row <- rows, not dropped?(row), do: row.key)

    assert keys == never,
           "a save with no options does not write the STORE-1 rows marked `no`:\n" <>
             compare(keys, never)

    # And a save that gives every option carries every key the table names.
    :ok = Store.save(id, [Message.user("hi")], all_options(rows))
    keys = keys(id)

    assert keys == MapSet.new(rows, & &1.key),
           "a save with every option does not write the keys of the STORE-1 table:\n" <>
             compare(keys, MapSet.new(rows, & &1.key))
  end

  test "the STORE-6 table is every field a listed chat carries" do
    rows = listed_rows()
    named = MapSet.new(rows, & &1.field)

    # A task chat carries every field, the task-only ones included.
    task = chat()
    :ok = Store.save(task, [Message.user("hi")], all_options(saved_rows()))
    fields = fields(task)

    assert fields == named,
           "a listed task chat does not carry the fields of the STORE-6 table:\n" <>
             compare(fields, named)

    # A chat that is no sub-task carries the rows the table marks `any`, and no
    # others.
    plain = chat()
    :ok = Store.save(plain, [Message.user("hi")], all_options(non_task_rows()))
    fields = fields(plain)
    any = MapSet.new(for row <- rows, row.chats == "any", do: row.field)

    assert fields == any,
           "a listed chat that is no sub-task does not carry the STORE-6 rows marked " <>
             "`any`:\n" <> compare(fields, any)
  end

  defp non_task_rows, do: Enum.reject(saved_rows(), &(&1.key == "task"))

  ## The code

  # A chat of this test's own, removed at its end.
  defp chat do
    id = Elia.Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    id
  end

  defp keys(id), do: id |> term() |> Map.keys() |> names()
  defp fields(id), do: id |> Store.entry() |> Map.keys() |> names()

  defp names(keys), do: MapSet.new(keys, &Atom.to_string/1)

  defp term(id) do
    Store.dir() |> Path.join(id <> ".term") |> File.read!() |> :erlang.binary_to_term()
  end

  defp compare(got, named) do
    "  the table names: " <>
      Enum.join(Enum.sort(named), ", ") <>
      "\n  the code has:    " <>
      Enum.join(Enum.sort(got), ", ") <>
      "\n  only in the table: " <>
      Enum.join(Enum.sort(MapSet.difference(named, got)), ", ") <>
      "\n  only in the code:  " <>
      Enum.join(Enum.sort(MapSet.difference(got, named)), ", ")
  end
end
