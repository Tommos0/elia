# Testing

Read this before writing or changing tests. Tests live in `test/elia/` (core) and `test/elia_web/` (web, LiveViews in `test/elia_web/live/`, real-browser tests in `test/elia_web/browser/`). Helpers are in `test/support/` (`conn_case.ex`, `llm_case.ex`, `fake_llm.ex`, `live_tree.ex`, `browser_case.ex`, `browser_js_logger.ex`).

## Specs

- Every requirement you add or change needs a test. Cite its ID in the test name or a comment, e.g. `# SHELL-3`.
- The corpus is checked too: `test/elia/spec_hygiene_test.exs` fails the suite on the rules `specs/README.md` states (SPEC), so an ID defined twice, a section outside the shape or a citation of an ID no spec defines is a test failure rather than a review comment.
- Traceability is checked too: every requirement must be accounted for by a test file that exists, named in a spec's `## Tests` section, or by a `No test:` line saying why, and a named path must be there (TRACE, `specs/test-traceability.md`); `test/elia/spec_tests_test.exs` fails the suite on the rest. That is what a spec's `## Tests` section is for — name the file and the IDs it covers — and why a test cites its own IDs.
- Pick a **free** ID, and re-check it when you rebase: another chat can land the same ID on `master` while you work on yours, and only then does the hygiene lint see the duplicate. Renumber yours (the new one goes at the end, since IDs are never reused) and update every citation — a blanket `UI-<n>` → `UI-<n+1>` in the files you touched, and by hand in a file that also cites the other chat's requirement.
- If code and spec disagree, one is a bug. Fix the code or update the spec deliberately. See `specs/README.md`.
- Worktree and deploy tests use a throwaway live tree (`Elia.LiveTree.create/0`, `test/support/live_tree.ex`), never the server's own tree. A test of a *push* gives it a remote with `Elia.LiveTree.origin/2` (a bare repository the test makes, outside the tree so the jail argument is real, DEPLOY-42/43); a push is unjailed, so it reaches the remote even where a jailed command could not (ISOL-13), and the trunk it pushes is whatever the test committed.
- A test that needs a real git tree — a snapshot (`Elia.Snapshot`, SNAP), a worktree, a deploy — uses that throwaway live tree, whose `git/2`, `git!/2` and `commit/2` run git in it. Two traps cost a debugging round each: a temporary index for git plumbing has to be *created and then removed* (`idx=$(mktemp); rm -f "$idx"`) — git reads the empty file `mktemp` leaves behind as a corrupt index ("index file smaller than expected") — and `IO.puts` from library code does not reach a `mix test` run's output, so debug a library function by calling it from a script with `MIX_ENV=test mix run <file>.exs`.
- A test that deploys by hot reload replaces the loader — `config :elia, Elia.Deploy, load: fun` — instead of calling `Phoenix.CodeReloader.reload/1`: a real recompile inside a test run rebuilds Elia's own endpoint and leaves `_build/test` broken for every later test.

## Processes

- **Always** start processes with `start_supervised!/1`.
- **Avoid** `Process.sleep/1` and `Process.alive?/1`.
  - To wait for a process to end, monitor it and assert on the DOWN message:

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - To synchronize before the next call, use `_ = :sys.get_state(pid)`.
- Use `Elia.FakeLLM` (`test/support/fake_llm.ex`) rather than real model calls.
  A provider serves only the chats of the test that started it (SUITE-9), so
  start it before the sessions you drive: a call from a session that was already
  running is refused, which is what keeps a session another test leaked from
  taking a turn you scripted.
- A test that runs the boot scan (`Elia.Agent.Resumer.resume_interrupted/0`)
  points the store at a scratch directory of its own (SUITE-10,
  `test/elia/auto_resume_test.exs`): the scan reads every saved chat, so against
  the store the suite shares it would resume the chats other tests left behind
  and start sessions that outlive the test that runs it.
- A project's allowlist of hosts is global state (PROJ-49, NET-28): Elia's own
  project's lives in the settings database under `:harness_project_allowlist`
  and a stored project's in the registry file. A test that allows a host must
  put the list back —
  `on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)` — or a later
  test in the same file sees it, and `test/elia/projects_test.exs` deletes the
  key in its `setup` for the same reason. A chat's own setting holds its mode
  and nothing else, so a test that wants a chat to reach a host sets both: the
  project's entry and the chat's mode.

## Fixtures that name a tool

- A test that renames a tool in a fixture has to follow it into the compaction
  notes: `Elia.LLM.Compaction.input_summary/1` renders a `shell` call as
  `$ <command>`, so the note for a `shell` result is
  `[output elided by compaction: shell $ cat file2.txt. …]` — an assertion on it
  needs the `$`, not just the tool name and the command.

## Fixtures that are source code

- A fixture that has to contain a backslash — a default argument
  (`def plain(a, b \\ 1)`), a regex, an escaped character — is written with
  `~S"""`, never `"""`: in a plain Elixir string `\\` is *one* backslash, so
  the file the test writes is not the source it looks like, and
  `Code.string_to_quoted/1` fails on it. A shell heredoc (`cat > f <<'EOF'`)
  passes `\\` through unchanged; an Elixir string does not.
- A probe script or fixture written to `/tmp` in one `shell` call is gone in the
  next — every call gets its own `/tmp` and pid namespace (ISOL-2) — so write it
  and run it in the same command. `MIX_ENV=test mix run --no-start <script>` is
  the quick way to push something through the real pipeline (a render, an index)
  without a test.

## LiveView tests

- Use `Phoenix.LiveViewTest` and `LazyHTML`.
- Drive forms with `render_submit/2` and `render_change/2`.
- **Always** reference the DOM IDs you added to templates, via `element/2` and `has_element?/2`: `assert has_element?(view, "#my-form")`.
- **Never** assert against raw HTML. Prefer testing for key elements over text content, which changes.
- Test outcomes, not implementation details. Start with simple "content exists" tests, then add interactions, in small isolated files.
- `<.form>` and other components can render different HTML than you expect, so test against the actual output.
- `assert_patch/2` compares the URL as the page's own links build it, and the
  `~p` sigil percent-encodes a slash in a query value: a patch to a nested path
  is `"/files?path=files_live_fixture%2Finner"`, so build the expectation with
  `URI.encode_query/1` (`&"…?" <> URI.encode_query(%{path: path})`) rather than
  by hand. Over a map of more than two keys the two don't even agree on the
  order: `URI.encode_query/1` walks the map and `~p` sorts, so a page that
  builds its patch URL with `~p` over a map is matched by `~p` over the same
  map, not by a query string of your own (`files_live_test.exs`'s `mode_url/2`).
- `render/1` returns HTML with the whitespace the template's own line breaks
  hold, and a text node a template spreads over several lines comes back with
  that newline and indentation injected into it — while `has_element?/3` with
  `text:` compares the element's text as Floki reads it, which is where that
  whitespace is gone. So an assertion copied from a passing
  `has_element?(view, "#id", text)` can fail as `render() =~ text`; assert a
  substring, or check the exact text in a real-browser test with `textContent`,
  where what the browser parsed is finally the truth.
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
  server, no API keys. They see the workspace's own code — the worktree a chat
  made for itself, when its code is there (DEPLOY-28).
- They are excluded from a plain `mix test`, so `mix test` and `mix precommit`
  stay fast and need no Node. Run them explicitly:

      mix assets.build                                 # esbuild/tailwind run in dev only
      ELIA_BROWSER_TESTS=1 mix test --only real_browser

- A browser test file run without `--only real_browser` runs nothing: it
  reports `0 failures, N excluded`, which reads as a green run. The line filter
  (`mix test test/elia_web/browser/x_test.exs:42`) is the exception — it
  includes the one test it names. And the Playwright driver can die at startup
  with an `EPIPE` stack (the same symptom a taken port gives a preview, above)
  and leave the run with everything excluded and an exit of 0 all the same, so
  a browser run is read by its number of tests, not by its exit.
- The first run after a recompile can fail with `Timeout 2000ms exceeded` on
  `visit`, while the test env server boots, and the same run passes when it is
  repeated — re-run it before chasing the page.
- A closed `<details>` still lays its hidden content out in Chromium — it is in
  the DOM, and has a height — so a test that the card is collapsed asks
  `element.checkVisibility()`, not `offsetHeight`, and opens it by clicking the
  `summary` (`document.querySelector("#id > summary").click()`).
- `assets/node_modules` is gitignored, so a worktree a chat made for itself
  (DEPLOY-28) should have the live tree's copied in (DEPLOY-29); without it,
  install the packages the bundle imports (`@xterm/*`) once with `npm install`
  in `assets/`. The Playwright CLI is not one of them — it is user-wide, not a
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
- That rule counts errors the *file* logs too: a script in a file the app serves
  into a sandboxed frame is refused, and the browser logs the refusal as a
  console error of the page's. A test whose fixture carries a script therefore
  accounts for the log instead of hiding it — `BrowserJsLogger.take/0` and an
  assertion that every entry is the browser's own refusal, as
  `files_raw_test.exs` does — or the case flunks on the file's error.
- A whole-directory browser run (`mix test test/elia_web/browser --only
  real_browser`) is where a test that passes alone can fail: `chat_menu_test`'s
  Escape test has been seen to, with the browser shared and the runs serial. Re-run
  the file on its own before chasing the page.
- `EliaWeb.BrowserCase` gives you the page, not a LiveView: there is no
  `has_element?` and no verified route (`~p`), so a test uses `assert_has/3` and
  builds a URL as a string (`"/files?" <> URI.encode_query(%{path: path})`) —
  `EliaWeb.ConnCase` is what brings those helpers, and a browser test that
  `use`s it instead of `BrowserCase` loses the console-error check (BROWSER-8).
- Keep them few and shallow: a browser run is seconds per test. Test outcomes
  in the LiveView suite where you can, and reach for a browser only for what
  JavaScript and layout do (e.g. `#chat-input`'s Enter-to-send hook). What the
  *browser* decides — which of two layers is on top — has no other witness:
  `evaluate/4` with a function that returns `document.elementFromPoint` and
  `getComputedStyle` is how `test/elia_web/browser/small_screen_layout_test.exs`
  checks a stacking order (UI-94).
- Playwright **scrolls an element into view as part of clicking it**, and the
  page sees that scroll. Where something in the page reacts to a scroll — the
  transcript's own following (UI-14), or the citation popover a scroll closes
  (CITE-8) — a test must put the page where it wants it *before* the click
  (`evaluate/2` with a `scrollIntoView` or a `scrollTop`), or the click's own
  scroll races the thing it is checking.
- `PhoenixTest.Playwright` has no `hover` and no touchscreen, so
  `test/elia_web/browser/chat_browser_test.exs` drives both through the lower
  binding: `PlaywrightEx.Frame.hover(frame_id, selector: …)` for the pointer
  resting on an element (`unwrap/2` hands you the ids), and
  `PlaywrightEx.Page.mouse_move(page_id, x: …, y: …)` for a move to a point,
  which is what reaches a layer that takes no pointer of its own — an element
  with `pointer-events: none` is never a Playwright click or hover target. A tap
  is `evaluate/2` dispatching the events a finger sends: `pointerdown` and
  `pointerup` with `pointerType: "touch"`, then the `click` the browser sends
  after them.
- A pointer sent to the point it already rests on reports nothing: no
  `pointerover`, so a hook that opens on one does not open again. A test that
  hovers the same element twice moves the pointer somewhere else in between
  (`chat_browser_test.exs`'s `hover_citation/1`).
- `evaluate/2` hands back the `conn`, never the value: a value comes to you
  through the function `evaluate/3` (or `/4`) takes, so capture it there rather
  than by assignment. A JavaScript object arrives with **string** keys
  (`view["marked"]`), not atoms.
- A test that changes the driver's own config must **merge** it:
  `Application.put_env(:phoenix_test, :playwright, …)` replaces the whole
  keyword list, taking the test helper's `assets_dir` (BROWSER-2) and
  `config/test.exs`'s `screenshot_dir` with it — the driver then fails with
  "Could not find Playwright in `./assets`", which reads like a broken install.
  Read the list and `Keyword.put` into it, as `preview_test.exs` does. In
  `browser_context_opts`, `color_scheme` is an atom (`:dark`), not a string.

### UI previews

`bin/preview` (`specs/ui-preview.md`, PREVIEW) points the same browser at pages
instead of assertions: it boots the workspace's own code as the test env app,
screenshots the pages you ask for into the gitignored `tmp/preview/`, and prints
a Markdown image link per picture, which the chat renders at
`/preview/<chat id>/<file>` (`EliaWeb.PreviewController`). It is how a UI change
is shown before it is deployed. `test/elia_web/browser/preview_test.exs` is the
run itself, tagged `:preview` and excluded like these tests, so it never starts
a browser during `mix test`.

A picture is looked at with the `view_image` tool, whose path is resolved
against the workspace root rather than the chat's own working directory: a
preview taken in `tmp/worktrees/<chat id>/` is read as
`tmp/worktrees/<chat id>/tmp/preview/<file>.png` even though the chat is `cd`'d
there (WD-1, WD-9).

A picture is only as tall as the viewport, `full_page: true` included: the app
shell has a height of its own and the transcript scrolls inside it (UI-78), so
what has been scrolled below the pane is not in the picture — raise
`ELIA_PREVIEW_HEIGHT` to bring a card low in a long transcript into frame. A
picture of a `<details>` that is shut is taken by temporarily rendering it
`open` for the run and reverting that edit afterwards, which `git status
--porcelain` in the worktree then says nothing about.

The preview runs the test env, where the host's jail is off, so `Elia.Net`
falls back to unrestricted (NET-1, NET-25) and the settings page's Network
section shows its "this host can't limit a chat's network" state rather than the
entries list: a picture of the entries list needs a host that can build a jail,
and the projects page (`/projects`) is where those entries are edited anyway
(PROJ-50).

A preview navigates and waits; it never clicks, hovers or types (out of scope in
`specs/ui-preview.md`). A picture of something a *click* opens — a citation's
popover (CITE-7), the image viewer (IMG-1) — is therefore taken by hand, from
the browser layer: a throwaway `:preview`-tagged test that visits the page,
`click`s, and `screenshot`s into `ELIA_PREVIEW_DIR`, which `bin/preview` uses as
its own output directory. Tag it `:preview` and `use
PhoenixTest.Playwright.Case` the way `preview_test.exs` does: a throwaway that
`use`s `EliaWeb.BrowserCase` carries `:real_browser` as well, and that exclusion
beats `bin/preview`'s `--only preview`, so it quietly runs nothing (`1 test, 1
excluded`). Run that one yourself instead:
`ELIA_BROWSER_TESTS=1 mix test --only real_browser <file>`.

## Running

- One file: `mix test test/path_test.exs`. Previously failed: `mix test --failed`.
- The whole suite: `bin/test` — the same tests as `mix test`, but as concurrent
  partitions (`specs/test-suite.md`, SUITE). Each partition gets its own scratch
  workspace, settings database and temp directory, under one run directory the
  run makes for itself (SUITE-1, SUITE-11), so the wall time is the slowest
  partition instead of the sum. `bin/test --plan` prints the split without
  running anything, and `bin/test test/foo_test.exs` (or `--failed`, or `--only`)
  falls back to one plain `mix test` (SUITE-6).
- The split is by file, weighted by how slow each one measured: the deploy tests
  and the restart tests each lead their own partition. A new file needs no entry
  — it weighs 1 and lands on the lightest partition (SUITE-3). The weights are
  a comment away in `bin/test`; re-measure with `mix test --slowest 20` when a
  partition feels lopsided.
- Before finishing: `mix precommit`, which runs its test step through `bin/test`
  (SUITE-8) — unless the change is one you judge safe without a run, and then say
  in your last message why the skip was safe (`AGENTS.md`).
- A suite run started from a chat's shell inherits **the running server's own
  environment**, and two variables change what tests see there: `ELIA_SUPERVISED`
  (DEPLOY-33, RESTART-12) makes the two deploy tests that expect a server nothing
  would bring back fail, and `ELIA_ALLOWED_ORIGINS` makes the three
  `test/elia_web/socket_origin_test.exs` cases fail, because the endpoint's
  `check_origin` is then not `:conn` (SOCK-1). Five failures in partition 1, all
  of them this one cause: run `env -u ELIA_SUPERVISED -u ELIA_ALLOWED_ORIGINS
  bin/test` from such a shell. `settings_live_test.exs` says which server it is
  about for itself (`unsupervised/0`); the deploy and socket-origin files don't
  yet.
- A partition can fail on a test that passes on its own. In this tree partition
  2 failed twice in a row — once on `test/elia_web/live/chat_upload_test.exs`
  and once on an `Elia.LLM.AnthropicTest` case — while the machine was busy with
  other runs, and each file passed when run alone (`mix test test/<file>`). When
  a partition fails, run the file it named before believing it. The same goes for
  a run that fails a handful of tests at once under load —
  `test/elia/shell_test.exs`'s process-group ones are the usual suspects there —
  and for a partition whose failures you can't name: re-run, and say what you
  re-ran. `Elia.TerminalTest`'s "leaves no tmux server and no socket" is one of
  these too: tmux keeps its sockets in `/tmp/tmux-<uid>/` for the whole user
  rather than in the run's own temp directory, so the test can see one a
  concurrent run's terminal is using, and the file passes when run alone.
- `test/elia_web/live/chat_live_test.exs`'s "a command awaiting approval is
  open" (UI-99, around line 1687) fails on `master` when it is run alone: it
  waits 5s for `{:status, :idle}` after approving a command that really runs
  `mix test`, which takes longer than that on this machine. It is not your
  change's — stash your work and run the file before chasing it.
- Runs don't have to take turns. Every run's state is its own: the scratch
  workspace, the settings database and the temp directory the run's tests name
  their own paths in all live under a run directory belonging to that run
  (SUITE-1, SUITE-11, SUITE-12), whether it is a `bin/test` partition, a plain
  `mix test`, a preview or the suite a deploy runs for itself. Leftovers from a
  run that was killed rather than exited are cleared away the next time a run
  starts (SUITE-13).
- What two runs still cannot share is the port: a run that starts the endpoint
  binds one, so give a second browser run its own `ELIA_TEST_PORT` (`bin/preview`
  takes `ELIA_PREVIEW_PORT`, default 4010, and moves the test server there). A
  preview whose port is taken fails as a `Node.js` `EPIPE` stack from the
  Playwright CLI with no picture, and its exit is 0 all the same — check for the
  `UI preview: N picture(s)` line, and rerun it with another
  `ELIA_PREVIEW_PORT` rather than reading the stack as a broken page.
- A suite run through the `shell` tool needs a longer timeout than the shell's
  default: `timeout_seconds` is 300s unless the call asks for more, and never more
  than 1800s (SHELL-10), while `mix precommit` compiles, formats and runs four
   partitions. A chat's first run in a worktree it made for itself compiles deps
   and app before
   its first test, so give it `timeout_seconds` rather than letting it be killed
  halfway through the compile. A run the harness itself makes — the deploy's
  suite (DEPLOY-5) — is `Elia.Harness.run_tests/3`: it hands `mix test` a
  per-test `--timeout` and runs under `config :elia, Elia.Harness, timeout: 600`
  by default (VERIFY-1, VERIFY-8, VERIFY-9).
- In the test env `Elia.Workspace.root()` is the run's own scratch workspace
  (SUITE-1), not the tree you are in — so a test that wants a file of the tree
  has to set `:workspace` itself, as the preview's setup does with `File.cwd!()`
  (PREVIEW-2), and a `MIX_ENV=test mix run -e` probe sees that scratch workspace
  too, which makes a `File.exists?` on a tree path come back false for a reason
  that is not a bug.
