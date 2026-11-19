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

  # EXPL-15, EXPL-16
  test "browses one project and switches with the picker", %{conn: conn} do
    # Both roots share the relative path "sub", so switching can keep it; the
    # project also has a path Elia's own root doesn't, to check the fallback.
    File.rm_rf!(in_root(@project))
    File.mkdir_p!(in_root("#{@project}/sub"))
    File.mkdir_p!(in_root("#{@project}/onlyproj"))
    File.write!(in_root("#{@project}/sub/keep.txt"), "kept\n")
    File.write!(in_root("#{@project}/onlyproj/x.txt"), "x\n")
    File.write!(in_root("#{@project}/note.txt"), "hello project\n")
    File.mkdir_p!(in_root("sub"))
    File.write!(in_root("sub/keep.txt"), "kept\n")
    {:ok, project} = Projects.create("Swap", in_root(@project))

    on_exit(fn ->
      File.rm_rf!(in_root(@project))
      File.rm_rf!(in_root("sub"))
      Projects.delete(project.id)
    end)

    # EXPL-15: name the project and list its folder relative to it.
    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id}}")
    assert has_element?(view, "#project-name", "Swap")
    assert has_element?(view, "#project-picker")
    assert has_element?(view, "[data-entry='sub']")
    assert has_element?(view, "[data-entry='note.txt']")
    refute has_element?(view, "[data-entry='#{@dir}']")

    # The viewer reads a file from the project.
    view |> element("[data-entry='note.txt']") |> render_click()
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "note.txt"}}")
    assert has_element?(view, "#file-path", "note.txt")
    assert has_element?(view, "#file-content", "hello project")

    # EXPL-16: switching keeps the current path when it exists in the new one.
    view |> element("[data-entry='sub']") |> render_click()
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "sub"}}")

    view |> element("form#project-switch") |> render_change(%{"project" => "harness"})
    assert_patch(view, "/files?path=sub")
    assert has_element?(view, "#project-name", "Elia")
    assert has_element?(view, "[data-entry='sub/keep.txt']")

    # Back in the project, a path that only exists there falls back to the root.
    view |> element("form#project-switch") |> render_change(%{"project" => project.id})
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "sub"}}")

    view |> element("#parent-dir") |> render_click()
    view |> element("[data-entry='onlyproj']") |> render_click()
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "onlyproj"}}")

    view |> element("form#project-switch") |> render_change(%{"project" => "harness"})
    assert_patch(view, "/files")
    assert has_element?(view, "[data-entry='#{@dir}']")
  end

  # EXPL-15
  test "an unknown or missing project browses Elia's own", %{conn: conn} do
    for url <- [~p"/files", ~p"/files?#{%{project: "nope"}}"] do
      {:ok, view, _} = live(conn, url)
      assert has_element?(view, "#project-name", "Elia")
      assert has_element?(view, "[data-entry='#{@dir}']")
    end
  end

  # EXPL-17, EXPL-18: a chat's own workspace can be browsed — its project's
  # folder, which for a chat in Elia's own project is the live tree (PROJ-12,
  # DEPLOY-1), since the harness makes no worktree for it — and the page names
  # the chat it browses.
  test "browses a chat's own workspace", %{conn: conn} do
    chat = Elia.Agent.new_id()
    File.mkdir_p!(in_root("inner"))
    File.write!(in_root("inner/only_here.ex"), "defmodule OnlyHere do\nend\n")
    :ok = Elia.Store.save(chat, [], project: "harness", title: "Where the file is")

    on_exit(fn ->
      Elia.Store.delete(chat)
      File.rm_rf!(in_root("inner"))
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat}}")
    assert has_element?(view, "#project-name", "Elia")
    assert has_element?(view, "#workspace-note", "Where the file is")

    view |> element("[data-entry='inner']") |> render_click()
    assert_patch(view, ~p"/files?#{%{chat: chat, path: "inner"}}")
    assert has_element?(view, "[data-entry='inner/only_here.ex']")

    view |> element("[data-entry='inner/only_here.ex']") |> render_click()
    assert has_element?(view, "#file-content", "defmodule OnlyHere do")

    # Back to the directory, so the picker's current path is one the project has
    # too (EXPL-16, EXPL-18): it browses that project's folder and leaves the
    # chat behind.
    view |> element("#breadcrumbs a", "inner") |> render_click()
    assert_patch(view, ~p"/files?#{%{chat: chat, path: "inner"}}")

    view |> element("form#project-switch") |> render_change(%{"project" => "harness"})
    assert_patch(view, "/files?path=inner")
    refute has_element?(view, "#workspace-note")
    assert has_element?(view, "[data-entry='inner/only_here.ex']")
  end

  # EXPL-17: a chat that isn't a saved one is ignored, and the project decides.
  test "an unknown chat browses the project", %{conn: conn} do
    for url <- [~p"/files?#{%{chat: "nosuchchat12"}}", ~p"/files?#{%{chat: "not an id"}}"] do
      {:ok, view, _} = live(conn, url)
      assert has_element?(view, "[data-entry='#{@dir}']")
      refute has_element?(view, "#workspace-note")
    end
  end

  # EXPL-19: a project whose folder is gone shows its own message — in place of
  # EXPL-9's path message — and leaves the page usable, instead of crashing on
  # the listing that couldn't be read.
  test "a project folder that is gone shows a message and keeps the picker", %{conn: conn} do
    folder = in_root("#{@project}_gone")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("Gone", folder)
    File.rm_rf!(folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id}}")

    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#project-name", "Gone")
    assert has_element?(view, "#project-picker")
    refute has_element?(view, "#file-error")
    refute has_element?(view, "[data-entry]")
    refute render(view) =~ "Empty directory"

    # The picker is the way out: a project that is there browses as usual.
    view |> element("form#project-switch") |> render_change(%{"project" => "harness"})
    assert_patch(view, "/files")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "[data-entry='#{@dir}']")
  end

  # EXPL-19: a root that is not a directory says so rather than crashing.
  test "a project folder that isn't a directory shows a message", %{conn: conn} do
    folder = in_root("#{@project}_file")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("A file", folder)
    File.rm_rf!(folder)
    File.write!(folder, "not a folder")

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id}}")
    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#project-picker")
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

  # PROJ-27: a project whose folder is gone stays in the picker and is marked,
  # so it isn't mistaken for a deleted one.
  test "the picker marks a project whose folder is gone", %{conn: conn} do
    folder = in_root("#{@project}_marked")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("Unmounted", folder)
    File.rm_rf!(folder)

    on_exit(fn ->
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files")

    assert has_element?(
             view,
             "#project-picker option[value='#{project.id}']",
             "Unmounted (unavailable)"
           )

    assert has_element?(view, "#project-picker option[value='harness']", "Elia")
    refute render(element(view, "#project-picker")) =~ "Elia (unavailable)"
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

    on_exit(fn ->
      File.rm_rf!(base)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id}}")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "#project-name", "Linked")
    assert has_element?(view, "[data-entry='inner']")
    assert has_element?(view, "[data-entry='note.txt']")
    refute render(view) =~ "Empty directory"

    view |> element("[data-entry='note.txt']") |> render_click()
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "note.txt"}}")
    assert has_element?(view, "#file-content", "through the link")

    view |> element("[data-entry='inner']") |> render_click()
    assert_patch(view, ~p"/files?#{%{project: project.id, path: "inner"}}")
    refute has_element?(view, "#root-error")
    assert has_element?(view, "[data-entry='inner/deep.txt']")
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

    on_exit(fn ->
      File.rm_rf!(base)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id}}")
    assert has_element?(view, "#root-error", folder)
    assert has_element?(view, "#project-name", "Broken link")
    assert has_element?(view, "#project-picker")
    refute has_element?(view, "#file-error")
    refute has_element?(view, "[data-entry]")
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

  # EXPL-23: an SVG is a picture here, so its source is no longer the text view.
  test "previews an SVG rather than its markup", %{conn: conn} do
    File.write!(in_root("#{@dir}/logo.svg"), ~s(<svg xmlns="http://www.w3.org/2000/svg"/>))

    {:ok, view, _} = live(conn, ~p"/files?#{[path: "#{@dir}/logo.svg"]}")

    assert has_element?(view, "img#file-preview")
    refute has_element?(view, "#file-content")
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

  # EXPL-15, EXPL-17, EXPL-24, EXPL-26: a preview's URL carries the workspace
  # the page browses, so the route serves that same file.
  test "a preview's URL names the project and the chat in view", %{conn: conn} do
    folder = in_root("#{@dir}/project")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "logo.png"), <<137, 80, 78, 71>>)
    {:ok, project} = Projects.create("Previews", folder)
    chat = Elia.Agent.new_id()
    :ok = Elia.Store.save(chat, [], project: project.id, title: "The picture")

    on_exit(fn ->
      Elia.Store.delete(chat)
      File.rm_rf!(folder)
      Projects.delete(project.id)
    end)

    {:ok, view, _} = live(conn, ~p"/files?#{%{project: project.id, path: "logo.png"}}")

    project_url = ~p"/files/raw?#{%{project: project.id, path: "logo.png"}}"
    assert has_element?(view, "img#file-preview[src='#{project_url}']")

    {:ok, view, _} = live(conn, ~p"/files?#{%{chat: chat, path: "logo.png"}}")
    chat_url = ~p"/files/raw?#{%{chat: chat, path: "logo.png"}}"
    assert has_element?(view, "img#file-preview[src='#{chat_url}']")
    assert has_element?(view, "#file-preview-open[href='#{chat_url}']")
  end
end
