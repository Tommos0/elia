defmodule Elia.Uploads do
  @moduledoc """
  The files a message carries, written into the chat's own workspace
  (`specs/file-uploads.md`).

  An attachment lands in `uploads/` under the workspace the chat works in
  (UPLOAD-6, PROJ-12) — the folder of its project, which for a chat in Elia's
  own project is the live tree (DEPLOY-1) — where the agent reaches it with its
  own file tools (FILE). It is an ordinary file of that workspace and nothing
  of Elia's own: no other chat sees it, and no conversion is applied to it, so
  what the user handed over is what is there.
  """

  @dir "uploads"

  # UPLOAD-8: how far the search for a free name goes before giving up, so a
  # directory that is full of the same name fails rather than spins.
  @max_number 1000

  @doc """
  The directory a chat's attachments are written into (UPLOAD-6).

  It is created when it isn't there — the one write of a chat's own workspace
  that a chat does on its own — so a caller can write into it: `{:ok, path}`,
  or `{:error, reason}`, which is the reason `File.mkdir_p/1` gave.
  """
  @spec directory(binary()) :: {:ok, binary()} | {:error, term()}
  def directory(root) when is_binary(root) do
    dir = Path.join(root, @dir)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes one attachment into `root` (UPLOAD-6), under the name it keeps
  (UPLOAD-7) and without overwriting a file already there (UPLOAD-8).

  Returns the file's path relative to `root` — the path the message names
  (UPLOAD-10) — or the reason it could not be written (UPLOAD-9).
  """
  @spec write(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def write(root, name, content) when is_binary(root) and is_binary(content) do
    with {:ok, dir} <- directory(root),
         {:ok, path} <- free_path(dir, base_name(name)) do
      case File.write(path, content) do
        :ok -> {:ok, Path.relative_to(path, root)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  The name an attachment keeps (UPLOAD-7): the base name of what the browser
  gave it, with any path separator or control character in `_`, and `file` when
  what it gave names no file at all.
  """
  @spec base_name(binary()) :: binary()
  def base_name(name) when is_binary(name) do
    case name |> Path.basename() |> String.replace(~r/[[:cntrl:]\/\\]/u, "_") do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      base -> base
    end
  end

  # UPLOAD-8: a name `dir` already holds takes the first free number before its
  # extension, so `shot.png` becomes `shot-1.png` rather than an overwrite.
  defp free_path(dir, base) do
    ext = Path.extname(base)
    try_number(dir, String.replace_suffix(base, ext, ""), ext, 0)
  end

  defp try_number(_dir, _stem, _ext, n) when n > @max_number, do: {:error, :eexist}

  defp try_number(dir, stem, ext, n) do
    name = if n == 0, do: stem <> ext, else: stem <> "-#{n}" <> ext
    path = Path.join(dir, name)

    case File.stat(path) do
      {:ok, _stat} -> try_number(dir, stem, ext, n + 1)
      {:error, :enoent} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end
end
