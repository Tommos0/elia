defmodule EliaWeb.FileLinks do
  @moduledoc """
  The paths the agent mentions, as links to the Files page
  (`specs/file-links.md`).

  A mention is a path in a reply's inline code (FLINK-1) or the `path` of a tool
  call's card (FLINK-4). It becomes a link only when the Files page could show
  it in the chat's own workspace (FLINK-5, EXPL-17); every other mention stays
  plain text, so a link never leads to a page that would show an error.
  """

  alias Elia.{Explorer, Workspace}

  @typedoc """
  Where a chat's mentions resolve (FLINK-5): the workspace that chat works in
  (PROJ-12) and its id, which the Files page is asked for.
  """
  @type t :: %{chat_id: binary(), root: binary()}

  @doc """
  The context a chat's mentions resolve in (FLINK-5): the workspace a chat works
  in (PROJ-12, EXPL-17) and its id.
  """
  @spec context(Elia.Projects.t(), binary()) :: t()
  def context(project, chat_id) do
    %{chat_id: chat_id, root: project.folder}
  end

  @doc """
  The Files page URL for `mention` (FLINK-1), or `nil` when it is not a path the
  Files page could show (FLINK-5).
  """
  @spec url(t() | nil, String.t()) :: String.t() | nil
  def url(nil, _mention), do: nil

  def url(%{chat_id: chat_id, root: root}, mention) do
    with text when is_binary(text) and text != "" <- trim(mention),
         path when path != "" <- strip_line(text),
         {:ok, abs} <- Explorer.safe_path(path, root),
         true <- showable?(abs) do
      query = URI.encode_query([{"chat", chat_id}, {"path", Workspace.relative(abs, root)}])
      "/files?" <> query
    else
      _ -> nil
    end
  end

  @doc """
  The Files page URL for a tool card's `path` input (UI-15, FLINK-4) — the same
  link a mention in a reply gets (FLINK-5) — or `nil` when the call has no path,
  or not one the Files page could show.
  """
  @spec card_url(t() | nil, map()) :: String.t() | nil
  def card_url(links, %{input: %{"path" => path}}), do: url(links, path)
  def card_url(_links, _item), do: nil

  @doc """
  The URL that serves `path`'s own bytes in the chat's workspace (EXPL-24) —
  where a card shows the picture a call looked at (VISION-16) — or `nil` when no
  route would serve it: a path that is no previewable file of the workspace
  (EXPL-25), so a card never carries a `src` into a 404.

  The route a chat's links name takes the chat's own workspace from the chat's
  id (EXPL-17), exactly as the Files page does (FLINK-5).
  """
  @spec raw_url(t() | nil, String.t() | nil) :: String.t() | nil
  def raw_url(nil, _path), do: nil
  def raw_url(_links, path) when not is_binary(path), do: nil

  def raw_url(%{chat_id: chat_id, root: root}, path) do
    case Explorer.preview_file(path, root) do
      {:ok, %{kind: :image, path: served}} ->
        "/files/raw?" <> URI.encode_query([{"chat", chat_id}, {"path", served}])

      _not_served ->
        nil
    end
  end

  @doc """
  The Files page URL for `path` at `line` (CITE-10) — what a citation's tooltip
  links to — or `nil` when the Files page could not show the path (FLINK-5).

  FLINK-2 leaves a *mention*'s line suffix out of its link, which is the file's
  page; this is the other way round, for a link whose whole point is the line
  (CITE-10), and it builds on the same URL so that both name the same page.
  """
  @spec line_url(t() | nil, String.t(), pos_integer()) :: String.t() | nil
  def line_url(nil, _path, _line), do: nil

  def line_url(%{} = links, path, line) when is_binary(path) and is_integer(line) do
    case url(links, path) do
      nil -> nil
      url -> url <> "&line=" <> Integer.to_string(line)
    end
  end

  @doc """
  The document with every mention in it linked (FLINK-1). A path inside a
  fenced code block is content, not a mention; the text of a link, and an
  image's alt text, are left alone, so no link lands inside another.
  """
  @spec link(MDEx.Document.t(), t() | nil) :: MDEx.Document.t()
  def link(%MDEx.Document{} = doc, nil), do: doc

  def link(%MDEx.Document{} = doc, links),
    do: %{doc | nodes: Enum.map(doc.nodes, &mention(&1, links))}

  # FLINK-1: an inline code span is a mention; its text stays the label (the
  # `code` node goes inside the link), so the mention still reads as code.
  defp mention(%MDEx.Code{literal: literal} = code, links) do
    case url(links, literal) do
      nil -> code
      href -> %MDEx.Link{nodes: [code], url: href}
    end
  end

  defp mention(%MDEx.Link{} = link, _links), do: link
  defp mention(%MDEx.Image{} = image, _links), do: image

  defp mention(%{nodes: nodes} = node, links),
    do: %{node | nodes: Enum.map(nodes, &mention(&1, links))}

  defp mention(node, _links), do: node

  # FLINK-2: a line suffix belongs to the label, never to the link's target.
  @line_suffix ~r/:\d+(?::\d+)?(?:-\d+)?\z/

  defp strip_line(text) do
    case Regex.run(@line_suffix, text) do
      [suffix] -> binary_part(text, 0, byte_size(text) - byte_size(suffix))
      _ -> text
    end
  end

  # FLINK-5: only what the Files page would show — a file or a directory that
  # `safe_path/2` has already cleared (inside the workspace, not protected, and
  # with no symlink on the way, EXPL-1, EXPL-2).
  defp showable?(abs) do
    case File.stat(abs) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :directory] -> true
      _ -> false
    end
  end

  defp trim(mention) when is_binary(mention), do: String.trim(mention)
  defp trim(_mention), do: nil
end
