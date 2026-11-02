# Testing

Read this before writing or changing tests. Tests live in `test/elia/` (core) and `test/elia_web/` (web, LiveViews in `test/elia_web/live/`). Helpers are in `test/support/` (`conn_case.ex`, `llm_case.ex`, `fake_llm.ex`, `live_tree.ex`).

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

## Running

- One file: `mix test test/path_test.exs` (or `run_tests`). Previously failed: `mix test --failed`.
- Before finishing: `mix precommit`.
