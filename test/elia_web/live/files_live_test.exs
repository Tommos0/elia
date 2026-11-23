defmodule EliaWeb.FilesLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Projects, Workspace}

  @dir "files_live_fixture"
  @project "files_live_swap"

  defp in_root(path), do: Path.join(Workspace.root(), path)

  # The URL a link like CITE-10's opens: the file and the line it names.
  defp files_url(path, line), do: "/files?" <> URI.encode_query(%{path: path, line: line})

  # A URL naming a path and nothing else, as the page's own links build it.
  defp path_url(path), do: "/files?" <> URI.encode_query(%{path: path})

  # EXPL-30, EXPL-33: a URL naming a path and the mode to show it in, which is
  # what the mode control patches to.
  defp mode_url(path, mode), do: ~p"/files?#{%{path: path, mode: mode}}"

  # EXPL-15: the page browses the open project (PROJ-28), so a test that wants
  # another one makes it the open one; Elia's own goes back afterwards.
  defp open_project(name, folder) do
    {:ok, project} = Projects.create(name, folder)
    :ok = Projects.set_default(project.id)
    on_exit(fn -> Elia.Settings.delete(:default_project) end)
    project
  end

  # EXPL-29: choose a project from the header's switcher.
  defp switch_project(view, id) do
    view |> element("#project-switcher") |> render_click()
    view |> element("#project-option-#{id}") |> render_click()
  end

  setup do
    File.rm_rf!(in_root(@dir))
    File.mkdir_p!(in_root("#{@dir}/inner"))
    File.write!(in_root("#{@dir}/hello.ex"), "defmodule Hello do\n  :ok\nend\n")
    File.write!(in_root("#{@dir}/inner/deep.txt"), "<b>not html</b>")
    File.write!(in_root("#{@dir}/blob.bin"), <<0, 1, 2>>)
    File.write!(in_root("#{@dir}/empty.txt"), "")
    on_exit(fn -> File.rm_rf!(in_root(@dir)) end)
  end

  # EXPL-10
  test "the header links to the explorer", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files")
    assert has_element?(view, "#files-link[href='/files']")
  end

  # EXPL-6, EXPL-7
  test "browses the root and opens directories by patching", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files")

    assert has_element?(view, "[data-entry='#{@dir}']")
    refute has_element?(view, "[data-entry='.git']")
    refute has_element?(view, "#parent-dir")
    assert has_element?(view, "#file-placeholder")

    view |> element("[data-entry='#{@dir}']") |> render_click()
    assert_patch(view, "/files?path=#{@dir}")
    assert has_element?(view, "[data-entry='#{@dir}/hello.ex']")
    assert has_element?(view, "#breadcrumbs a", @dir)
    assert has_element?(view, "#parent-dir")

    view |> element("#parent-dir") |> render_click()
    assert_patch(view, "/files")
  end

  # EXPL-6, EXPL-7, EXPL-8
  test "shows a file with line numbers next to its directory", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/hello.ex"}")

    assert has_element?(view, "#file-path", "#{@dir}/hello.ex")
    assert has_element?(view, "#file-header", "3 lines")
    assert render(element(view, "#file-gutter")) =~ "1\n2\n3"
    refute render(element(view, "#file-gutter")) =~ "4"
    assert has_element?(view, "#file-content", "defmodule Hello do")
    assert has_element?(view, "[data-entry='#{@dir}/hello.ex'][aria-current=true]")
    assert has_element?(view, "[data-entry='#{@dir}/blob.bin']")
    refute has_element?(view, "#file-truncated")
  end

  # EXPL-8
  test "file contents are escaped, not rendered", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/inner/deep.txt"}")
    assert has_element?(view, "#file-content", "<b>not html</b>")
    refute has_element?(view, "#file-content b")
  end

  # EXPL-8
  test "empty files show no lines", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/empty.txt"}")
    assert has_element?(view, "#file-header", "0 lines")
  end

  # EXPL-8
  test "notes truncated files", %{conn: conn} do
    File.write!(in_root("#{@dir}/big.txt"), String.duplicate("x\n", 200_000))
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/big.txt"}")
    assert has_element?(view, "#file-truncated")
  end

  # EXPL-8
  test "binary files show a notice", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/blob.bin"}")
    assert has_element?(view, "#file-binary")
    refute has_element?(view, "#file-content")
  end

  # EXPL-7
  test "symlinks are listed but not opened", %{conn: conn} do
    File.ln_s!("/etc", in_root("#{@dir}/link"))
    {:ok, view, _} = live(conn, ~p"/files?path=#{@dir}")
    assert has_element?(view, "span[data-entry='#{@dir}/link']", "symlink")
    refute has_element?(view, "a[data-entry='#{@dir}/link']")
  end

  # EXPL-1, EXPL-9
  test "forbidden and missing paths show a message and the root", %{conn: conn} do
    for path <- ["../..", "/etc", ".git", ".elia/sessions", "#{@dir}/missing.txt"] do
      {:ok, view, _} = live(conn, ~p"/files?#{[path: path]}")
      assert has_element?(view, "#file-error"), path
      assert has_element?(view, "[data-entry='#{@dir}']"), path
      refute has_element?(view, "#parent-dir"), path
    end
  end

  # EXPL-12, EXPL-13
  test "names the language for the highlight hook", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/hello.ex"}")
    assert has_element?(view, "#file-content[phx-hook=Highlight][data-language=elixir]")
    # The server still sends the plain text.
    refute render(element(view, "#file-content")) =~ "<span"
    assert has_element?(view, "#file-content", "defmodule Hello do")
  end

  # EXPL-12
  test "unknown file types are not highlighted", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/inner/deep.txt"}")
    assert has_element?(view, "#file-content")
    refute has_element?(view, "#file-content[data-language]")
  end

  # EXPL-12
  test "large and truncated files are not highlighted", %{conn: conn} do
    # Over 128 KiB but under the 256 KiB read limit.
    File.write!(in_root("#{@dir}/large.ex"), String.duplicate("x = 1\n", 30_000))
    File.write!(in_root("#{@dir}/huge.ex"), String.duplicate("x = 1\n", 60_000))

    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/large.ex"}")
    refute has_element?(view, "#file-truncated")
    refute has_element?(view, "#file-content[data-language]")

    {:ok, view, _} = live(conn, ~p"/files?path=#{"#{@dir}/huge.ex"}")
    assert has_element?(view, "#file-truncated")
    refute has_element?(view, "#file-content[data-language]")
  end

  # EXPL-27
  test "marks the line a link names", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/hello.ex", line: "2"]}")

    assert has_element?(view, "#file-content[data-line='2']")
    # The server still sends the plain text; the mark is the hook's (EXPL-13).
    refute render(element(view, "#file-content")) =~ "<span"
    assert has_element?(view, "#file-content", "defmodule Hello do")
  end

  # EXPL-27: a line that isn't one of the text in view is ignored, and the file
  # opens as it otherwise would.
  test "a line it can't use is ignored", %{conn: conn} do
    for line <- ["0", "-1", "1.5", "abc", "", "4", "2x"] do
      {:ok, view, _} = live(conn, files_url("#{@dir}/hello.ex", line))

      refute has_element?(view, "#file-content[data-line]"), line
      assert has_element?(view, "#file-content", "defmodule Hello do"), line
    end
  end

  # EXPL-27: a truncated file shows only its first part, so a line past that
  # part is past the text shown.
  test "a line past a truncated file's text is ignored", %{conn: conn} do
    File.write!(in_root("#{@dir}/long.txt"), String.duplicate("x\n", 200_000))

    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/long.txt", line: "10"]}")
    assert has_element?(view, "#file-truncated")
    assert has_element?(view, "#file-content[data-line='10']")

    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/long.txt", line: "150000"]}")
    refute has_element?(view, "#file-content[data-line]")
  end

  # EXPL-27: with no text in view there is no line to mark — a preview draws the
  # file itself, a binary file has no text, and a directory is a listing.
  test "a line with no text in view is ignored", %{conn: conn} do
    File.write!(in_root("#{@dir}/shot.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    for {path, element} <- [
          {"#{@dir}/shot.png", "img#file-preview"},
          {"#{@dir}/blob.bin", "#file-binary"},
          {@dir, "#file-list"}
        ] do
      {:ok, view, _} = live(conn, files_url(path, "2"))

      assert has_element?(view, element), path
      refute has_element?(view, "#file-content"), path
    end
  end

  # EXPL-28
  test "another file or directory leaves the line out of the URL", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/hello.ex", line: "2"]}")
    assert has_element?(view, "#file-content[data-line='2']")

    view |> element("[data-entry='#{@dir}/inner']") |> render_click()
    assert_patch(view, path_url("#{@dir}/inner"))

    view |> element("#parent-dir") |> render_click()
    assert_patch(view, path_url(@dir))

    view |> element("[data-entry='#{@dir}/hello.ex']") |> render_click()
    assert_patch(view, path_url("#{@dir}/hello.ex"))
    refute has_element?(view, "#file-content[data-line]")

    view |> element("#breadcrumbs a", "workspace") |> render_click()
    assert_patch(view, "/files")
  end

  # EXPL-15, EXPL-16, EXPL-29: the page browses the open project (PROJ-28) and
  # has no project control of its own; the header's switcher switches it to
  # another project in place, keeping the path in view when that project has it.
  test "browses the open project and switches to another in place", %{conn: conn} do
    # A project whose folder holds a path Elia's own root does not, to check the
    # fallback, and one both of them have, to check the path is kept.
    File.mkdir_p!(in_root("#{@project}/sub"))
    File.mkdir_p!(in_root("#{@project}/onlyproj"))
    File.write!(in_root("#{@project}/sub/keep.txt"), "kept\n")
    File.write!(in_root("#{@project}/onlyproj/x.txt"), "x\n")
    File.write!(in_root("#{@project}/note.txt"), "hello project\n")
    File.mkdir_p!(in_root("sub"))
    File.write!(in_root("sub/keep.txt"), "kept\n")
    project = open_project("Swap", in_root(@project))

    on_exit(fn ->
      File.rm_rf!(in_root(@project))
      File.rm_rf!(in_root("sub"))
    end)

    # EXPL-15: the open project is named, its folder is listed relative to it,
    # and a file of it is read.
    {:ok, view, _} = live(conn, ~p"/files")
    assert has_element?(view, "#project-name", "Swap")
    refute has_element?(view, "#project-picker")
    assert has_element?(view, "[data-entry='sub']")
    assert has_element?(view, "[data-entry='note.txt']")
    refute has_element?(view, "[data-entry='#{@dir}']")

    view |> element("[data-entry='note.txt']") |> render_click()
    assert_patch(view, "/files?path=note.txt")
    assert has_element?(view, "#file-path", "note.txt")
    assert has_element?(view, "#file-content", "hello project")

    # EXPL-29: switching keeps the path in view when the new project has it.
    view |> element("[data-entry='sub']") |> render_click()
    assert_patch(view, "/files?path=sub")

    switch_project(view, "harness")
    assert_patch(view, "/files?path=sub")
    assert has_element?(view, "#project-name", "Elia")
    assert has_element?(view, "[data-entry='sub/keep.txt']")

    switch_project(view, project.id)
    assert_patch(view, "/files?path=sub")

    # And falls back to the new project's root when it does not (EXPL-9).
    view |> element("#parent-dir") |> render_click()
    view |> element("[data-entry='onlyproj']") |> render_click()
    assert_patch(view, "/files?path=onlyproj")

    switch_project(view, "harness")
    assert_patch(view, "/files")
    assert has_element?(view, "[data-entry='#{@dir}']")
  end

  # EXPL-15: an older URL's `project` parameter is ignored — the page browses
  # the open project whatever the URL says.
  test "an old project parameter is ignored", %{conn: conn} do
    File.mkdir_p!(in_root(@project))
    File.write!(in_root("#{@project}/note.txt"), "hello project\n")
    project = open_project("Swap", in_root(@project))
    on_exit(fn -> File.rm_rf!(in_root(@project)) end)

    for url <- [
          ~p"/files",
          ~p"/files?#{%{project: project.id}}",
          ~p"/files?#{%{project: "nope"}}"
        ] do
      {:ok, view, _} = live(conn, url)
      assert has_element?(view, "#project-name", "Swap")
      assert has_element?(view, "[data-entry='note.txt']")
    end
  end

  # EXPL-17, EXPL-18: a chat in view browses that chat's own workspace, which is
  # where a file the agent mentions in it is opened (FLINK-5), and the page says
  # so; switching in the header leaves the chat behind (EXPL-29).
  test "browses the chat in view's own workspace", %{conn: conn} do
    folder = in_root("#{@project}/project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "mine.txt"), "the chat's own\n")
    {:ok, project} = Projects.create("A chat's project", folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "Where the file is")
    on_exit(fn -> Elia.Store.delete(chat) end)

    open = open_project("Another", in_root(@project))

    # EXPL-17: the chat's workspace wins over the open project, and the page
    # says whose workspace it is.
    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat}}")
    assert has_element?(view, "#project-name", "A chat's project")
    assert has_element?(view, "#workspace-note", "Where the file is")
    assert has_element?(view, "[data-entry='mine.txt']")
    assert has_element?(view, "#workspace-note[title='#{folder}']")

    view |> element("[data-entry='mine.txt']") |> render_click()
    assert_patch(view, "/files?chat=#{chat}&path=mine.txt")
    assert has_element?(view, "#file-content", "the chat's own")

    # EXPL-29: the switcher opens its project and leaves the chat behind.
    switch_project(view, "harness")
    assert_patch(view, "/files")
    refute has_element?(view, "#workspace-note")
    assert has_element?(view, "#project-name", "Elia")
    assert has_element?(view, "[data-entry='#{@dir}']")

    switch_project(view, open.id)
    assert has_element?(view, "#project-name", "Another")
  end

  # EXPL-17: a chat that isn't a saved one is ignored, and the project decides.
  test "an unknown chat browses the project", %{conn: conn} do
    for url <- [~p"/files?#{%{chat: "nosuchchat12"}}", ~p"/files?#{%{chat: "not an id"}}"] do
      {:ok, view, _} = live(conn, url)
      assert has_element?(view, "[data-entry='#{@dir}']")
      refute has_element?(view, "#workspace-note")
    end
  end

  # EXPL-19, EXPL-29: a project whose folder is gone shows its own message — in
  # place of EXPL-9's path message — and the header's switcher is the way out.
  test "a project folder that is gone shows a message the switcher can leave", %{conn: conn} do
    folder = in_root("#{@project}_gone")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("Gone", folder)
    File.rm_rf!(folder)
    :ok = Projects.set_default(project.id)

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files")

    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#project-name", "Gone")
    refute has_element?(view, "#project-picker")
    refute has_element?(view, "#file-error")
    refute has_element?(view, "[data-entry]")
    refute render(view) =~ "Empty directory"

    switch_project(view, "harness")
    assert_patch(view, "/files")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "[data-entry='#{@dir}']")
  end

  # EXPL-21: a project whose folder is a link that leads nowhere reports its
  # root the way any other root that can't be listed does.
  test "a project whose folder is a broken symlink shows the root message", %{conn: conn} do
    base = in_root("#{@project}_broken")
    File.rm_rf!(base)
    File.mkdir_p!(Path.join(base, "real"))
    File.ln_s!("real", Path.join(base, "link"))
    folder = Path.join(base, "link")
    {:ok, project} = Projects.create("Broken link", folder)
    File.rm_rf!(Path.join(base, "real"))
    :ok = Projects.set_default(project.id)

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      File.rm_rf!(base)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files")
    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#project-name", "Broken link")
    refute has_element?(view, "#project-picker")
    refute has_element?(view, "#file-error")
    refute has_element?(view, "[data-entry]")
  end

  # EXPL-19: a root that is not a directory says so rather than crashing.
  test "a project folder that isn't a directory shows a message", %{conn: conn} do
    folder = in_root("#{@project}_file")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("A file", folder)
    File.rm_rf!(folder)
    File.write!(folder, "not a folder")
    :ok = Projects.set_default(project.id)

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files")
    assert has_element?(view, "#root-error", folder)
    refute has_element?(view, "#project-picker")
  end

  # EXPL-19, EXPL-17: a chat whose project's folder is gone reports it the same
  # way, naming the workspace it browsed.
  test "a chat whose project folder is gone shows the message too", %{conn: conn} do
    folder = in_root("#{@project}_chat")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("Gone chat", folder)
    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "No folder")
    File.rm_rf!(folder)

    on_exit(fn ->
      Elia.Store.delete(chat)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat}}")
    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#workspace-note", "No folder")
    assert has_element?(view, "#project-name", "Gone chat")
  end

  # EXPL-20: a project whose folder is itself a symlink to a directory is
  # browsed like any other, rather than reported as an unreadable root.
  test "a project whose folder is a symlink is browsed", %{conn: conn} do
    base = in_root("#{@project}_symlink")
    File.rm_rf!(base)
    File.mkdir_p!(Path.join(base, "real/inner"))
    File.write!(Path.join(base, "real/note.txt"), "through the link\n")
    File.write!(Path.join(base, "real/inner/deep.txt"), "deep")
    File.ln_s!("real", Path.join(base, "link"))
    {:ok, project} = Projects.create("Linked", Path.join(base, "link"))
    :ok = Projects.set_default(project.id)

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      File.rm_rf!(base)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "#project-name", "Linked")
    assert has_element?(view, "[data-entry='inner']")
    assert has_element?(view, "[data-entry='note.txt']")
    refute render(view) =~ "Empty directory"

    view |> element("[data-entry='note.txt']") |> render_click()
    assert_patch(view, "/files?path=note.txt")
    assert has_element?(view, "#file-content", "through the link")

    view |> element("[data-entry='inner']") |> render_click()
    assert_patch(view, "/files?path=inner")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "[data-entry='inner/deep.txt']")
  end

  # EXPL-23, EXPL-26: a picture is a picture, not its bytes shown as text, and
  # its header links to the file's own URL.
  test "previews an image instead of showing its text", %{conn: conn} do
    File.write!(in_root("#{@dir}/shot.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/shot.png"]}")

    url = ~p"/files/raw?#{%{path: "#{@dir}/shot.png"}}"

    assert has_element?(view, "img#file-preview[src='#{url}']")
    assert has_element?(view, "#file-preview-open[href='#{url}'][target=_blank]")
    assert has_element?(view, "#file-path", "#{@dir}/shot.png")
    assert has_element?(view, "#file-header", "8 B")
    refute has_element?(view, "#file-content")
    refute has_element?(view, "#file-gutter")
    refute has_element?(view, "#file-binary")
    # EXPL-23: no line count for a picture.
    refute has_element?(view, "#file-header", "line")
    # EXPL-30, EXPL-33: a picture opens in the raw mode, with the control that
    # offers its source beside it.
    assert has_element?(view, "#mode-raw[aria-current=true]")
    assert has_element?(view, "#mode-source")
  end

  # EXPL-30, EXPL-32, EXPL-33: a page is a page — the browser renders the file's
  # own bytes in the frame rather than its markup as text — and the header's
  # control shows the source instead. A file the browser doesn't render of itself
  # opens as its source (EXPL-30), so this is the mode asked for.
  test "renders an HTML file raw, and shows its source on request", %{conn: conn} do
    File.write!(in_root("#{@dir}/page.html"), "<h1>hello</h1>\n")

    {:ok, view, _} = live(conn, mode_url("#{@dir}/page.html", "raw"))

    url = ~p"/files/raw?#{%{path: "#{@dir}/page.html"}}"

    assert has_element?(view, "iframe#file-raw[src='#{url}'][sandbox]")
    assert has_element?(view, "#file-preview-open[href='#{url}'][target=_blank]")
    assert has_element?(view, "#file-path", "#{@dir}/page.html")
    # EXPL-26: the header still names the file's size.
    assert has_element?(view, "#file-header", "15 B")
    # EXPL-32: none of the text view's parts are there, and no line count.
    refute has_element?(view, "#file-content")
    refute has_element?(view, "#file-gutter")
    refute has_element?(view, "#file-header", "line")
    refute has_element?(view, "#file-binary")
    assert has_element?(view, "#mode-raw[aria-current=true]")

    # EXPL-30: the source mode reads the file as text instead, with the size and
    # the line count EXPL-8 gives it.
    view |> element("#mode-source") |> render_click()
    assert_patch(view, mode_url("#{@dir}/page.html", "source"))
    assert has_element?(view, "#file-content", "<h1>hello</h1>")
    assert has_element?(view, "#file-header", "1 line")
    assert has_element?(view, "#mode-source[aria-current=true]")
    refute has_element?(view, "#file-raw")

    view |> element("#mode-raw") |> render_click()
    assert_patch(view, mode_url("#{@dir}/page.html", "raw"))
    assert has_element?(view, "iframe#file-raw")
    refute has_element?(view, "#file-content")
  end

  # SERVE-15, SERVE-16: with a preview host configured, an HTML document in a
  # project's `dist` folder opens at its URL on that host — the only URL a
  # browser runs it at, since the raw view has its scripts off (EXPL-24).
  # Without one it stays the raw view's URL, which is what the test above
  # asserts. The preview's path is the slug and then the document's path in
  # `dist`, so the folder itself is not in the URL.
  test "an HTML document in dist opens at the preview host's URL when there is one", %{
    conn: conn
  } do
    File.mkdir_p!(in_root("#{@dir}/dist"))
    File.write!(in_root("#{@dir}/dist/page.html"), "<h1>hello</h1>\n")
    _project = open_project("files live preview", in_root(@dir))

    Application.put_env(:elia, EliaWeb.PreviewHost, host: "preview.localhost:7000")
    on_exit(fn -> Application.delete_env(:elia, EliaWeb.PreviewHost) end)

    # The project's folder is the fixture directory, so the path in view is the
    # file's path in it (EXPL-1, EXPL-15).
    {:ok, view, _} = live(conn, path_url("dist/page.html"))

    url = "http://preview.localhost:7000/files-live-preview/page.html"

    assert has_element?(view, "#file-preview-open[href='#{url}'][target=_blank]")
    # The page itself is still the raw view's, which the frame draws.
    refute has_element?(view, "iframe#file-raw[src='#{url}']")
  end

  # SERVE-15: an HTML document beside the build, in the project's folder but
  # not in its `dist` folder, has no URL on the preview host — it is not served
  # there (SERVE-16) — so the control stays the raw view's.
  test "an HTML document outside dist opens at the raw view's URL", %{conn: conn} do
    File.write!(in_root("#{@dir}/page.html"), "<h1>hello</h1>\n")
    _project = open_project("files live preview", in_root(@dir))

    Application.put_env(:elia, EliaWeb.PreviewHost, host: "preview.localhost:7000")
    on_exit(fn -> Application.delete_env(:elia, EliaWeb.PreviewHost) end)

    {:ok, view, _} = live(conn, path_url("page.html"))

    url = ~p"/files/raw?#{%{path: "page.html"}}"

    assert has_element?(view, "#file-preview-open[href='#{url}'][target=_blank]")
  end

  # SERVE-15: a chat's own workspace has no preview URL — a preview serves a
  # project, not a chat's worktree — so the control stays the raw view's.
  test "a chat's own workspace opens at the raw view's URL with a preview host", %{conn: conn} do
    folder = in_root("#{@project}/preview_url")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "page.html"), "<h1>hi</h1>")
    {:ok, project} = Projects.create("Preview url", folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "The page")
    on_exit(fn -> Elia.Store.delete(chat) end)

    Application.put_env(:elia, EliaWeb.PreviewHost, host: "preview.localhost:7000")
    on_exit(fn -> Application.delete_env(:elia, EliaWeb.PreviewHost) end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat, path: "page.html"}}")

    url = ~p"/files/raw?#{%{path: "page.html", chat: chat}}"

    assert has_element?(view, "#file-preview-open[href='#{url}'][target=_blank]")
  end

  # EXPL-30: a `mode` that is missing, that names neither of the two, or that
  # asks for a raw view a file has none of (EXPL-31) is the file's default mode.
  test "a mode a file can't be shown in is its default mode", %{conn: conn} do
    File.write!(in_root("#{@dir}/note.txt"), "hello\n")

    # A text file's default is its source, which is what each of these asks for.
    for mode <- ["", "nonsense", "Raw", "1", "sources"] do
      {:ok, view, _} = live(conn, mode_url("#{@dir}/note.txt", mode))
      assert has_element?(view, "#file-content", "hello"), mode
      refute has_element?(view, "#file-raw"), mode
      # EXPL-33: a text file has a raw view, so the control is there too.
      assert has_element?(view, "#mode-source[aria-current=true]"), mode
      assert has_element?(view, "#mode-raw"), mode
    end

    # A binary file has none (EXPL-31), so `raw` is EXPL-8's notice instead, and
    # there is no control to switch modes with.
    {:ok, view, _} = live(conn, mode_url("#{@dir}/blob.bin", "raw"))
    assert has_element?(view, "#file-binary")
    refute has_element?(view, "#file-raw")
    refute has_element?(view, "#file-modes")
    refute has_element?(view, "#file-preview-open")
  end

  # EXPL-8, EXPL-30: a picture's source is binary, so that is what the source
  # mode says — the raw mode is the default, and this one has to be asked for.
  test "the source mode of a picture is the binary notice", %{conn: conn} do
    File.write!(in_root("#{@dir}/shot2.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)

    {:ok, view, _} = live(conn, mode_url("#{@dir}/shot2.png", "source"))

    assert has_element?(view, "#file-binary")
    refute has_element?(view, "#file-preview")
    assert has_element?(view, "#mode-source[aria-current=true]")
    assert has_element?(view, "#file-preview-open")
  end

  # EXPL-22, EXPL-23: every kind the browser renders itself gets its own element.
  test "previews a PDF, a video and an audio file", %{conn: conn} do
    for {file, element} <- [
          {"paper.pdf", "iframe#file-preview"},
          {"clip.mp4", "video#file-preview[controls]"},
          {"voice.mp3", "audio#file-preview[controls]"}
        ] do
      File.write!(in_root("#{@dir}/#{file}"), "not really what it says")

      {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/#{file}"]}")

      url = ~p"/files/raw?#{%{path: "#{@dir}/#{file}"}}"

      assert has_element?(view, element <> "[src='#{url}']"), file
      refute has_element?(view, "#file-content"), file
    end
  end

  # EXPL-23, EXPL-30: an SVG is a picture in the raw mode it opens in, rather
  # than the markup the source mode shows (EXPL-11 reads it as XML).
  test "previews an SVG rather than its markup", %{conn: conn} do
    File.write!(in_root("#{@dir}/logo.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))

    {:ok, view, _} = live(conn, path_url("#{@dir}/logo.svg"))

    assert has_element?(view, "img#file-preview")
    refute has_element?(view, "#file-content")

    view |> element("#mode-source") |> render_click()
    assert_patch(view, mode_url("#{@dir}/logo.svg", "source"))
    assert has_element?(view, "#file-content", "<svg xmlns=")
    refute has_element?(view, "#file-preview")
  end

  # EXPL-23: the read cap is not applied to a preview — nothing is read.
  test "previews a file far larger than the read cap", %{conn: conn} do
    File.write!(in_root("#{@dir}/big.png"), String.duplicate("x", 400_000))

    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/big.png"]}")

    assert has_element?(view, "img#file-preview")
    refute has_element?(view, "#file-truncated")
    refute has_element?(view, "#file-binary")
  end

  # EXPL-25: a previewable path the page can't show is EXPL-9's message, so the
  # page never points the browser at a URL that would be a 404.
  test "a previewable path that can't be previewed shows the path message", %{conn: conn} do
    File.ln_s!(in_root("#{@dir}/hello.ex"), in_root("#{@dir}/link.png"))

    for path <- ["#{@dir}/nope.png", "#{@dir}/link.png", ".git/objects/shot.png"] do
      {:ok, view, _} = live(conn, ~p"/files?#{[path: path]}")
      assert has_element?(view, "#file-error"), path
      refute has_element?(view, "#file-preview"), path
      refute has_element?(view, "#file-preview-open"), path
    end
  end

  # EXPL-33: switching mode keeps the workspace the page browses and the file in
  # view, so the other mode shows the same file.
  test "the mode control keeps the workspace and the file", %{conn: conn} do
    folder = in_root("#{@project}/modes")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "page.html"), "<h1>hi</h1>")
    {:ok, project} = Projects.create("Modes", folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "The page")
    on_exit(fn -> Elia.Store.delete(chat) end)

    {:ok, view, _} =
      live(conn, ~p"/files?#{%{chat: chat, path: "page.html", mode: "raw"}}")

    assert has_element?(view, "#file-raw")

    view |> element("#mode-source") |> render_click()

    assert_patch(view, ~p"/files?#{%{chat: chat, path: "page.html", mode: "source"}}")

    assert has_element?(view, "#file-content", "<h1>hi</h1>")
    assert has_element?(view, "#workspace-note")
  end

  # EXPL-15, EXPL-17, EXPL-24, EXPL-26: a preview's URL carries the workspace
  # the page browses, so the route serves that same file.
  test "a preview's URL names the project and the chat in view", %{conn: conn} do
    folder = in_root("#{@dir}/project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "logo.png"), <<137, 80, 78, 71>>)
    {:ok, project} = Projects.create("Previews", folder)
    :ok = Projects.set_default(project.id)
    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "The picture")

    on_exit(fn ->
      Elia.Settings.delete(:default_project)
      Elia.Store.delete(chat)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{path: "logo.png"}}")

    project_url = ~p"/files/raw?#{%{path: "logo.png"}}"
    assert has_element?(view, "img#file-preview[src='#{project_url}']")

    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat, path: "logo.png"}}")
    chat_url = ~p"/files/raw?#{%{chat: chat, path: "logo.png"}}"
    assert has_element?(view, "img#file-preview[src='#{chat_url}']")
    assert has_element?(view, "#file-preview-open[href='#{chat_url}']")
  end
end
