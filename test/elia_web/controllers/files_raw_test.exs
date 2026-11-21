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
    File.write!(in_root("#{@dir}/page.html"), "<h1>hello</h1>")
    File.write!(in_root("#{@dir}/doc.xml"), "<a/>")
    File.write!(in_root("#{@dir}/template.heex"), "<p>hi</p>")
    File.write!(in_root("#{@dir}/blob.bin"), <<0, 1, 2>>)
    on_exit(fn -> File.rm_rf!(in_root(@dir)) end)
  end

  # EXPL-24
  test "serves a file's bytes, with its type and validators", %{conn: conn} do
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
    # EXPL-24: an image can carry script (an SVG can), so its own URL must not
    # be a way to run one on this origin — and its own inline styles still apply.
    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; style-src 'unsafe-inline'; sandbox"
           ]
  end

  # EXPL-24, EXPL-31: a page is served as a page, and an XML file and any other
  # file the page reads as text as text — a kind that can carry script under the
  # same policy as an image, and the others without one.
  test "serves a page and a text file for the raw view", %{conn: conn} do
    conn = get(conn, ~p"/files/raw?#{%{path: "#{@dir}/page.html"}}")

    assert conn.status == 200
    assert conn.resp_body == "<h1>hello</h1>"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; style-src 'unsafe-inline'; sandbox"
           ]

    for {file, body} <- [
          {"doc.xml", "<a/>"},
          {"template.heex", "<p>hi</p>"},
          {"notes.txt", "hello"}
        ] do
      conn = get(conn, ~p"/files/raw?#{%{path: "#{@dir}/#{file}"}}")

      assert conn.status == 200, file
      assert conn.resp_body == body, file
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"], file

      # A plain text file has no markup of its own, so nothing to restrict.
      if file == "notes.txt" do
        assert get_resp_header(conn, "content-security-policy") == []
      else
        assert get_resp_header(conn, "content-security-policy") == [
                 "default-src 'none'; style-src 'unsafe-inline'; sandbox"
               ],
               file
      end
    end
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

  # EXPL-1, EXPL-2, EXPL-24, EXPL-25, EXPL-31: the route reaches exactly what
  # the page may show raw, and says nothing about the rest.
  test "is a 404 for everything the page can't show", %{conn: conn} do
    File.ln_s!(in_root("#{@dir}/shot.png"), in_root("#{@dir}/link.png"))
    File.ln_s!("/etc", in_root("#{@dir}/etc-link"))

    for path <- [
          # not there
          "#{@dir}/nope.png",
          # a directory, whatever it is called
          "#{@dir}/folder.png",
          # a binary file, which the page reads as text and can't (EXPL-5)
          "#{@dir}/blob.bin",
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

  # EXPL-15, EXPL-24: the open project's folder is what the route serves from.
  test "serves a file of the open project", %{conn: conn} do
    folder = in_root("#{@dir}/project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "logo.png"), @png)
    {:ok, project} = Projects.create("Raw", folder)
    :ok = Projects.set_default(project.id)

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    conn = get(conn, ~p"/files/raw?#{%{path: "logo.png"}}")
    assert conn.status == 200
    assert conn.resp_body == @png

    # The same path in Elia's own project is not that file (EXPL-9).
    Elia.Settings.delete(:default_project)
    assert get(conn, ~p"/files/raw?#{%{path: "logo.png"}}").status == 404
  end

  # EXPL-17, EXPL-24: a chat in view serves from its own workspace, whatever
  # project is open.
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

    :ok = Elia.Projects.set_default("harness")

    conn = get(conn, ~p"/files/raw?#{%{chat: chat, path: "shot.png"}}")
    assert conn.resp_body == @png <> "chat"

    # A chat that isn't a saved one is ignored, as on the page (EXPL-17).
    assert get(conn, ~p"/files/raw?#{%{chat: "nosuchchat12", path: "#{@dir}/shot.png"}}").status ==
             200
  end
end
