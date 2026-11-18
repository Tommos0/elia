defmodule EliaWeb.BundleRefreshTest do
  use EliaWeb.ConnCase, async: true

  alias EliaWeb.AssetVersion

  # A scratch tree of its own, so a test that writes a bundle never touches the
  # one this tree built (BUNDLE-1).
  defp tmp_dir(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp bundle(dir, css, js) do
    for {path, body} <- [{"assets/css/app.css", css}, {"assets/js/app.js", js}] do
      file = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, body)
    end

    dir
  end

  # BUNDLE-1: the version of a tree's bundle is the two entry points the
  # endpoint serves (DEPLOY-24), each read from its built file the way PWA-8
  # reads one.
  test "the version names both entry points, read from their files" do
    dir = bundle(tmp_dir("elia-bundle"), "one", "two")

    assert AssetVersion.current(dir) ==
             "css=#{AssetVersion.version_of("/assets/css/app.css", dir)};" <>
               "js=#{AssetVersion.version_of("/assets/js/app.js", dir)}"

    assert AssetVersion.current(dir) =~ ~r{^css=\d+-\d+;js=\d+-\d+$}
  end

  # BUNDLE-1: a bundle built again is another version, which is what lets a page
  # tell that the one it loaded is not the one served.
  test "a rebuilt bundle is another version" do
    dir = bundle(tmp_dir("elia-bundle-rebuilt"), "one", "two")
    first = AssetVersion.current(dir)

    bundle(dir, "one", "two!")

    refute AssetVersion.current(dir) == first
  end

  # BUNDLE-1: an asset that was never built reads as PWA-8's stable placeholder
  # rather than failing, so a page of a tree with no build still renders.
  test "a bundle that was never built is the placeholder" do
    assert AssetVersion.current(tmp_dir("elia-bundle-unbuilt")) == "css=0;js=0"
  end

  # BUNDLE-3: the endpoint answers with the version the tree serves now, as
  # plain text, and through the browser pipeline — so a client asking is never
  # answered from a cache (PWA-9).
  test "serves the tree's current version", %{conn: conn} do
    conn = get(conn, "/asset-version")

    assert response(conn, 200) == AssetVersion.current()
    assert [type] = get_resp_header(conn, "content-type")
    assert type =~ "text/plain"
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert conn.resp_body =~ ~r{^css=(\d+-\d+|0);js=(\d+-\d+|0)$}
  end

  # BUNDLE-2: a page carries the version of the bundle it loaded, in the meta
  # the client reads it from.
  test "a page carries the version it loaded", %{conn: conn} do
    html = conn |> get(~p"/settings") |> html_response(200)

    assert html =~ ~s(<meta name="elia-asset-version" content="#{AssetVersion.current()}")
  end

  # BUNDLE-2: the meta and the links a page carries name the same build, so the
  # version the page compares is the version it fetched.
  test "the version a page carries is the one its links use", %{conn: conn} do
    html = conn |> get(~p"/settings") |> html_response(200)

    assert [_, css] = Regex.run(~r{href="/assets/css/app\.css\?v=([^"]+)"}, html)
    assert [_, js] = Regex.run(~r{src="/assets/js/app\.js\?v=([^"]+)"}, html)

    assert html =~ ~s(content="css=#{css};js=#{js}")
  end
end
