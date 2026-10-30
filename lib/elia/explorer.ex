defmodule Elia.Explorer do
  @moduledoc """
  Read-only access to the workspace for the file explorer page
  (`specs/file-explorer.md`).

  Paths are relative to `Elia.Workspace.root/0`. Anything outside the
  workspace, in a protected path (`.git`, `_build`, `deps`, `.elia`) or
  reached through a symlink is refused with `{:error, :forbidden}`.
  """

  alias Elia.Workspace

  # EXPL-4
  @max_bytes 256 * 1024

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: :dir | :file | :symlink | :other,
          size: non_neg_integer() | nil
        }

  @type error :: :forbidden | :not_found | :directory | :not_a_directory | :unreadable

  def max_bytes, do: @max_bytes

  @doc "Lists the directory at `rel` (\"\" is the workspace root)."
  @spec list(String.t()) :: {:ok, [entry()]} | {:error, error()}
  def list(rel) do
    with {:ok, abs} <- safe_path(rel),
         {:ok, :dir} <- type_of(abs, :not_a_directory),
         {:ok, names} <- File.ls(abs) |> posix() do
      entries =
        names
        |> Enum.map(&entry(abs, &1))
        |> Enum.reject(&(Workspace.classify(Path.join(abs, &1.name)) == :protected))
        |> Enum.sort_by(&{&1.type != :dir, String.downcase(&1.name), &1.name})

      {:ok, entries}
    end
  end

  @doc "Reads the text file at `rel`."
  @spec read(String.t()) ::
          {:ok,
           %{
             path: String.t(),
             size: non_neg_integer(),
             content: String.t(),
             truncated?: boolean()
           }}
          | {:error, error() | :binary}
  def read(rel) do
    with {:ok, abs} <- safe_path(rel),
         {:ok, :file} <- type_of(abs, :directory),
         {:ok, size} <- size(abs),
         {:ok, data} <- read_head(abs) do
      truncated? = size > @max_bytes
      data = binary_part(data, 0, min(byte_size(data), @max_bytes))

      case text(data, truncated?) do
        {:ok, content} ->
          {:ok,
           %{path: Workspace.relative(abs), size: size, content: content, truncated?: truncated?}}

        :error ->
          {:error, :binary}
      end
    end
  end

  @extensions %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".heex" => "xml",
    ".eex" => "xml",
    ".leex" => "xml",
    ".html" => "xml",
    ".htm" => "xml",
    ".xml" => "xml",
    ".svg" => "xml",
    ".erl" => "erlang",
    ".hrl" => "erlang",
    ".js" => "javascript",
    ".mjs" => "javascript",
    ".cjs" => "javascript",
    ".ts" => "typescript",
    ".css" => "css",
    ".json" => "json",
    ".md" => "markdown",
    ".markdown" => "markdown",
    ".sh" => "bash",
    ".bash" => "bash",
    ".yml" => "yaml",
    ".yaml" => "yaml",
    ".toml" => "ini",
    ".ini" => "ini",
    ".cfg" => "ini",
    ".py" => "python",
    ".rb" => "ruby",
    ".rs" => "rust",
    ".go" => "go",
    ".c" => "c",
    ".h" => "c",
    ".cpp" => "cpp",
    ".cc" => "cpp",
    ".hpp" => "cpp",
    ".sql" => "sql",
    ".diff" => "diff",
    ".patch" => "diff",
    ".mk" => "makefile"
  }

  @basenames %{
    "makefile" => "makefile",
    "dockerfile" => "dockerfile",
    "mix.lock" => "elixir",
    ".formatter.exs" => "elixir"
  }

  @doc """
  The highlight.js language for a file path, from its base name or extension
  (EXPL-11), or `nil` when unknown.
  """
  @spec language(String.t()) :: String.t() | nil
  def language(path) do
    base = path |> Path.basename() |> String.downcase()
    Map.get(@basenames, base) || Map.get(@extensions, Path.extname(base))
  end

  @doc """
  Expands `rel` against the workspace root and checks it may be browsed.
  Returns the absolute path.
  """
  @spec safe_path(String.t()) :: {:ok, String.t()} | {:error, :forbidden}
  def safe_path(rel) when is_binary(rel) do
    # EXPL-1
    with false <- String.contains?(rel, <<0>>),
         {abs, class} when class in [:core, :extension] <- Workspace.resolve(rel),
         false <- symlink_on_path?(abs) do
      {:ok, abs}
    else
      _ -> {:error, :forbidden}
    end
  end

  # EXPL-2
  defp symlink_on_path?(abs) do
    root = Workspace.root()

    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end

  # `wrong` is the error for a path of the other kind (dir vs. file).
  defp type_of(abs, wrong) do
    case File.lstat(abs) do
      {:ok, %File.Stat{type: :directory}} when wrong == :directory ->
        {:error, :directory}

      {:ok, %File.Stat{type: :directory}} ->
        {:ok, :dir}

      {:ok, %File.Stat{type: :regular}} when wrong == :not_a_directory ->
        {:error, :not_a_directory}

      {:ok, %File.Stat{type: :regular}} ->
        {:ok, :file}

      {:ok, _} ->
        {:error, :unreadable}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, :enotdir} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  defp size(abs), do: posix(File.stat(abs, time: :posix), & &1.size)

  defp read_head(abs) do
    case File.open(abs, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @max_bytes + 1) do
            data when is_binary(data) -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, _} -> {:error, :unreadable}
          end
        after
          File.close(io)
        end

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  # EXPL-4: NUL bytes or invalid UTF-8 mean binary. A cut may split a
  # character, so up to 3 trailing bytes may be dropped for truncated files.
  defp text(data, truncated?) do
    cond do
      :binary.match(data, <<0>>) != :nomatch -> :error
      String.valid?(data) -> {:ok, data}
      truncated? -> trim_partial(data, 3)
      true -> :error
    end
  end

  defp trim_partial(_data, -1), do: :error
  defp trim_partial(data, n) when byte_size(data) < n, do: :error

  defp trim_partial(data, n) do
    head = binary_part(data, 0, byte_size(data) - n)
    if String.valid?(head), do: {:ok, head}, else: trim_partial(data, n - 1)
  end

  defp entry(dir, name) do
    abs = Path.join(dir, name)

    {type, size} =
      case File.lstat(abs) do
        {:ok, %File.Stat{type: :directory}} -> {:dir, nil}
        {:ok, %File.Stat{type: :regular, size: size}} -> {:file, size}
        {:ok, %File.Stat{type: :symlink}} -> {:symlink, nil}
        _ -> {:other, nil}
      end

    %{name: name, path: Workspace.relative(abs), type: type, size: size}
  end

  defp posix(result, fun \\ & &1)
  defp posix({:ok, value}, fun), do: {:ok, fun.(value)}
  defp posix({:error, :enoent}, _), do: {:error, :not_found}
  defp posix({:error, _}, _), do: {:error, :unreadable}
end
