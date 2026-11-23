# Preview host

Status: Implemented

A project's build output — its `dist` folder — is served over HTTP at a
hostname of their own, so a browser can run what the project builds — on a
phone, through the tunnel the app is reached at. The Files page cannot do that:
a raw view of an HTML document is served under `sandbox` with its scripts off
(EXPL-24), deliberately, so a file from a workspace can never run in the app's
own origin. A preview host is the other way round — the files are served from a
hostname that is not the app's, under no policy of the preview's own — so a
page's scripts, module scripts, storage and same-origin requests work as they
do from any web server, while the app's origin stays untouched. What it serves
is one folder: the `dist` folder of the project its path names, and nothing
else of that project's — a source file, a `.env` or a key beside the build is
not reachable through it. It is a file server and nothing else: read-only, one
project at a time, no listing, no session, and the same refusals the explorer
gives for a path that leads out of the folder served, into a protected path or
through a symlink (EXPL-1, EXPL-2, EXPL-5).

## Requirements

### Serving a project

- **SERVE-1** With `ELIA_PREVIEW_HOST` set (config `:elia, EliaWeb.PreviewHost,
  host:`) the app serves a project's files over HTTP at that host, in every
  environment and on the port the app itself listens on — there is no second
  listener.
- **SERVE-2** With no preview host configured nothing is served as a preview,
  and every request is answered as it is without the feature.
- **SERVE-3** On the preview host no route of the app is reachable: a path that
  is not a file of a project is a 404, so the app's own pages are not served
  there.
- **SERVE-4** On any other host the preview serves nothing, so a project's file
  is never served as a document from the app's own origin.
- **SERVE-5** The request's host is the `Host` header, the first
  `X-Forwarded-Host` value, or the server's own view of the request, with a
  missing port meaning the default port of that scheme (RECOVER-13's rule), so a
  proxy that terminates TLS and rewrites the hostname reaches the preview.

### What it serves

- ~~**SERVE-6** `GET /<path>` serves `path` under the folder of the project that
  is open — the one `Elia.Projects.default/0` names (PROJ-8), which the app
  stores when a project is chosen in the header, the Files page or the Projects
  page, or a chat in it is opened, and which the Files page browses when no chat
  is in view (EXPL-15) — and `GET /` serves that folder's `index.html`.~~
  Superseded by SERVE-16 and SERVE-17: the path names the project and its `dist`
  folder, so no project is open in the preview and nothing is served at the
  root.
- ~~**SERVE-7** A first path segment that is a project's slug — the one PROJ-34
  derives from its name, matched against the projects `list/0` returns in order
  (PROJ-3, PROJ-4), so the first of two projects that derive the same one serves
  — serves that project with the rest of the path under its folder; a first
  segment that is no project's slug is a path in the open project.~~
  Superseded by SERVE-16 and SERVE-17: the first segment is always a slug, and
  one that is no project's is a 404.
- **SERVE-16** The first path segment names a project by its slug — the one
  PROJ-34 derives from its name, matched against the projects `list/0` returns
  in order (PROJ-3, PROJ-4), so the first of two projects that derive the same
  one serves — and the rest of the path is relative to that project's `dist`
  folder, with `/<slug>/` being the `index.html` that folder holds (SERVE-8).
- **SERVE-17** The root `/`, and any path whose first segment is no project's
  slug, is a 404.
- **SERVE-18** A project with no `dist` folder serves nothing: every path under
  its slug is a 404.
- **SERVE-8** A directory is served as the `index.html` it holds, and a
  directory without one is a 404; no directory is ever listed.
- **SERVE-9** A file is served under the content type its extension gives it —
  HTML, CSS, JavaScript, JSON, SVG, plain text, fonts, WASM and the kinds
  EXPL-22 previews (image, PDF, video, audio) — with
  `x-content-type-options: nosniff`, and an extension nothing names is
  `application/octet-stream`.
- **SERVE-10** A path that resolves outside the folder served (SERVE-16), into a
  protected path (WS-1: `.git`, `_build`, `deps`, `.elia`), through a symlink,
  to a missing file, a special file or one that cannot be read is a 404
  (EXPL-1, EXPL-2, EXPL-5).
- **SERVE-11** A response carries no `content-security-policy`, so a document's
  own scripts, module scripts, storage and same-origin requests work as they do
  from any web server.
- **SERVE-12** A response carries `cache-control: no-cache` and the served
  file's `etag` and `last-modified`, and a request whose `if-none-match` matches
  is answered `304` with no body (EXPL-24, PWA-9).

### How it is served

- **SERVE-13** The preview takes no part in the app's session: it reads no
  session, sets no cookie, needs no forgery token, and serves a request carrying
  the app's session cookie exactly as it serves one that does not.
- **SERVE-14** `GET` and `HEAD` are the only methods answered, any other method
  is a 405, and no request writes anything.

### The Files page

- **SERVE-15** With a preview host configured, the Files page's open control
  for an HTML document in a project's `dist` folder points at that document's
  preview URL — its project's slug and its path under `dist` — and opens it in
  a new tab. It stays the raw view's URL (EXPL-26) with no preview host
  configured, for a document elsewhere in the project's folder, and for one in
  a chat's own workspace (EXPL-17), which no project serves.

## Configuration

- `ELIA_PREVIEW_HOST` names the host the preview is served at, with a port when
  it is not the app's own — `preview.wolk.run`, or `preview.localhost:7000` on
  this machine. Unset: no preview host, and nothing changes.
- Behind a tunnel, one public hostname pointing at the app's own port is all
  that is needed — `preview.wolk.run` → `http://localhost:7000` — so every
  project is previewed without a rule of its own.
- A build is previewed under its project's slug, so it has to fetch its assets
  by a relative path (`base: './'` in Vite). One that fetches them by absolute
  path (`/assets/…`, Vite's default) asks for a path whose first segment is no
  project's slug, which is a 404 (SERVE-17); a build that is one self-contained
  document needs nothing.
- The preview has no authentication of its own — the app has none either. What
  it may serve is a project's `dist` folder and nothing beside it (SERVE-16,
  SERVE-17), so a hostname behind an auth proxy such as Cloudflare Access serves
  it like any other, and is not what keeps a project's own files out of reach.

## Out of scope

- A single chat's worktree as the previewed root (EXPL-17): a preview names a
  project (SERVE-16), so a build a chat has not merged is previewed by
  putting it in the project's folder.
- Writing, uploading or deleting anything through the preview.
- Live reload, a websocket, or anything rendered on the server: the preview
  serves the files as they are on disk.
- An authentication of its own, a token in the URL, or a hostname per project.
- A build output anywhere other than a project's `dist` folder, and a project's
  sources or its folder as a whole.
- Showing a file in the app's own chrome: that is the Files page's raw mode
  (EXPL-30).

## Stored data

Nothing is stored: the preview reads files from disk, writes none, keeps no
state between requests and reads no saved shape differently. No migration.

## Implementation

- `EliaWeb.PreviewHost` — the host check, the project a path's slug names and
  the file served under its `dist` folder (SERVE-16 - SERVE-18), ahead of the
  router in the endpoint's plug list.
- `Elia.Explorer` — the resolved file and the content type to serve it as,
  reusing the path refusals of EXPL-1, EXPL-2 and EXPL-5.
- `config/runtime.exs` — `ELIA_PREVIEW_HOST`.
- `EliaWeb.FilesLive` — the open control's URL (SERVE-15).

## Tests

- `test/elia_web/preview_host_test.exs` (SERVE-1 to SERVE-14 and SERVE-16 to
  SERVE-18, over the endpoint: the host as `X-Forwarded-Host` and with the
  scheme a proxy reports, the app's routes unreachable on the preview host and
  the preview unreachable on the app's, a project's slug serving its `dist`
  folder while the root and a first segment that is no slug are 404, a project
  with no `dist` folder, `index.html` and a directory without one, each content
  type and the fallback, each refusal, no policy header, revalidation with
  `if-none-match`, the app's session cookie changing nothing, `HEAD` and a
  refused method).
- `test/elia_web/live/files_live_test.exs` (SERVE-15, with a preview host
  configured, for a document under a project's `dist` folder and for one
  elsewhere in it, and for a chat's own workspace and with none — the tests
  EXPL-26 already has).
- `test/elia_web/browser/preview_host_test.exs` (SERVE-11 as behaviour: a page
  the preview serves is in an origin of its own, runs its own script and keeps
  its own storage — what the raw view's policy denies). It is a real-browser
  test, so it runs with `ELIA_BROWSER_TESTS=1` (BROWSER-2, BROWSER-3).
