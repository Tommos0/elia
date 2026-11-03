# UI preview

Status: Draft

A chat's UI changes are invisible to the running app until the user deploys
them (DEPLOY-8), which is a heavy loop for a tweak to a template, a class or a
hook. A **preview** closes that loop: it boots the chat's own code, drives a
real headless Chromium over the pages asked for, writes a PNG per page, and
hands back a link for each one, so the pictures appear in the chat itself.

It is the browser layer of `specs/browser-tests.md` pointed at pages instead of
assertions (BROWSER-1 - BROWSER-7), which is what makes it possible at all: the
test env server in the same BEAM node serves the workspace's own compiled code
with `Elia.FakeLLM` answering model calls, so nothing is deployed and no API key
is involved. The app the preview shows is that workspace's own, whose data is
its own too — empty, except for the sample chat a preview seeds so the pages
have something to render.

## Requirements

### Running a preview (`bin/preview`)

- **PREVIEW-1** `bin/preview [path …]` runs from the chat's workspace (the
  worktree of a chat in Elia's own project, DEPLOY-1) and previews `/` and
  `@chat` when no path is given. It builds the assets first — a preview must
  never show a stale CSS or JS bundle (BROWSER-6) — and then boots the
  workspace's own code as the test env app: the endpoint listens on
  `ELIA_PREVIEW_PORT` (default `4010`), `Elia.FakeLLM` answers model calls, and
  no API key, live settings database or saved conversation is involved
  (BROWSER-3, BROWSER-7, ISOL-5).
- **PREVIEW-2** While it runs, the app's workspace root and live-tree root are
  pointed at the workspace the preview runs in, so the pages show *that* chat's
  code and files, and the preview's own data (`.elia`, gitignored) stays under
  it. A preview never reads or writes the live tree's `.elia`.
- **PREVIEW-3** It drives the pinned headless Chromium of the browser layer
  (BROWSER-1, BROWSER-2) with a viewport of `ELIA_PREVIEW_WIDTH` ×
  `ELIA_PREVIEW_HEIGHT` (default 1280 × 900, so a narrow width previews the
  small-screen layout) and waits `ELIA_PREVIEW_WAIT` milliseconds after load
  (default 500) so client hooks have run. It captures the whole scrollable page.
- **PREVIEW-13** It emulates the colour scheme `ELIA_PREVIEW_THEME` names —
  `dark` or `light` — through the browser's `prefers-color-scheme`, which the
  app's theme script follows when no theme is stored (`data-theme="dark"`).
  Unset or anything else leaves the browser's own default. So a preview can
  show the dark theme (CONF-17), or the light one on a machine set to dark.
- **PREVIEW-4** It writes one PNG per path under `tmp/preview/` in that
  workspace (gitignored), named `<n>-<slug>.png`: `n` is the path's position in
  the arguments and the slug is the path with anything that isn't a letter or
  digit turned into `-` (`/` becomes `root`). The names are deterministic, so a
  later run of the same path replaces the picture the chat already links to.
- **PREVIEW-5** It prints a report for the agent to use: one line per path with
  the file path and its Markdown image link
  (`![<path>](/preview/<chat id>/<file>)`), the chat id taken from the workspace
  it runs in (`Elia.Preview.worktree_chat/1`, the worktree's own name), then the
  console messages and uncaught page errors the page logged, which are reported
  and never fail the run — a preview is not a test. Outside a chat's worktree
  there is no such chat to link through, and the report says so instead of a URL
  the running app couldn't serve (PREVIEW-7).
- **PREVIEW-6** A preview is excluded from the default test run like the
  browser tests (BROWSER-5): `bin/preview` runs it through the browser layer's
  case, tagged `:preview`, so `mix test`, `run_tests`, `mix precommit` and a
  deploy's suite never start a browser. Failures say what to fix instead of
  reading as assertions: a missing `assets/node_modules` names `npm install`
  (BROWSER-2) and a missing asset says to build it (BROWSER-6).

### The sample chat the preview seeds

Pages without content are hard to judge, so a preview seeds one. It goes into
the workspace's own data (PREVIEW-2), through the app's own persistence, so the
live tree's saved chats are never touched.

- **PREVIEW-10** Before it takes any picture, a preview saves a sample chat with
  `Elia.Store.save/3` (STORE) and `Elia.LLM.Message` blocks: a user message, an
  assistant reply with Markdown (heading, list, table, fenced code block, link),
  a `shell` tool call with its output, a failed tool call with its error output,
  and a reasoning block — the pieces a transcript renders (UI-8, UI-15, UI-16,
  UI-20, UI-29). The chat's title comes from its first user message (STORE-7).
- **PREVIEW-11** The sample chat has the fixed id `preview`, so `/c/preview` is
  the same page on every run and its picture's file name never changes
  (PREVIEW-4). The path `@chat` in a preview's arguments means `/c/preview`, and
  the report (PREVIEW-5) prints that path.
- **PREVIEW-12** The sample chat is a saved chat, not a running turn: states
  that exist only while a turn runs (working, streaming, awaiting approval, a
  pause) are not in it, and previewing one needs a scripted turn, which is out
  of scope.

### Showing a preview in the chat

- **PREVIEW-7** The running app serves an image a preview wrote:
  `GET /preview/<chat id>/<file>` returns the file from that chat's worktree
  `tmp/preview/`, and nothing else is reachable. The chat id must be valid
  (`Elia.Store.valid_id?/1`), the file a single path segment with an image
  extension (`.png`, `.jpg`, `.jpeg`, `.webp`), and the resolved path must stay
  inside that `tmp/preview/` directory: any other id, path, extension or a
  missing file is a 404 — never a listing, never a directory, never a file from
  elsewhere in the workspace. The response carries `cache-control: no-cache`, so
  a re-run of a preview shows the new picture and not a cached one.
- **PREVIEW-8** An image in an assistant message (UI-25, UI-27) is shown, not
  linked: it scales down to at most the transcript's width, keeps rounded
  corners and a border like a card, and clicking it opens it at full size in the
  viewer over the chat (IMG-1 in `specs/image-viewer.md`), never in a new tab. A
  screenshot therefore appears in the chat as the agent's reply, with no deploy
  and no page of its own.

### The workflow

- **PREVIEW-9** The agent's instructions say how a UI change is shown: after
  changing a template, a stylesheet (`assets/css/`), a hook or another
  client-side file, run a preview and put its image links in the reply, since
  the user cannot see the change in the running app until they deploy it. The
  wording lives in `AGENTS.md` and the `self-modification` skill. By default a
  preview for that purpose is taken in the dark theme at a mobile width
  (`ELIA_PREVIEW_THEME=dark` with `ELIA_PREVIEW_WIDTH=390`, PREVIEW-3), and a
  light or desktop picture is taken as well only when the change is about that.

## Configuration

```sh
bin/preview                      # the empty state and the sample chat
bin/preview @chat                # just the sample chat
bin/preview / /files /settings   # three pages, three PNGs, three links
ELIA_PREVIEW_THEME=dark ELIA_PREVIEW_WIDTH=390 bin/preview @chat  # the agent's default
ELIA_PREVIEW_WIDTH=390 bin/preview @chat   # the small-screen layout
ELIA_PREVIEW_THEME=dark bin/preview @chat  # the dark theme
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `ELIA_PREVIEW_PORT` | `4010` | the port the preview server listens on |
| `ELIA_PREVIEW_WIDTH` | `1280` | viewport width |
| `ELIA_PREVIEW_HEIGHT` | `900` | viewport height |
| `ELIA_PREVIEW_WAIT` | `500` | milliseconds to settle after load |
| `ELIA_PREVIEW_THEME` | *(browser default)* | colour scheme to emulate: `dark` or `light` |

`tmp/preview/` is gitignored, so a preview is never committed and never reaches
a deploy.

## Out of scope

- Previewing the deployed tree, and a preview of the user's real chats,
  projects and settings: a preview runs the test env app on its own data — the
  sample chat it seeds (PREVIEW-10 - PREVIEW-12) and nothing else. A dev-env
  preview over a copy of the live data would be a separate change.
- Scripted interaction (clicking, hovering, typing, a streaming turn) and
  video or Playwright traces: a preview navigates and waits.
- Browsers other than Chromium, and sizing below the phone breakpoint.
- A preview tool of its own with an approval card: it runs through `shell`,
  whose `timeout_seconds` a long first run (npm, a compile, the browser) needs.

## Implementation

- `Elia.Preview` (naming, path safety, the URLs and the sample chat, no
  browser), `EliaWeb.PreviewController` + a router entry (PREVIEW-7),
  `test/elia_web/browser/preview_test.exs` with `use EliaWeb.BrowserCase`
  (PREVIEW-1 - PREVIEW-6, PREVIEW-10 - PREVIEW-12), `bin/preview` (PREVIEW-1),
  the transcript's image styling in `EliaWeb.ChatLive` (PREVIEW-8),
  `AGENTS.md`, `docs/agents/harness.md` and the `self-modification` skill
  (PREVIEW-9).

## Tests

- `test/elia/preview_test.exs` (naming and path safety, PREVIEW-4, PREVIEW-7;
  the sample chat, PREVIEW-10 - PREVIEW-11).
- `test/elia_web/controllers/preview_controller_test.exs` (PREVIEW-7), against a
  throwaway live tree with a chat worktree (`Elia.LiveTree.create/0`).
- `test/elia_web/live/chat_live_test.exs` (an image in a message, PREVIEW-8).
- `test/elia/skills_test.exs` (the preview instruction the agent follows names
  the dark, mobile default, in the `self-modification` skill and `AGENTS.md`,
  PREVIEW-9).
- The preview run itself is checked by hand, since it needs a browser:
  `bin/preview`, from a chat in Elia's own project.
