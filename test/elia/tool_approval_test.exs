defmodule Elia.ToolApprovalTest do
  # Not async: the path policy's jail probe turns the host's jail setting on
  # for its own test (ISOL-20), as the file-tools tests do.
  use ExUnit.Case, async: false

  # APPR-7, APPR-15 to APPR-18: the APPR-7 table in `specs/tool-approval.md`
  # names every built-in tool the harness can offer an agent, with the approval
  # the tool declares (APPR-1) and the chats it is offered to (SUBTASK-1). These
  # tests read the table out of the spec and compare it with the tools
  # themselves, so a tool added, removed, re-approvaled or moved between a
  # parent and a sub-task without the table fails the suite.

  @spec_path Path.expand("../../specs/tool-approval.md", __DIR__)

  # APPR-16: the paths a policy is asked about — an extension path inside the
  # workspace, a core one inside it, a protected one, and one outside it.
  @skills "skills/x/SKILL.md"
  @core "lib/x.ex"
  @protected ".elia/x"
  @outside "/etc/hostname"

  # APPR-15, APPR-16, APPR-17
  test "the APPR-7 table agrees with the tools the skills offer" do
    violations = violations()

    assert violations == [],
           "the APPR-7 table in specs/tool-approval.md and the tools disagree:\n" <>
             Enum.map_join(violations, "\n", &("- " <> &1))
  end

  # APPR-16: a `path read` or `path write` cell is the policy the tool
  # enforces, asked on a path of each class rather than assumed.
  test "a path cell is the policy its tool enforces" do
    for row <- path_rows(), name <- row.names do
      tool = by_name()[name]
      ask = fn path, ctx -> decision(tool, path, ctx) end

      assert ask.(@skills, %{}) == :never,
             "#{name} should not need approval for #{@skills}"

      case row.kind do
        "path read" ->
          assert ask.(@outside, %{}) == :required,
                 "#{name} should need approval outside the workspace"

        "path write" ->
          assert ask.(@core, %{}) == :required, "#{name} should need approval for #{@core}"

          assert {:deny, _} = ask.(@protected, %{}),
                 "#{name} should be refused for #{@protected}"

          assert {:deny, _} = ask.(@outside, %{}),
                 "#{name} should be refused for #{@outside}"
      end
    end

    # FILE-12: with the jail on, a path outside the workspace is refused
    # rather than offered for approval. The suite runs with the jail off
    # (config/test.exs), so the host's setting is turned on here, as the
    # file-tools tests do (ISOL-20).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    for row <- path_rows(), name <- row.names do
      assert {:deny, _} = decision(by_name()[name], @outside, %{jail: true}),
             "#{name} should be refused outside the workspace under the jail"
    end
  end

  ## The table, read out of the spec (APPR-15)

  defp rows do
    case String.split(File.read!(@spec_path), "**APPR-7**", parts: 2) do
      [_, rest] -> rest |> table_lines() |> Enum.map(&row/1)
      _ -> []
    end
  end

  defp table_lines(rest) do
    rest
    |> String.split("\n")
    |> Enum.drop_while(&(not table_line?(&1)))
    |> Enum.take_while(&table_line?/1)
    # The header row and the `| --- |` row under it.
    |> Enum.drop(2)
  end

  defp table_line?(line), do: String.starts_with?(String.trim(line), "|")

  defp row(line) do
    cells =
      line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)

    case cells do
      [tool, approval, who] ->
        %{names: names(tool), kind: kind(approval), role: who, line: line, cells: 3}

      _ ->
        %{names: [], kind: nil, role: nil, line: line, cells: length(cells)}
    end
  end

  # A row names one or more tools, each in backticks (APPR-15).
  defp names(cell), do: Regex.scan(~r/`([^`]+)`/, cell) |> Enum.map(&List.last/1)

  # The approval cell starts with the kind; a note after it cites requirements
  # (APPR-15, APPR-16).
  defp kind(cell) do
    case String.split(cell) do
      ["path", kind | _] when kind in ["read", "write"] -> "path #{kind}"
      [kind | _] -> kind
    end
  end

  ## The tools (APPR-15, APPR-17)

  # The tools the harness offers: the built-in skills' own, and the `task`
  # skill's `finish_task`, which only a sub-task chat gets (SUBTASK-1). A
  # folder skill's script tools are the project's own and have no fixed name;
  # they always need approval (FOLDER-8, APPR-15).
  defp tools do
    builtin() ++ Elia.Skills.Tasks.child_skill().tools()
  end

  defp builtin, do: Enum.flat_map(Elia.Skills.builtin(), & &1.tools())

  defp by_name, do: Map.new(tools(), &{&1.name, &1})

  defp path_rows do
    for row <- rows(), row.cells == 3, row.kind in ["path read", "path write"], do: row
  end

  defp parent_names, do: Enum.map(builtin(), & &1.name)

  defp child_names do
    spawned = Enum.map(Elia.Skills.Tasks.tools(), & &1.name)
    finish = Enum.map(Elia.Skills.Tasks.child_skill().tools(), & &1.name)
    Enum.uniq(parent_names() -- spawned) ++ finish
  end

  defp role_of(name) do
    cond do
      name in parent_names() and name in child_names() -> "both"
      name in parent_names() -> "parent"
      true -> "child"
    end
  end

  ## What the table claims against what the tools are

  defp violations do
    rows = rows()
    offered = by_name()
    named = Enum.flat_map(rows, & &1.names)

    no_tools =
      for row <- rows, row.names == [], do: "a row names no tool: #{String.trim(row.line)}"

    wrong_shape =
      for row <- rows,
          row.names != [] and row.cells != 3,
          do: "a row has no Tool, Approval and Who cells: #{String.trim(row.line)}"

    duplicated =
      for {name, count} <- Enum.frequencies(named),
          count > 1,
          do: "`#{name}` is named by #{count} rows"

    missing =
      for name <- Map.keys(offered),
          name not in named,
          do: "`#{name}` is offered but the APPR-7 table does not name it"

    extra =
      for name <- Enum.uniq(named),
          not Map.has_key?(offered, name),
          do: "`#{name}` is in the APPR-7 table but no built-in skill offers it"

    wrong =
      for row <- rows,
          row.cells == 3,
          name <- row.names,
          tool = offered[name],
          tool != nil,
          message = disagreement(name, row, tool),
          message != nil,
          do: message

    no_tools ++ wrong_shape ++ duplicated ++ missing ++ extra ++ wrong
  end

  defp disagreement(name, row, tool) do
    declared = declared(tool)
    role = role_of(name)

    cond do
      row.kind != declared ->
        "`#{name}`: the table says `#{row.kind}`, the tool declares `#{declared}`"

      row.role != role ->
        "`#{name}`: the table says `#{row.role}`, the toolset makes it `#{role}`"

      true ->
        nil
    end
  end

  # APPR-16: the kind a tool declares, derived by asking it rather than from a
  # list that could drift in its turn (APPR-1). A policy that is a function is
  # read from what it decides for a core path inside the workspace: approval
  # there is the write policy (FILE-5, FILE-21), none is the read policy
  # (FILE-4, FILE-18, FILE-29).
  defp declared(tool) do
    case tool.approval do
      :never -> "never"
      :required -> "always"
      fun when is_function(fun, 2) -> path_kind(tool)
    end
  end

  defp path_kind(tool) do
    if decision(tool, @core, %{}) == :required, do: "path write", else: "path read"
  end

  defp decision(tool, path, ctx), do: Elia.Tool.approval(tool, input_for(tool, path), ctx)

  # The tool's required keys, filled from its schema, with `path` set to the
  # sample: a path policy reads nothing else.
  defp input_for(tool, path) do
    properties = tool.input_schema["properties"] || %{}

    (tool.input_schema["required"] || [])
    |> Map.new(&{&1, sample(properties[&1])})
    |> Map.put("path", path)
  end

  defp sample(%{"type" => "string"}), do: "x"
  defp sample(%{"type" => "array"}), do: ["x"]
  defp sample(%{"type" => "object"}), do: %{}
  defp sample(%{"type" => "boolean"}), do: true
  defp sample(%{"type" => type}) when type in ["integer", "number"], do: 1
  defp sample(_), do: "x"
end
