# Testing

Read this before writing or changing tests. Tests live in `test/elia/` (core) and `test/elia_web/` (web, LiveViews in `test/elia_web/live/`, real-browser tests in `test/elia_web/browser/`). Helpers are in `test/support/` (`conn_case.ex`, `llm_case.ex`, `fake_llm.ex`, `live_tree.ex`, `browser_case.ex`, `browser_js_logger.ex`).

## Specs

- Every requirement you add or change needs a test. Cite its ID in the test name or a comment, e.g. `# SHELL-3`.
- If code and spec disagree, one is a bug. Fix the code or update the spec deliberately. See `specs/README.md`.
- Worktree and deploy tests use a throwaway live tree (`Elia.LiveTree.create/0`, `test/support/live_tree.ex`), never the server's own tree.
- A test that deploys by hot reload replaces the loader — `config :elia, Elia.Deploy, load: fun` — instead of calling `Phoenix.CodeReloader.reload/1`: a real recompile inside a test run rebuilds Elia's own endpoint and leaves `_build/test` broken for every later test.

## Processes

- **Always** start processes with `start_supervised!/1`.
- **Avoid** `Process.sleep/1` and `Process.alive?/1`.
  - To wait for a process to end, monitor it and assert on the DOWN message:

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - To synchronize before the next call, use `_ = :sys.get_state(pid)`.
- Use `Elia.FakeLLM` (`test/support/fake_llm.ex`) rather than real model calls.

## LiveView tests

- Use `Phoenix.LiveViewTest` and `LazyHTML`.
- Drive forms with `render_submit/2` and `render_change/2`.
- **Always** reference the DOM IDs you added to templates, via `element/2` and `has_element?/2`: `assert has_element?(view, "#my-form")`.
- **Never** assert against raw HTML. Prefer testing for key elements over text content, which changes.
- Test outcomes, not implementation details. Start with simple "content exists" tests, then add interactions, in small isolated files.
- `<.form>` and other components can render different HTML than you expect, so test against the actual output.
- To debug a selector, narrow the output with `LazyHTML`:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      IO.inspect(LazyHTML.filter(document, "your-selector"), label: "Matches")

## Real-browser tests

`Phoenix.LiveViewTest` sees the server's HTML, not a browser: JavaScript hooks,
the websocket connecting, computed styles, geometry and focus are invisible to
it. `test/elia_web/browser/` (BROWSER, `use EliaWeb.BrowserCase`) covers those
with a real headless Chromium, driven from Elixir by `PhoenixTest` and
Playwright.

- They speak HTTP to the **test env server**, which is the same BEAM node, so
  `Elia.FakeLLM` and the scratch workspace still apply: no deploy, no dev
  server, no API keys. They see the worktree's own code.
- They are excluded from a plain `mix test`, so `run_tests` and `mix precommit`
  stay fast and need no Node. Run them explicitly:

      mix assets.build                                 # esbuild/tailwind run in dev only
      ELIA_BROWSER_TESTS=1 mix test --only real_browser

- `assets/node_modules` is gitignored, so a fresh worktree has none: install it
  once with `npm install` in `assets/` for the packages the bundle imports
  (`@xterm/*`). The Playwright CLI is not one of them — it is user-wide, not a
  workspace dependency: install it once for the user with `npm install -g
  --prefix ~/.local playwright@1.64.1`, which puts the CLI in
  `~/.local/lib/node_modules/playwright` and `playwright` on your `PATH` (so
  any project on the machine can drive it). `config/config.exs` names that
  directory once (`:elia, :playwright_dir`), the test helper points the driver
  at it, and the jail binds it read-only, so a jailed browser run reaches it
  too (ISOL-26). The version is pinned to one whose Chromium revision is
  already in `~/.cache/ms-playwright`, so `playwright install chromium` reuses
  the cached browser and nothing large downloads; it needs Node ≥ 20. A browser
  run that finds the user-wide CLI missing says exactly that instead of failing
  inside the driver (BROWSER-10), and `bin/preview` installs the workspace's own
  packages for you (PREVIEW-14).
- Console errors and page errors fail the test that caused them
  (`EliaWeb.BrowserJsLogger`), so a broken hook doesn't pass quietly. Lower
  levels are logged as usual.
- Keep them few and shallow: a browser run is seconds per test. Test outcomes
  in the LiveView suite where you can, and reach for a browser only for what
  JavaScript and layout do (e.g. `#chat-input`'s Enter-to-send hook).

### UI previews

`bin/preview` (`specs/ui-preview.md`, PREVIEW) points the same browser at pages
instead of assertions: it boots the workspace's own code as the test env app,
screenshots the pages you ask for into the gitignored `tmp/preview/`, and prints
a Markdown image link per picture, which the chat renders at
`/preview/<chat id>/<file>` (`EliaWeb.PreviewController`). It is how a UI change
is shown before it is deployed. `test/elia_web/browser/preview_test.exs` is the
run itself, tagged `:preview` and excluded like these tests, so it never starts
a browser during `mix test`.

## Running

- One file: `mix test test/path_test.exs` (or `run_tests`). Previously failed: `mix test --failed`.
- The whole suite: `bin/test` — the same tests as `mix test`, but as concurrent
  partitions (`specs/test-suite.md`, SUITE). Each partition gets its own scratch
  workspace, settings database and port (`ELIA_TEST_WORKSPACE`,
  `ELIA_TEST_SETTINGS`, `ELIA_TEST_PORT`, SUITE-1), so the wall time is the
  slowest partition instead of the sum. `bin/test --plan` prints the split
  without running anything, and `bin/test test/foo_test.exs` (or `--failed`, or
  `--only`) falls back to one plain `mix test` (SUITE-6).
- The split is by file, weighted by how slow each one measured: the deploy tests
  and the restart tests each lead their own partition. A new file needs no entry
  — it weighs 1 and lands on the lightest partition (SUITE-3). The weights are
  a comment away in `bin/test`; re-measure with `mix test --slowest 20` when a
  partition feels lopsided.
- Before finishing: `mix precommit`, which runs its test step through `bin/test`
  (SUITE-8).
- A suite run through the `shell` tool needs a longer timeout than the shell's
  default: `timeout_seconds` is 300s unless the call asks for more, and never more
  than 1800s (SHELL-10), while `mix precommit` compiles, formats and runs four
  partitions. A `run_tests` run has its own timeouts: a per-test one handed to
  `mix test` as `--timeout`, and the run's own, 600s by default
  (`config :elia, Elia.Harness`, VERIFY-8, VERIFY-9). A chat's first run in a
  fresh worktree compiles deps and app before its first test, so give it
  `timeout_seconds` rather than letting it be killed halfway through the
  compile (VERIFY-10).
