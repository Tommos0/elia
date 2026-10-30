defmodule EliaWeb.RecoveryTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Elia.{Checkpoint, Guarded, Workspace}
  alias EliaWeb.{FakeCheckpoints, Recovery}

  defp in_root(path), do: Path.join(Workspace.root(), path)

  # Builds a request as the endpoint would see it from a local browser.
  defp request(method, path, opts \\ []) do
    conn = conn(method, path, opts[:body])
    conn = %{conn | host: opts[:host] || "localhost", remote_ip: opts[:ip] || {127, 0, 0, 1}}

    conn =
      Enum.reduce(opts[:headers] || [], conn, fn {key, value}, conn ->
        put_req_header(conn, key, value)
      end)

    Recovery.call(conn, Recovery.init(Keyword.take(opts, [:checkpoints])))
  end

  defp rollback_request(sha, opts \\ []) do
    headers = Keyword.get(opts, :headers, [{"origin", "http://localhost"}])
    request(:post, "/recover", [body: "checkpoint=#{sha}", headers: headers] ++ opts)
  end

  setup do
    File.write!(in_root("recover.txt"), "original")
    {:ok, sha} = Checkpoint.create("recovery test")
    File.write!(in_root("recover.txt"), "changed")

    on_exit(fn ->
      File.rm(in_root("recover.txt"))
      File.rm_rf!(in_root("skills/recover-skill"))
      File.rm_rf!(in_root("lib"))
      Guarded.mark_loaded()
      Elia.Skills.reload()
    end)

    %{sha: sha}
  end

  test "RECOVER-8: the plug and every Elia module it uses are guarded" do
    assert Guarded.guarded?("lib/elia_web/recovery.ex")

    modules =
      "lib/elia_web/recovery.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/\bElia(?:\.[A-Z]\w*)+/, &1))
      |> List.flatten()
      |> Enum.uniq()

    assert "Elia.Checkpoint" in modules

    for module <- modules do
      path = "lib/" <> Macro.underscore(module) <> ".ex"
      assert Guarded.guarded?(path), "#{module} (#{path}) is not guarded"
    end
  end

  test "RECOVER-1: the endpoint serves recovery before the reloaders" do
    source = File.read!("lib/elia_web/endpoint.ex")
    position = fn needle -> :binary.match(source, needle) |> elem(0) end

    assert position.("plug EliaWeb.Recovery") < position.("plug Phoenix.LiveReloader")
    assert position.("plug EliaWeb.Recovery") < position.("plug Phoenix.CodeReloader")
  end

  describe "RECOVER-2: local requests only" do
    test "serves loopback requests", %{sha: _} do
      assert request(:get, "/recover").status == 200
      assert request(:get, "/recover", ip: {0, 0, 0, 0, 0, 0, 0, 1}, host: "::1").status == 200
      assert request(:get, "/recover", ip: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}).status == 200
      assert request(:get, "/recover", host: "127.0.0.1").status == 200
    end

    test "refuses remote peers, foreign hosts and forwarded requests", %{sha: sha} do
      refused = [
        request(:get, "/recover", ip: {10, 0, 0, 5}),
        request(:get, "/recover", host: "example.com"),
        request(:get, "/recover", headers: [{"x-forwarded-for", "203.0.113.9"}]),
        request(:get, "/recover", headers: [{"cf-connecting-ip", "203.0.113.9"}]),
        rollback_request(sha, ip: {10, 0, 0, 5}),
        rollback_request(sha, host: "example.com", headers: [{"origin", "http://example.com"}])
      ]

      for conn <- refused, do: assert(conn.status == 403)
      assert File.read!(in_root("recover.txt")) == "changed"
    end
  end

  describe "RECOVER-3: checkpoint list" do
    test "shows the newest agent-turn checkpoint first, as recommended" do
      turn = "recover-#{System.unique_integer([:positive])}"
      :ok = Checkpoint.ensure(turn)
      {:ok, _} = Checkpoint.create("a manual checkpoint")

      conn = request(:get, "/recover")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"

      body = conn.resp_body
      turn_row = :binary.match(body, "before agent turn #{turn}") |> elem(0)
      manual_row = :binary.match(body, "a manual checkpoint") |> elem(0)
      recommended = :binary.match(body, "(recommended)") |> elem(0)

      assert turn_row < manual_row
      assert recommended > turn_row and recommended < manual_row
      assert body =~ ~s(action="/recover")
    end

    test "other methods are not allowed" do
      conn = request(:put, "/recover")
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST"]
    end

    test "CKPT-6: checkpoints are listed newest first" do
      {:ok, first} = Checkpoint.create("order one")
      {:ok, second} = Checkpoint.create("order two")
      shas = Enum.map(Checkpoint.list(), & &1.sha)

      assert Enum.find_index(shas, &(&1 == second)) < Enum.find_index(shas, &(&1 == first))
    end
  end

  describe "RECOVER-4: rolling back" do
    test "restores the checkpoint's files", %{sha: sha} do
      assert rollback_request(sha).status == 200
      assert File.read!(in_root("recover.txt")) == "original"
    end

    test "needs a same-origin Origin header", %{sha: sha} do
      refused = [
        rollback_request(sha, headers: []),
        rollback_request(sha, headers: [{"origin", "http://evil.example"}]),
        rollback_request(sha, headers: [{"origin", "http://localhost:9999"}]),
        rollback_request(sha, headers: [{"origin", "https://localhost"}]),
        rollback_request(sha, headers: [{"origin", "null"}])
      ]

      for conn <- refused, do: assert(conn.status == 403)
      assert File.read!(in_root("recover.txt")) == "changed"
    end

    test "only accepts recent checkpoints", %{sha: _} do
      unknown = String.duplicate("a", 40)

      assert rollback_request(unknown).status == 400
      assert rollback_request("--help").status == 400

      missing =
        request(:post, "/recover", body: "other=1", headers: [{"origin", "http://localhost"}])

      assert missing.status == 400
      assert File.read!(in_root("recover.txt")) == "changed"
    end
  end

  describe "RECOVER-5: after a rollback" do
    test "offers an undo and reloads skills", %{sha: sha} do
      File.mkdir_p!(in_root("skills/recover-skill"))

      File.write!(
        in_root("skills/recover-skill/SKILL.md"),
        "---\nname: recover-skill\ndescription: temporary\n---\nBody"
      )

      assert Enum.any?(Elia.Skills.reload().skills, &(&1.name == "recover-skill"))

      conn = rollback_request(sha)
      assert conn.status == 200
      refute Enum.any?(Elia.Skills.current(), &(&1.name == "recover-skill"))
      assert conn.resp_body =~ ~s(href="/")

      [_, undo] = Regex.run(~r/name="checkpoint" value="([0-9a-f]+)"/, conn.resp_body)
      assert File.read!(in_root("recover.txt")) == "original"

      assert rollback_request(undo).status == 200
      assert File.read!(in_root("recover.txt")) == "changed"
      assert Enum.any?(Elia.Skills.current(), &(&1.name == "recover-skill"))
    end

    test "lists guarded files whose changes are still unloaded" do
      File.mkdir_p!(in_root("lib/elia"))
      File.write!(in_root("lib/elia/harness.ex"), "v0")
      Guarded.mark_loaded()
      File.write!(in_root("lib/elia/harness.ex"), "v1")
      {:ok, sha} = Checkpoint.create("guarded change")
      File.write!(in_root("lib/elia/harness.ex"), "v2")

      conn = rollback_request(sha)
      assert conn.status == 200
      assert conn.resp_body =~ "lib/elia/harness.ex"
      assert conn.resp_body =~ "still paused"

      File.write!(in_root("lib/elia/harness.ex"), "v0")
      {:ok, clean} = Checkpoint.create("loaded state")
      File.write!(in_root("lib/elia/harness.ex"), "v2")

      conn = rollback_request(clean)
      assert conn.resp_body =~ "resumes on the next request"
      refute conn.resp_body =~ "still paused"
    end
  end

  test "RECOVER-6: a failed rollback shows the escaped error" do
    Process.put(:fake_checkpoints_list, [%{sha: "abc123", at: "now", label: "x"}])
    conn = rollback_request("abc123", checkpoints: FakeCheckpoints)

    assert conn.status == 500
    assert conn.resp_body =~ "boom &lt;b&gt;"
    assert File.read!(in_root("recover.txt")) == "changed"
  end

  describe "RECOVER-7: banner on crash pages" do
    @crash "<html><body class=\"x\"><h1>Boom</h1></body></html>"

    defp crash(opts \\ [], status \\ 500, type \\ "text/html") do
      conn = request(:get, "/anything", opts)
      conn = conn |> put_resp_content_type(type) |> send_resp(status, @crash)
      {_status, _headers, body} = sent_resp(conn)
      body
    end

    setup do
      :ok = Checkpoint.ensure("banner-#{System.unique_integer([:positive])}")
    end

    test "adds a banner with a recovery link and a rollback button" do
      body = crash()

      assert body =~ ~s(id="elia-recovery-banner")
      assert body =~ ~s(href="/recover")
      assert body =~ "Roll back to the checkpoint before the last agent turn"

      body_tag = :binary.match(body, ~s(<body class="x">)) |> elem(0)
      banner = :binary.match(body, "elia-recovery-banner") |> elem(0)
      heading = :binary.match(body, "<h1>Boom</h1>") |> elem(0)
      assert body_tag < banner and banner < heading
    end

    test "leaves other responses unchanged" do
      assert crash([], 200) == @crash
      assert crash([], 404) == @crash
      assert crash([], 500, "application/json") == @crash
      assert crash(ip: {10, 0, 0, 5}) == @crash
      assert crash(host: "example.com") == @crash
    end

    test "leaves compressed or body-less pages unchanged" do
      conn = request(:get, "/anything")

      conn =
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("content-encoding", "gzip")
        |> send_resp(500, @crash)

      assert {500, _, @crash} = sent_resp(conn)

      conn =
        request(:get, "/anything")
        |> put_resp_content_type("text/html")
        |> send_resp(500, "plain fragment")

      assert {500, _, "plain fragment"} = sent_resp(conn)
    end

    test "never changes the response when the banner can't be built" do
      conn = request(:get, "/anything", checkpoints: FakeCheckpoints)
      conn = conn |> put_resp_content_type("text/html") |> send_resp(500, @crash)

      assert {500, _, @crash} = sent_resp(conn)
    end

    test "appears on the debugger page for an error raised in the router" do
      conn = %{conn(:get, "/x") | host: "localhost", remote_ip: {127, 0, 0, 1}}
      conn = put_req_header(conn, "accept", "text/html")

      assert_raise RuntimeError, "kaboom", fn -> EliaWeb.CrashingPipeline.call(conn, []) end
      assert_received {_ref, {500, _headers, body}}

      assert body =~ "RuntimeError at GET /x"
      assert body =~ ~s(id="elia-recovery-banner")
    end
  end
end
