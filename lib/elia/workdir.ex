defmodule Elia.Workdir do
  @moduledoc """
  A chat's working directory (WD-1): the directory its file tool calls (FILE)
  and its `shell` call (SHELL-2) resolve a relative path against. It starts as
  the chat's workspace root and the `cd` tool changes it, so a chat can work
  inside one part of a tree without repeating the prefix in every path.

  It changes what a relative path names, never what a path is allowed to be:
  every path is still judged by its own class (`Elia.Workspace.classify/2`) and
  its own real location (WS-5), so a chat reaches no further by standing
  somewhere else — and a directory outside the workspace is refused outright
  (WD-5).

  The session owns the chat's directory (`Elia.Agent.Session`) and saves it with
  the chat (STORE-46); this module is the part every caller shares.
  """

  alias Elia.Workspace

  @doc """
  The directory a tool call's context resolves relative paths against (WD-1):
  the `cwd` its context carries, else its workspace root, else Elia's own root.

  A step's context carries the `cwd` the loop read from the session when the
  step began (WD-10), so every call of one step resolves against the same
  directory.
  """
  @spec of(map()) :: binary()
  def of(ctx), do: ctx[:cwd] || ctx[:workspace] || Workspace.root()

  @doc """
  The directory `path` names, from `base` — an absolute path, or one relative to
  `base` (WD-3) — as its real location (WS-5): `{:ok, dir}` when it is a
  directory inside `root`, and otherwise `{:error, message}` naming the path and
  the reason (WD-5).
  """
  @spec resolve(binary(), binary(), binary()) :: {:ok, binary()} | {:error, binary()}
  def resolve(path, base, root) do
    abs = Path.expand(path, base)

    case Workspace.real_location(abs) do
      :unresolvable ->
        {:error,
         "#{abs} goes through more symlinks than can be followed, so where it leads is unknown"}

      real ->
        cond do
          Workspace.classify(real, real_root(root)) == :outside -> {:error, outside(abs, real)}
          true -> existing_directory(real)
        end
    end
  end

  @doc """
  `abs` named relative to `root`, `.` for the root itself (WD-3) — the form a
  `cd` result gives, and what a chat is told when it asks where it is (WD-4).
  """
  @spec label(binary(), binary()) :: binary()
  def label(abs, root), do: Workspace.relative(abs, real_root(root))

  @doc """
  The workspace root with its links followed (WS-5): the directory a chat's
  working directory is compared with, so a root that is reached through a
  symlink is still the root (WD-7).
  """
  @spec real_root(binary()) :: binary()
  def real_root(root) do
    case Workspace.real_location(root) do
      :unresolvable -> root
      real -> real
    end
  end

  defp existing_directory(real) do
    case File.stat(real) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, real}
      {:ok, _} -> {:error, "#{real} is not a directory"}
      {:error, reason} -> {:error, "#{real}: #{:file.format_error(reason)}"}
    end
  end

  # WS-8: a path inside the workspace that resolves out of it says where it
  # goes, as the file tools' refusal does (FILE-39).
  defp outside(abs, real) when real == abs, do: "#{abs} is outside the workspace."
  defp outside(abs, real), do: "#{abs} resolves to #{real}, outside the workspace."
end
