defmodule EliaWeb.FilesLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Projects, Workspace}

  @dir "files_live_fixture"
  @project "files_live_swap"

  defp in_root(path), do: Path.join(Workspace.root(), path)

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
end
