defmodule EliaWeb.PwaTest do
  use EliaWeb.ConnCase, async: true

  defp manifest(conn) do
    conn = get(conn, "/manifest.webmanifest")
    assert response(conn, 200)
    JSON.decode!(conn.resp_body)
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

    assert html =~ ~s(rel="manifest" href="/manifest.webmanifest")
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
    assert js =~ "fetch(event.request)"
    refute js =~ "caches."
  end

  # PWA-6
  test "icon generator exists", _ do
    assert File.exists?("assets/pwa_icons.exs")
  end
end
