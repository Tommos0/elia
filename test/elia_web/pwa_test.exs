defmodule EliaWeb.PwaTest do
  use EliaWeb.ConnCase, async: true

  defp manifest(conn) do
    conn = get(conn, "/manifest.webmanifest")
    assert response(conn, 200)
    JSON.decode!(conn.resp_body)
  end

  # A scratch tree of its own, so a test that writes an asset never touches the
  # one this tree built (PWA-8).
  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
  end

  # PWA-1
  test "serves the manifest", %{conn: conn} do
    conn = get(conn, "/manifest.webmanifest")
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "json"

    manifest = JSON.decode!(conn.resp_body)
    assert manifest["name"] == "Elia"
    assert manifest["start_url"] == "/"
    assert manifest["scope"] == "/"
    assert manifest["display"] == "standalone"
    assert is_binary(manifest["background_color"])
    assert is_binary(manifest["theme_color"])
  end

  # PWA-2
  test "manifest lists 192 and 512 icons for any and maskable, all served", %{conn: conn} do
    icons = manifest(conn)["icons"]

    for size <- ["192x192", "512x512"], purpose <- ["any", "maskable"] do
      assert Enum.any?(icons, &(&1["sizes"] == size and &1["purpose"] == purpose)),
             "missing #{size} #{purpose}"
    end

    for %{"src" => src, "sizes" => sizes} <- icons do
      conn = get(conn, src)
      assert <<137, "PNG", _::binary>> = response(conn, 200)
      [w, _h] = sizes |> String.split("x") |> Enum.map(&String.to_integer/1)
      assert <<_::binary-size(16), ^w::32, ^w::32, _::binary>> = conn.resp_body
    end
  end

  # PWA-3
  test "root layout links the manifest, theme color and apple touch icon", %{conn: conn} do
    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ ~s(rel="manifest" href="/manifest.webmanifest" crossorigin="use-credentials")
    assert html =~ ~s(name="theme-color")
    assert html =~ ~s(rel="apple-touch-icon" href="/images/apple-touch-icon.png")

    conn = get(conn, "/images/apple-touch-icon.png")
    assert <<_::binary-size(16), 180::32, 180::32, _::binary>> = response(conn, 200)
  end

  # PWA-4
  test "serves the service worker from the root", %{conn: conn} do
    js = conn |> get("/sw.js") |> response(200)

    assert js =~ "skipWaiting"
    assert js =~ "clients.claim"
    assert js =~ ~s("fetch")
    refute js =~ "respondWith"
    refute js =~ "caches."
  end

  # PWA-7: the page is resized by a phone's on-screen keyboard rather than the
  # keyboard covering the bottom of the page, where a chat's composer is (UI-78).
  test "the viewport meta asks the keyboard to resize the page", %{conn: conn} do
    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ ~s(name="viewport")

    assert html =~
             ~s(content="width=device-width, initial-scale=1, interactive-widget=resizes-content"),
           "the viewport meta does not resize the page for the on-screen keyboard"
  end

  # PWA-8: a page that loads again on a new build asks for the bundle under a
  # URL it has never fetched, so the browser's cache cannot answer with the one
  # it holds.
  test "the shell's asset links carry a version of the built file", %{conn: conn} do
    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ ~r/href="\/assets\/css\/app\.css\?v=[^"]+"/
    assert html =~ ~r/src="\/assets\/js\/app\.js\?v=[^"]+"/
  end

  # PWA-8: the version is the file's own, so a rebuild is a URL the browser has
  # never fetched.
  test "an asset's version follows its file" do
    dir = tmp_dir("elia-asset-version")
    on_exit(fn -> File.rm_rf!(dir) end)

    file = Path.join(dir, "assets/js/app.js")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "one")
    first = EliaWeb.AssetVersion.versioned("/assets/js/app.js", dir)

    File.write!(file, "two!")
    second = EliaWeb.AssetVersion.versioned("/assets/js/app.js", dir)

    assert first =~ ~r{^/assets/js/app\.js\?v=\d+-\d+$}
    assert first != second
  end

  # PWA-8: an asset that was never built still renders, under one stable
  # placeholder rather than an error or a version that changes per render.
  test "an asset that was not built has a stable version" do
    dir = tmp_dir("elia-asset-unbuilt")
    on_exit(fn -> File.rm_rf!(dir) end)

    assert EliaWeb.AssetVersion.versioned("/assets/js/app.js", dir) ==
             "/assets/js/app.js?v=0"
  end

  # PWA-6
  test "icon generator exists", _ do
    assert File.exists?("assets/pwa_icons.exs")
  end
end
