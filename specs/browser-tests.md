# Real-browser tests

Status: Implemented

`Phoenix.LiveViewTest` renders the server's HTML in-process and speaks the
LiveView protocol, so it sees none of what a browser adds: JavaScript hooks,
the websocket actually connecting, `getComputedStyle`, geometry, focus and
layout. These tests fill that gap with Elixir test code that drives a real
headless Chromium through [PhoenixTest](https://hexdocs.pm/phoenix_test) and
[Playwright](https://playwright.dev/). They are the Elixir-native alternative
to the Python `ui_run` skill: same browser, but written as `mix test` files.

They run against the **test env server in the same BEAM node**, so
`Elia.FakeLLM` and the scratch workspace from `config/test.exs` still apply and
no deploy is involved — unlike `ui_run`, which checks the deployed live tree.
A browser test therefore sees the chat's own worktree code.

## Requirements

- **BROWSER-1** `mix.exs` declares `{:phoenix_test_playwright, "~> 0.19", only: :test, runtime: false}` (which brings `phoenix_test` and `playwright_ex`). No browser dependency is added to any other env.
- **BROWSER-2** The Playwright CLI comes from `assets/package.json`, with `playwright` pinned to a version whose Chromium revision is already in `~/.cache/ms-playwright`, so `playwright install chromium` reuses the cached browser instead of downloading one. This requires Node ≥ 20 (`node --version`); the pin, the install commands and the version constraint are documented in `docs/agents/testing.md`.
- **BROWSER-3** `config/test.exs` sets `config :phoenix_test, otp_app: :elia` and lets the endpoint listen **only when opted in** — `server: System.get_env("ELIA_BROWSER_TESTS") == "1"` — with the port taken from `ELIA_TEST_PORT` (default `4002`), which `config/runtime.exs` leaves alone in the test env (its `PORT` default of 7000 is the running dev server's). A plain `mix test` stays serverless, so test runs that overlap on one machine (a chat and its sub-tasks) cannot collide on the port.
- **BROWSER-4** `test/test_helper.exs` starts `PhoenixTest.Playwright.Supervisor` and sets `:base_url` to `EliaWeb.Endpoint.url()`, so a browser case knows which URL to drive.
- **BROWSER-5** Every browser test carries the tag `:real_browser` (not `:browser`, which `PhoenixTest.Playwright` reads as its browser option), and ExUnit excludes that tag by default, so `mix test`, the `run_tests` tool and `mix precommit` never start a browser or need Node. They are run explicitly with `ELIA_BROWSER_TESTS=1 mix test --only real_browser`.
- **BROWSER-6** Browser tests need built assets. When `priv/static/assets/js/app.js` or `priv/static/assets/css/app.css` is missing, the browser case setup fails with a message naming `mix assets.build`, rather than silently testing an unstyled page with no JS hooks. `priv/static/assets/` stays gitignored.
- **BROWSER-7** The app under test is the test env server in-process: `Elia.FakeLLM` answers model calls and the scratch workspace applies, so the tests need no running dev server, no deploy and no API keys. Browser cases do not run concurrently (`async: false`), since the workspace and the server are shared.
- **BROWSER-8** A smoke file `test/elia_web/browser/chat_browser_test.exs` covers, through the real browser: `/` loads and redirects to a chat; the LiveView websocket connects and the page produces no JavaScript console or page errors; and a message submitted through `#chat-form` is answered by `Elia.FakeLLM` and appears in `#transcript`.
- **BROWSER-9** `docs/agents/testing.md` documents the browser layer: the Node/Playwright pin, the `ELIA_BROWSER_TESTS=1` command, the assets precondition and when a browser test is the right tool instead of `Phoenix.LiveViewTest`.

## Configuration

```sh
# once, in assets/: pins the CLI to the cached Chromium revision
npm install --save-dev playwright@1.64.1
npx playwright install chromium        # reuses ~/.cache/ms-playwright/chromium-1248

# building what the browser loads, then running the browser tests
mix assets.build
ELIA_BROWSER_TESTS=1 mix test --only real_browser
```

`assets/node_modules` is gitignored, so a fresh worktree needs `npm install` in
its `assets/` before a browser run. `ELIA_TEST_PORT` moves the test server off
`4002` when two browser runs would otherwise meet.

Screenshots and Playwright traces go to `tmp/` (gitignored) and are never
committed.

## Out of scope

- Firefox and WebKit browser pools; only Chromium is configured.
- Wiring browser tests into CI; the project has no CI workflows, and
  `mix precommit` stays browser-free (BROWSER-5).
- Replacing `Phoenix.LiveViewTest`: browser tests are a thin layer over the
  existing suite for JS, websocket and layout questions only.
- The Python `skills/browser/` folder skill (`ui_run`) is **retired**: it was
  never merged, `skills/` stays out of the trunk, and the `BROWSER` tests above
  replace it. Its chat was kept but its worktree, `chat/A76mx6ao-DVo`, had been
  removed and the branch deleted, so reopening that chat forks a fresh worktree
  from the trunk. Retired for checking the deployed tree (no deploy, no
  `FakeLLM`, no worktree code) and for a Python toolchain in a repo that
  already has Elixir tests.

## Implementation

- `mix.exs` (dep), `config/test.exs` (BROWSER-3), `test/test_helper.exs`
  (BROWSER-4), a browser case helper in `test/support/` (BROWSER-6),
  `assets/package.json` (BROWSER-2).

## Tests

- `test/elia_web/browser/chat_browser_test.exs` (BROWSER-5, BROWSER-7, BROWSER-8).

Run with `ELIA_BROWSER_TESTS=1 mix test --only real_browser`, after
`mix assets.build`.
