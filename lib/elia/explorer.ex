defmodule Elia.Explorer do
  @moduledoc """
  Read-only access to the workspace for the file explorer page
  (`specs/file-explorer.md`).

  Paths are relative to a project's folder: Elia's own root by default, or the
  folder of the project being browsed (EXPL-15). Anything outside that folder,
  in a protected path (`.git`, `_build`, `deps`, `.elia`) or reached through a
  symlink is refused with `{:error, :forbidden}`. The browsed root itself is
  judged by what it points at (EXPL-20), so a project whose folder is a symlink
  to a directory is browsed like any other.
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

  @doc "Lists the directory at `rel` (\"\" is the browsed project's folder) under `root` (EXPL-15)."
  @spec list(String.t(), String.t()) :: {:ok, [entry()]} | {:error, error()}
  def list(rel, root \\ Workspace.root()) do
    with {:ok, abs} <- safe_path(rel, root),
         {:ok, :dir} <- type_of(abs, :not_a_directory, root),
         {:ok, names} <- File.ls(abs) |> posix() do
      entries =
        names
        |> Enum.map(&entry(abs, root, &1))
        |> Enum.reject(&(Workspace.classify(Path.join(abs, &1.name), root) == :protected))
        |> Enum.sort_by(&{&1.type != :dir, String.downcase(&1.name), &1.name})

      {:ok, entries}
    end
  end

  @doc "Reads the text file at `rel` under `root` (EXPL-15)."
  @spec read(String.t(), String.t()) ::
          {:ok,
           %{
             path: String.t(),
             size: non_neg_integer(),
             content: String.t(),
             truncated?: boolean()
           }}
          | {:error, error() | :binary}
  def read(rel, root \\ Workspace.root()) do
    with {:ok, abs} <- safe_path(rel, root),
         {:ok, :file} <- type_of(abs, :directory, root),
         {:ok, size} <- size(abs),
         {:ok, data} <- read_head(abs) do
      truncated? = size > @max_bytes
      data = binary_part(data, 0, min(byte_size(data), @max_bytes))

      case text(data, truncated?) do
        {:ok, content} ->
          {:ok,
           %{
             path: Workspace.relative(abs, root),
             size: size,
             content: content,
             truncated?: truncated?
           }}

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

  # EXPL-22: what the browser renders of a file itself, by extension, with the
  # content type it is served as (EXPL-24). A file that isn't here is shown as
  # text (EXPL-8).
  @previews %{
    ".png" => {:image, "image/png"},
    ".jpg" => {:image, "image/jpeg"},
    ".jpeg" => {:image, "image/jpeg"},
    ".gif" => {:image, "image/gif"},
    ".webp" => {:image, "image/webp"},
    ".avif" => {:image, "image/avif"},
    ".bmp" => {:image, "image/bmp"},
    ".ico" => {:image, "image/vnd.microsoft.icon"},
    ".svg" => {:image, "image/svg+xml"},
    ".pdf" => {:pdf, "application/pdf"},
    ".mp4" => {:video, "video/mp4"},
    ".m4v" => {:video, "video/mp4"},
    ".webm" => {:video, "video/webm"},
    ".ogv" => {:video, "video/ogg"},
    ".mov" => {:video, "video/quicktime"},
    ".mp3" => {:audio, "audio/mpeg"},
    ".wav" => {:audio, "audio/wav"},
    ".ogg" => {:audio, "audio/ogg"},
    ".oga" => {:audio, "audio/ogg"},
    ".m4a" => {:audio, "audio/mp4"},
    ".flac" => {:audio, "audio/flac"},
    ".aac" => {:audio, "audio/aac"},
    ".opus" => {:audio, "audio/opus"},
    ".weba" => {:audio, "audio/webm"}
  }

  # EXPL-31: the extensions of the files a browser parses as a document of its
  # own rather than as text. An HTML document is served as one; an XML file is
  # read as text like any other (EXPL-4) and served as text under the policy
  # EXPL-24 names.
  @html ~w(.html .htm)
  @xml ~w(.xml .heex .eex .leex)

  @type preview_kind :: :image | :pdf | :video | :audio

  @type preview :: %{
          path: String.t(),
          file: String.t(),
          kind: preview_kind(),
          type: String.t(),
          size: non_neg_integer(),
          mtime: non_neg_integer()
        }

  @doc """
  The preview a path has — `{:image | :pdf | :video | :audio, content_type}` —
  from its extension, ignoring case (EXPL-22), or `nil` for a file the page
  shows as text.
  """
  @spec preview(String.t()) :: {preview_kind(), String.t()} | nil
  def preview(path) do
    Map.get(@previews, path |> Path.extname() |> String.downcase())
  end

  @doc """
  The preview of the file at `rel` under `root`, once it is one the page may
  show (EXPL-25): a previewable (EXPL-22) regular file of the workspace, reached
  without a symlink (EXPL-1, EXPL-2), with the content type to serve it as and
  the size and modification time the route revalidates by (EXPL-24). Anything
  else is `{:error, :no_preview}` for a path nothing previews, or the same
  refusal reading it would give (EXPL-5).
  """
  @spec preview_file(String.t(), String.t()) :: {:ok, preview()} | {:error, error() | :no_preview}
  def preview_file(rel, root \\ Workspace.root()) do
    case preview(rel) do
      nil ->
        {:error, :no_preview}

      {kind, type} ->
        with {:ok, abs} <- safe_path(rel, root),
             {:ok, :file} <- type_of(abs, :directory, root),
             {:ok, stat} <- File.stat(abs, time: :posix) |> posix() do
          {:ok,
           %{
             path: Workspace.relative(abs, root),
             file: abs,
             kind: kind,
             type: type,
             size: stat.size,
             mtime: stat.mtime
           }}
        end
    end
  end

  @type raw_kind :: preview_kind() | :html | :xml | :text

  @type raw :: %{
          path: String.t(),
          file: String.t(),
          kind: raw_kind(),
          type: String.t(),
          size: non_neg_integer(),
          mtime: non_neg_integer()
        }

  @doc """
  What the browser renders of the file at `rel` under `root`, with the content
  type to serve it as, or none (EXPL-31): a path the page may preview (EXPL-25)
  as its own kind and type (EXPL-22) — an image, a PDF, a video, an audio file —
  an HTML document as `text/html`, and any other file the page reads as text
  (EXPL-4) as `text/plain`. A path that is forbidden, reached through a symlink,
  protected, a directory, missing, unreadable or binary has none (EXPL-1, EXPL-2,
  EXPL-5).
  """
  @spec raw_file(String.t(), String.t()) :: {:ok, raw()} | {:error, error()}
  def raw_file(rel, root \\ Workspace.root()) do
    case preview(rel) do
      {kind, type} -> raw_of(rel, root, kind, type)
      nil -> text_raw(rel, root)
    end
  end

  # EXPL-31: a file the browser doesn't render of itself is served raw only when
  # the page reads it as text, so a binary file has no raw view — the same read
  # the text view does decides it (EXPL-4).
  defp text_raw(rel, root) do
    with {:ok, text} <- read(rel, root) do
      kind = text_kind(text.path)
      raw_of(rel, root, kind, text_type(kind))
    end
  end

  defp text_kind(path) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in @html -> :html
      ext when ext in @xml -> :xml
      _ -> :text
    end
  end

  defp text_type(:html), do: "text/html; charset=utf-8"
  defp text_type(_kind), do: "text/plain; charset=utf-8"

  defp raw_of(rel, root, kind, type) do
    with {:ok, abs} <- safe_path(rel, root),
         {:ok, :file} <- type_of(abs, :directory, root),
         {:ok, stat} <- File.stat(abs, time: :posix) |> posix() do
      {:ok,
       %{
         path: Workspace.relative(abs, root),
         file: abs,
         kind: kind,
         type: type,
         size: stat.size,
         mtime: stat.mtime
       }}
    end
  end

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
  Expands `rel` against `root` (a project's folder) and checks it may be
  browsed. Returns the absolute path (EXPL-15).
  """
  @spec safe_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, :forbidden}
  def safe_path(rel, root \\ Workspace.root()) when is_binary(rel) do
    # EXPL-1
    with false <- String.contains?(rel, <<0>>),
         {abs, class} when class in [:core, :extension] <- Workspace.resolve(rel, root),
         false <- symlink_on_path?(abs, root) do
      {:ok, abs}
    else
      _ -> {:error, :forbidden}
    end
  end

  # EXPL-2
  defp symlink_on_path?(abs, root) do
    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end

  # EXPL-20: the browsed root is the workspace the user pointed the project at,
  # so its own type is what it points at — a root that is a symlink to a
  # directory is browsed like any other, while every path inside it is judged as
  # before (EXPL-2). `wrong` is the error for a path of the other kind (dir vs.
  # file).
  defp type_of(abs, wrong, root) do
    stat = if abs == Path.expand(root), do: File.stat(abs), else: File.lstat(abs)

    case stat do
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

  defp entry(dir, root, name) do
    abs = Path.join(dir, name)

    {type, size} =
      case File.lstat(abs) do
        {:ok, %File.Stat{type: :directory}} -> {:dir, nil}
        {:ok, %File.Stat{type: :regular, size: size}} -> {:file, size}
        {:ok, %File.Stat{type: :symlink}} -> {:symlink, nil}
        _ -> {:other, nil}
      end

    %{name: name, path: Workspace.relative(abs, root), type: type, size: size}
  end

  defp posix(result, fun \\ & &1)
  defp posix({:ok, value}, fun), do: {:ok, fun.(value)}
  defp posix({:error, :enoent}, _), do: {:error, :not_found}
  defp posix({:error, _}, _), do: {:error, :unreadable}
end
