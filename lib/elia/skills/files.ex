defmodule Elia.Skills.Files do
  @moduledoc """
  Read, write and edit files in the workspace.

  Approval follows `Elia.Workspace` classes: changes under `skills/` run
  without asking, other workspace files need approval, protected paths and
  paths outside the workspace are refused (reading outside needs approval).
  Every change checkpoints the workspace first.
  """

  @behaviour Elia.Skill

  alias Elia.Workspace

  @max_read_lines 2000

  @impl true
  def name, do: "files"

  @impl true
  def description, do: "Read, create and edit files in the workspace."

  @impl true
  def instructions do
    """
    Always use these tools, never shell commands (`cat`, `sed`, `echo >`, \
    scripts), to read, create and edit files: they apply the workspace policy. \
    Paths are relative to the workspace root (#{Workspace.root()}). Read a file \
    before editing it. `edit_file` replaces an exact string, which must occur \
    once unless `replace_all` is set; include enough surrounding lines to make \
    it unique. Changes under `skills/` apply without asking; other files need \
    the user's approval.
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
        run: &read_file/1
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
        description: "Replace `old_string` with `new_string` in a file.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "old_string" => %{"type" => "string"},
            "new_string" => %{"type" => "string"},
            "replace_all" => %{"type" => "boolean", "description" => "Replace every occurrence"}
          },
          "required" => ["path", "old_string", "new_string"]
        },
        approval: &write_policy/2,
        run: &edit_file/2
      }
    ]
  end

  ## Policies

  def read_policy(%{"path" => path}, _ctx) do
    case Workspace.resolve(path) do
      {_, :outside} -> :required
      _ -> :never
    end
  end

  def write_policy(%{"path" => path}, _ctx) do
    case Workspace.resolve(path) do
      {_, :extension} ->
        :never

      {_, :core} ->
        :required

      {abs, :protected} ->
        {:deny, "#{Workspace.relative(abs)} is protected and cannot be changed by tools."}

      {abs, :outside} ->
        {:deny, "#{abs} is outside the workspace."}
    end
  end

  ## Tools

  def read_file(%{"path" => path} = input) do
    {abs, _} = Workspace.resolve(path)

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

  def write_file(%{"path" => path, "content" => content}, ctx) do
    {abs, _} = Workspace.resolve(path)

    with_file_lock(abs, fn ->
      with :ok <- Elia.Checkpoint.ensure(ctx[:turn_id]),
           :ok <- File.mkdir_p(Path.dirname(abs)),
           :ok <- File.write(abs, content) do
        {:ok, "Wrote #{Workspace.relative(abs)} (#{byte_size(content)} bytes)"}
      else
        {:error, reason} when is_atom(reason) ->
          {:error, "Cannot write #{path}: #{:file.format_error(reason)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def edit_file(%{"path" => path, "old_string" => old, "new_string" => new} = input, ctx) do
    {abs, _} = Workspace.resolve(path)

    # The whole read-modify-write runs under the file's lock (FILE-11), so
    # concurrent edits of one file each see the previous edit's result.
    with_file_lock(abs, fn ->
      with {:ok, text} <- File.read(abs) |> file_error(path),
           {:ok, updated, count} <- replace(text, old, new, input["replace_all"] == true),
           :ok <- Elia.Checkpoint.ensure(ctx[:turn_id]),
           :ok <- File.write(abs, updated) |> file_error(path) do
        {:ok, "Edited #{Workspace.relative(abs)} (#{count} replacement#{if count != 1, do: "s"})"}
      end
    end)
  end

  # Serialises writers of one absolute path across processes (FILE-11).
  defp with_file_lock(abs, fun) do
    :global.trans({{__MODULE__, abs}, self()}, fun, [node()])
  end

  defp replace(_text, "", _new, _all?), do: {:error, "old_string must not be empty"}

  defp replace(text, old, new, all?) do
    case length(:binary.matches(text, old)) do
      0 ->
        {:error, "old_string not found in file"}

      1 ->
        {:ok, String.replace(text, old, new), 1}

      n when all? ->
        {:ok, String.replace(text, old, new), n}

      n ->
        {:error, "old_string occurs #{n} times; add context to make it unique or set replace_all"}
    end
  end

  defp file_error({:error, reason}, path) when is_atom(reason),
    do: {:error, "#{path}: #{:file.format_error(reason)}"}

  defp file_error(result, _path), do: result
end
