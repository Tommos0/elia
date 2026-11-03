defmodule EliaWeb.PreviewTest do
  @moduledoc """
  The pictures a UI preview is made of (PREVIEW-1 - PREVIEW-6, PREVIEW-10 -
  PREVIEW-12): it drives the browser layer's real headless Chromium
  (BROWSER-1, BROWSER-2) over the pages asked for, and writes one PNG per page
  into `tmp/preview/`.

  It runs the test env server of this same node, so it shows *this workspace's*
  own compiled code, files and data with no deploy and no API key (BROWSER-3,
  BROWSER-7) — which is the whole point of a preview (PREVIEW-1, PREVIEW-2).
  `bin/preview` is how it is meant to be run; it builds the assets and the
  sample chat first.

  A preview is not a test: what a page logged in the console is reported, not
  failed on (PREVIEW-5), and the module is excluded from the default run
  (PREVIEW-6).

      bin/preview
      bin/preview / /files
      ELIA_PREVIEW_WIDTH=390 bin/preview @chat
  """

  use PhoenixTest.Playwright.Case, async: false

  alias Elia.{FakeLLM, Preview}
  alias EliaWeb.BrowserJsLogger

  @moduletag :preview

  # PREVIEW-6: what the browser loads, built by `bin/preview`. A preview must
  # say what to run rather than test an unstyled page (BROWSER-6).
  @assets ["priv/static/assets/js/app.js", "priv/static/assets/css/app.css"]

  setup_all do
    check_assets!()
    start_supervised!(BrowserJsLogger)

    # PREVIEW-3: the viewport comes from the environment, so a narrow width
    # previews the small-screen layout. This runs before the browser context is
    # created, which is where a viewport applies.
    config = Application.get_env(:phoenix_test, :playwright, [])

    Application.put_env(
      :phoenix_test,
      :playwright,
      Keyword.put(config, :browser_context_opts,
        viewport: %{
          width: env_int("ELIA_PREVIEW_WIDTH", 1280),
          height: env_int("ELIA_PREVIEW_HEIGHT", 900)
        }
      )
    )

    :ok
  end

  setup do
    start_supervised!(FakeLLM)
    BrowserJsLogger.clear()

    # PREVIEW-2: the app under preview is this workspace's own code, files and
    # data — the live tree's are never involved.
    root = File.cwd!()
    Application.put_env(:elia, :workspace, root)
    Application.put_env(:elia, :runtime_root, root)

    # PREVIEW-10: a page without content is hard to judge.
    :ok = Preview.seed()

    {:ok, root: root}
  end

  # PREVIEW-1, PREVIEW-3, PREVIEW-4, PREVIEW-5
  test "takes a picture of every page asked for", %{conn: conn, root: root} do
    dir = Preview.dir(root)
    File.mkdir_p!(dir)
    paths = preview_paths()

    taken =
      for {path, index} <- Enum.with_index(paths) do
        file = Preview.file_name(index, path)
        conn |> visit(path) |> settle() |> screenshot(file, full_page: true)

        assert File.exists?(Path.join(dir, file)),
               "no picture was written for #{path} (expected #{file} in #{dir})"

        {path, file}
      end

    report(taken, root)
  end

  # PREVIEW-3: client hooks — the websocket, the scroll hook, highlighting — run
  # after the page has loaded, so a preview waits before it looks. Nothing here
  # can signal that they are done, so this is the settle time.
  defp settle(conn) do
    Process.sleep(env_int("ELIA_PREVIEW_WAIT", 500))
    conn
  end

  # PREVIEW-11: `@chat` is the sample chat, which a preview always seeds.
  defp preview_paths do
    case System.get_env("PREVIEW_PATHS") do
      nil -> ["/", "/c/" <> Preview.sample_id()]
      paths -> paths |> String.split("\n", trim: true) |> Enum.map(&Preview.resolve_path/1)
    end
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  # PREVIEW-5: what the agent needs to show the pictures — the file, and the URL
  # the chat renders it from — then what the pages logged, reported and not
  # failed on. A preview outside a chat's worktree has no URL to offer: the
  # running app only serves a chat's own previews (PREVIEW-7).
  defp report(taken, root) do
    chat_id = Preview.worktree_chat(root)

    lines =
      Enum.map(taken, fn {path, file} ->
        link =
          if chat_id do
            "![" <> path <> "](" <> Preview.url(chat_id, file) <> ")"
          else
            "(no link: this workspace is not a chat's worktree)"
          end

        ["  #{path}", "    #{Path.join(Preview.dir(root), file)}", "    #{link}"]
      end)

    IO.puts(
      Enum.join(
        ["", "==== UI preview: #{length(taken)} picture(s) in #{root}", ""] ++
          List.flatten(lines) ++ ["", "  page errors and console errors:", errors()],
        "\n"
      )
    )
  end

  defp errors do
    case BrowserJsLogger.take() do
      [] -> "    none"
      errors -> "\n" <> Enum.map_join(errors, "\n", &"    #{&1}")
    end
  end

  defp check_assets! do
    case Enum.reject(@assets, &File.exists?/1) do
      [] ->
        :ok

      missing ->
        raise """
        A preview needs built assets, and #{Enum.join(missing, ", ")} is missing.

        Run `bin/preview`, which builds them, or `mix assets.build` yourself (PREVIEW-6).
        """
    end
  end
end
