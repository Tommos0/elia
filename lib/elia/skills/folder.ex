defmodule Elia.Skills.Folder do
  @moduledoc """
  Loads a skill from a folder, so skills can be added without recompiling.

      skills/<name>/
        SKILL.md      # required: frontmatter + instructions for the model
        tools.json    # optional: script-backed tools
        ...           # any scripts or files the skill uses

  `SKILL.md` starts with simple `key: value` frontmatter:

      ---
      name: git-summary
      description: Summarise recent git activity
      ---
      Instructions for the model, in Markdown.

  `tools.json` is a list of tools. `command` runs with `sh -c` in the skill
  folder. The tool input is passed as JSON in `$ELIA_INPUT`, and each
  top-level scalar field as `$ELIA_ARG_<FIELD>` (upper-cased), so input is
  never spliced into the command line:

      [{
        "name": "git_summary",
        "description": "Summarise commits since a date",
        "command": "./summary.sh \\"$ELIA_ARG_SINCE\\"",
        "input_schema": {
          "type": "object",
          "properties": {"since": {"type": "string"}},
          "required": ["since"]
        },
        "timeout_seconds": 30
      }]

  Script tools always require user approval: the agent can write these files
  itself, so they must not become a way around shell approval.
  """

  @name_format ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @tool_name_format ~r/^[a-zA-Z0-9_-]{1,64}$/

  @spec load(binary(), Path.t()) :: {:ok, Elia.Skill.t()} | {:error, binary()}
  def load(dir, root \\ Elia.Workspace.root()) do
    with {:ok, text} <- read(Path.join(dir, "SKILL.md")),
         {:ok, meta, body} <- frontmatter(text),
         {:ok, name} <- fetch(meta, "name", @name_format),
         {:ok, description} <- fetch(meta, "description"),
         {:ok, tools} <- load_tools(dir) do
      {:ok,
       %Elia.Skill{
         name: name,
         description: description,
         instructions:
           String.trim(body) <> "\n\nSkill folder: #{Elia.Workspace.relative(dir, root)}",
         tools: tools,
         source: {:folder, dir}
       }}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        {:error, "cannot read #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp frontmatter(text) do
    case String.split(String.replace(text, "\r\n", "\n"), ~r/^---\s*$/m, parts: 3) do
      ["", header, body] ->
        meta =
          for line <- String.split(header, "\n"),
              [key, value] <- [String.split(line, ":", parts: 2)],
              into: %{},
              do: {String.trim(key), value |> String.trim() |> String.trim("\"")}

        {:ok, meta, body}

      _ ->
        {:error, "SKILL.md must start with a --- frontmatter block ---"}
    end
  end

  defp fetch(map, key, format \\ nil) do
    case map[key] do
      value when is_binary(value) and value != "" ->
        if format && not Regex.match?(format, value),
          do: {:error, "#{key} #{inspect(value)} must match #{Regex.source(format)}"},
          else: {:ok, value}

      _ ->
        {:error, "missing #{key}"}
    end
  end

  defp load_tools(dir) do
    path = Path.join(dir, "tools.json")

    with true <- File.exists?(path),
         {:ok, text} <- read(path) do
      case Jason.decode(text) do
        {:ok, specs} when is_list(specs) -> collect_tools(specs, dir)
        {:ok, _} -> {:error, "tools.json must be a JSON list"}
        {:error, error} -> {:error, "tools.json: #{Exception.message(error)}"}
      end
    else
      false -> {:ok, []}
      error -> error
    end
  end

  defp collect_tools(specs, dir) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, i}, {:ok, acc} ->
      case build_tool(spec, dir) do
        {:ok, tool} -> {:cont, {:ok, acc ++ [tool]}}
        {:error, reason} -> {:halt, {:error, "tools.json entry #{i}: #{reason}"}}
      end
    end)
  end

  defp build_tool(spec, dir) when is_map(spec) do
    schema = spec["input_schema"] || %{"type" => "object", "properties" => %{}}

    with {:ok, name} <- fetch(spec, "name", @tool_name_format),
         {:ok, description} <- fetch(spec, "description"),
         {:ok, command} <- fetch(spec, "command"),
         true <-
           (is_map(schema) and schema["type"] == "object") ||
             {:error, "input_schema must be an object schema"} do
      timeout = :timer.seconds(spec["timeout_seconds"] || 60)

      {:ok,
       %Elia.Tool{
         name: name,
         description: description,
         input_schema: schema,
         approval: :required,
         run: fn input, ctx -> run_script(command, dir, input, timeout, ctx) end
       }}
    end
  end

  defp build_tool(_spec, _dir), do: {:error, "must be an object"}

  defp run_script(command, dir, input, timeout, ctx) do
    with :ok <- ensure_checkpoint(ctx) do
      args =
        for {key, value} <- input, is_binary(value) or is_number(value) or is_boolean(value) do
          {"ELIA_ARG_" <> String.upcase(String.replace(key, ~r/[^A-Za-z0-9]/, "_")),
           to_string(value)}
        end

      env = [
        {"ELIA_INPUT", Jason.encode!(input)},
        {"ELIA_WORKSPACE", workspace(ctx)} | args
      ]

      Elia.Skills.Shell.result(
        Elia.Shell.run(command, cd: dir, env: env, timeout: timeout),
        timeout
      )
    end
  end

  # The workspace root of the turn (PROJ-12): the chat's own worktree for a chat
  # in Elia's own project (DEPLOY-1), Elia's own root when unset.
  defp workspace(ctx), do: ctx[:workspace] || Elia.Workspace.root()

  # PROJ-14: only Elia's own project is checkpointed — in the workspace the
  # chat works in, its own worktree (DEPLOY-1).
  defp ensure_checkpoint(ctx) do
    if Elia.Projects.harness_ctx?(ctx),
      do: Elia.Checkpoint.ensure(ctx[:turn_id], workspace(ctx)),
      else: :ok
  end
end
