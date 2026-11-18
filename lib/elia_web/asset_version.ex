defmodule EliaWeb.AssetVersion do
  @moduledoc """
  The URL a shell asset is fetched under (PWA-8).

  The browser's own cache is what can still hold an old bundle once the worker
  is out of the picture (PWA-4), and a cached URL is answered without asking
  the server. So the link the page carries names a URL that has never been
  fetched before: the asset's path with a version read from the built file
  itself, its modification time and its size. Building the bundle again writes
  the file again, so the next page to load asks for a new URL.

  The file is read when the layout renders, from the tree of the code that
  renders it — the app's own `priv/static`, through `Application.app_dir/2`, so
  a chat's worktree reads its own build rather than the live tree's.
  """

  # What an asset that has not been built is fetched as. There is no version to
  # read, so there is one stable value: the page renders either way, and nothing
  # about it changes from one render to the next.
  @unbuilt "0"

  # The bundle: the two entry points the endpoint serves (DEPLOY-24), named the
  # way the version string names them (BUNDLE-1).
  @bundle [css: "/assets/css/app.css", js: "/assets/js/app.js"]

  @doc """
  The version of the bundle a tree serves (BUNDLE-1).

  `css=<version>;js=<version>`, each version read from the built file the way
  `versioned/2` reads one, so the page and the server compare one string.

  `dir` is where the files are read from, the app's own `priv/static` by
  default.
  """
  @spec current(Path.t() | nil) :: String.t()
  def current(dir \\ nil) do
    dir = dir || Application.app_dir(:elia, "priv/static")

    Enum.map_join(@bundle, ";", fn {name, path} ->
      "#{name}=#{version_of(path, dir)}"
    end)
  end

  @doc """
  `url` with the version of the file it names appended as `?v=<version>`.

  `dir` is where the files are read from, the app's own `priv/static` by
  default.
  """
  @spec versioned(String.t(), Path.t() | nil) :: String.t()
  def versioned(url, dir \\ nil) do
    [path | query] = String.split(url, "?", parts: 2)
    version = version_of(path, dir || Application.app_dir(:elia, "priv/static"))

    case query do
      [] -> path <> "?v=" <> version
      [query] -> path <> "?" <> query <> "&v=" <> version
    end
  end

  @doc """
  The version of the file `path` names, or `#{@unbuilt}` when it is not there.
  """
  @spec version_of(String.t(), Path.t()) :: String.t()
  def version_of(path, dir) do
    file = Path.join(dir, String.trim_leading(path, "/"))

    case File.stat(file, time: :posix) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> "#{mtime}-#{size}"
      _ -> @unbuilt
    end
  end
end
