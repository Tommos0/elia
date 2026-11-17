defmodule EliaWeb.PreviewControllerTest do
  use EliaWeb.ConnCase, async: false

  alias Elia.{LiveTree, Preview}

  @chat "previewChat"
  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    tree = LiveTree.create()
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      LiveTree.remove(tree)
    end)

    # PREVIEW-7, DEPLOY-28: a chat that made itself a worktree inside the folder
    # wrote its pictures in the worktree's own tmp/preview/.
    worktree = Path.join([tree, "tmp", "worktrees", @chat])
    dir = Preview.dir(worktree)
    File.mkdir_p!(dir)

    %{tree: tree, worktree: worktree, dir: dir}
  end

  # PREVIEW-7
  test "serves the picture a preview wrote in the chat's own tree", %{
    conn: conn,
    dir: dir
  } do
    File.write!(Path.join(dir, "0-root.png"), @png)

    conn = get(conn, "/preview/#{@chat}/0-root.png")

    assert conn.status == 200
    assert conn.resp_body == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    # PREVIEW-4, PREVIEW-7: a re-run writes the same names, so nothing is cached.
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  # PREVIEW-7
  test "is a 404 for anything else", %{conn: conn, dir: dir, worktree: worktree} do
    File.write!(Path.join(dir, "0-root.png"), @png)
    File.mkdir_p!(Path.join(dir, "dir.png"))
    File.write!(Path.join(worktree, "secret.png"), "not a preview")
    File.ln_s(Path.join(worktree, "secret.png"), Path.join(dir, "link.png"))

    for path <- [
          # not there
          "/preview/#{@chat}/1-root.png",
          # not an image
          "/preview/#{@chat}/notes.txt",
          # a directory
          "/preview/#{@chat}/dir.png",
          # a symlink out of the preview dir
          "/preview/#{@chat}/link.png",
          # a path that leads out of the preview dir
          "/preview/#{@chat}/..%2F..%2Fsecret.png",
          # no preview dir for this chat
          "/preview/otherChat/0-root.png",
          # not a chat id
          "/preview/bad%2Fid/0-root.png"
        ] do
      assert get(conn, path).status == 404, "#{path} was not a 404"
    end
  end
end
