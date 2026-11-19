defmodule EliaWeb.FilesRawControllerTest do
  use EliaWeb.ConnCase, async: false

  alias Elia.{Projects, Workspace}

  @dir "files_raw_fixture"
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

  defp in_root(path), do: Path.join(Workspace.root(), path)

  setup do
    File.rm_rf!(in_root(@dir))
    File.mkdir_p!(in_root("#{@dir}/a-folder"))
    File.mkdir_p!(in_root("#{@dir}/folder.png"))
    File.write!(in_root("#{@dir}/shot.png"), @png)
    File.write!(in_root("#{@dir}/notes.txt"), "hello")
    File.write!(in_root("#{@dir}/clip.mp4"), "not really a video")
    File.write!(in_root("#{@dir}/voice.mp3"), "not really audio")
    File.write!(in_root("#{@dir}/paper.pdf"), "%PDF-1.4")
    on_exit(fn -> File.rm_rf!(in_root(@dir)) end)
  end

  # EXPL-24
  test "serves a previewed file's bytes, with its type and validators", %{conn: conn} do
    conn = get(conn, ~p"/files/raw?#{%{path: "#{@dir}/shot.png"}}")

    assert conn.status == 200
    assert conn.resp_body == @png
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"\d+-\d+"$/
    assert [modified] = get_resp_header(conn, "last-modified")
    assert modified =~ ~r/ \d\d:\d\d:\d\d GMT$/
    # EXPL-24: an image is the only kind that can carry script, so its own URL
    # must not be a way to run one on this origin.
    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; sandbox"
           ]
  end

  # EXPL-22, EXPL-24
  test "serves every kind of preview with its own content type", %{conn: conn} do
    for {file, type} <- [
          {"clip.mp4", "video/mp4"},
          {"voice.mp3", "audio/mpeg"},
          {"paper.pdf", "application/pdf"}
        ] do
      conn = get(conn, ~p"/files/raw?#{%{path: "#{@dir}/#{file}"}}")
      assert conn.status == 200, file
      assert get_resp_header(conn, "content-type") == [type], file
      # The browser's own viewers are left their own policies.
      refute get_resp_header(conn, "content-security-policy") |> Enum.any?(&(&1 =~ "sandbox")),
             file
    end
  end

  # EXPL-24: a page opened again revalidates instead of fetching the file again.
  test "answers 304 when the file is unchanged", %{conn: conn} do
    conn = get(conn, ~p"/files/raw?#{%{path: "#{@dir}/shot.png"}}")
    assert [etag] = get_resp_header(conn, "etag")

    conn =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/files/raw?#{%{path: "#{@dir}/shot.png"}}")

    assert conn.status == 304
    assert conn.resp_body == ""

    # A file that changed since is served afresh.
    File.write!(in_root("#{@dir}/shot.png"), @png <> <<0>>)

    conn =
      build_conn()
      |> put_req_header("if-none-match", etag)
      |> get(~p"/files/raw?#{%{path: "#{@dir}/shot.png"}}")

    assert conn.status == 200
    assert conn.resp_body == @png <> <<0>>
  end

  # EXPL-1, EXPL-2, EXPL-24, EXPL-25: the route reaches exactly what the page
  # may show, and says nothing about the rest.
  test "is a 404 for everything the page can't show", %{conn: conn} do
    File.ln_s!(in_root("#{@dir}/shot.png"), in_root("#{@dir}/link.png"))
    File.ln_s!("/etc", in_root("#{@dir}/etc-link"))

    for path <- [
          # not there
          "#{@dir}/nope.png",
          # a directory, whatever it is called
          "#{@dir}/folder.png",
          # a file the page shows as text
          "#{@dir}/notes.txt",
          # a symlink, and a path through one
          "#{@dir}/link.png",
          "#{@dir}/etc-link/hostname",
          # out of the workspace, and out of it by another name
          "../shot.png",
          "/etc/passwd",
          # protected
          ".git/config",
          # a name that ends a segment rather than a file
          "#{@dir}/shot.png/../../shot.png"
        ] do
      assert get(conn, ~p"/files/raw?#{%{path: path}}").status == 404, "#{path} was not a 404"
    end

    # No path at all.
    assert get(conn, ~p"/files/raw").status == 404
  end

  # EXPL-15, EXPL-24: a project's own folder is what the route serves from.
  test "serves a file of the project in view", %{conn: conn} do
    folder = in_root("#{@dir}/project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "logo.png"), @png)
    {:ok, project} = Projects.create("Raw", folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    conn = get(conn, ~p"/files/raw?#{%{project: project.id, path: "logo.png"}}")
    assert conn.status == 200
    assert conn.resp_body == @png

    # The same path in Elia's own project is not that file.
    assert get(conn, ~p"/files/raw?#{%{path: "logo.png"}}").status == 404
    # An unknown project browses Elia's own, as the page does (EXPL-15).
    assert get(conn, ~p"/files/raw?#{%{project: "nope", path: "#{@dir}/shot.png"}}").status == 200
  end

  # EXPL-17, EXPL-24: a chat in view serves from its own workspace, and a
  # `project` alongside it doesn't override that.
  test "serves a file of the chat in view", %{conn: conn} do
    folder = in_root("#{@dir}/chat-project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "shot.png"), @png <> "chat")
    {:ok, project} = Projects.create("Chat raw", folder)
    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "Where the picture is")

    on_exit(fn ->
      Elia.Store.delete(chat)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    conn = get(conn, ~p"/files/raw?#{%{chat: chat, path: "shot.png"}}")
    assert conn.status == 200
    assert conn.resp_body == @png <> "chat"

    conn = get(conn, ~p"/files/raw?#{%{chat: chat, project: "harness", path: "shot.png"}}")
    assert conn.resp_body == @png <> "chat"

    # A chat that isn't a saved one is ignored, as on the page (EXPL-17).
    assert get(conn, ~p"/files/raw?#{%{chat: "nosuchchat12", path: "#{@dir}/shot.png"}}").status ==
             200
  end
end
