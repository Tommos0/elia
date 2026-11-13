# Recovery

Status: Draft

A page that reaches the app when its own UI cannot. It existed once for a world
where the agent edited the tree the server ran from, so a bad change could leave
every request showing Phoenix's compilation-error page — including the chat UI,
the only way to ask the agent for a fix. That world is gone: a chat works in its
own worktree (DEPLOY-1), the only thing that loads code is a deploy, and a
deploy runs the full suite and a compile first and refuses to load a tree that
fails either (DEPLOY-5, HOT-4, HOT-6), so the app cannot be left uncompilable.
The page's own work then was hollow — it rolled *files* back, and a deploy
refuses a live tree with uncommitted changes (DEPLOY-5), which is exactly what a
rollback leaves behind — so the whole thing was retired (RECOVER-1–RECOVER-9).

It comes back smaller, for the failure the deploy gate does *not* catch: a
deploy that passes its suite and still leaves the UI unusable. The suite is
LiveView-level — browser tests are excluded (BROWSER-6) — so a broken layout, a
hook that raises on mount, or a new class with no rule on a page that kept its
stylesheet (HOT-8) all survive it, and DEPLOY-24 only refuses a tree whose
bundle is missing outright. The Settings page is then exactly what may be
broken, and the chat UI is the only way to ask for a fix. `/recover` is the way
out: plain HTML, no bundle and no JavaScript, that sends the app back to a
revision it has run before (DEPLOY-25, DEPLOY-26) — a deploy's own undo —
rendered by a plug that does not depend on the tree's front end at all.

This is not file rollback and not checkpoints: the only revisions on offer are
ones the running app has actually loaded, and the only thing a button does is
what the Settings page's own rollback control does (CONF-23).

## Requirements

- **RECOVER-10** `GET /recover` is served as plain, server-rendered HTML that
  needs none of the tree's front end: no CSS bundle, no JavaScript, no LiveView
  socket, and not the app's own layout (`EliaWeb.Layouts`, whose markup a deploy
  may be what broke). It is a plug in the endpoint (`EliaWeb.Recovery`, before
  the router), in every environment, and it answers without compiling or
  reloading anything (DEPLOY-8) — the files it reads are the live tree's own
  (DEPLOY-2).
- **RECOVER-11** The page says what the running app is on, which revisions it
  has run (DEPLOY-25; newest first, each with when it was loaded and by what)
  and what the last deploy or rollback did (DEPLOY-23) — the same record the
  Settings section reports (CONF-22), read back through `Elia.Deploy`. The
  revisions are `#recover-revisions`, and the last operation is
  `#recover-last`.
- **RECOVER-12** Every kept revision that is not the one running has a form that
  goes back to it (DEPLOY-26), with a button per load mode (hot reload,
  DEPLOY-6; restart, DEPLOY-7) — the revision in a `revision` field and the mode
  in a `mode` field, so a test can post one without a browser. The POST hands
  the work to the runner rather than doing it in the request (DEPLOY-15,
  DEPLOY-16), and the page it renders then says that the operation is running
  and which step it is on (DEPLOY-21, DEPLOY-22) — a build and a load is
  minutes, not a request that hangs — with a link that reloads the page to
  follow it.
- **RECOVER-13** A POST is same-origin or it is refused: the origin rule
  RECOVER-9 stated, revived. The origin's scheme is the first `X-Forwarded-Proto`
  value if present, otherwise the scheme the server received; its host and port
  are any of the `Host` header, the first `X-Forwarded-Host` value, or the
  server's own view of the request, with a missing port meaning the default port
  of that scheme. Through a proxy that terminates TLS,
  `https://app.example.com` therefore matches `Host: app.example.com` with
  `X-Forwarded-Proto: https`. A missing, `null`, other-scheme, other-host or
  other-port origin gets a 403 and nothing runs.
- **RECOVER-14** Any method other than `GET` and `POST` gets a 405. A POST
  naming a revision that is not in the record (DEPLOY-25) gets a 400 and nothing
  runs, and one while an operation runs is refused with a 409 and a message
  saying so, the way the runner refuses a second deploy (DEPLOY-16).
- **RECOVER-15** The page links back to the app (`/`), and the Settings
  deployment section names it (CONF-23).

## Out of scope

- Rolling files back, or choosing individual files to restore (retired
  RECOVER-3–RECOVER-6): the live tree is a git repository with the trunk in
  `master`, and a revision the app has run is the unit.
- Checkpoints (CKPT), and the 500-page banner that linked here (retired
  RECOVER-7): a crash page now just shows the error.
- Authenticating the page (retired RECOVER-2): the app has no login of its own,
  so anyone who can reach the chat UI can already approve commands. The
  same-origin POST check (RECOVER-13) is what guards the state change.

## Retired requirements

- ~~**RECOVER-1** When the endpoint's code reloader is on (the dev server), the
  endpoint serves `/recover` before `Phoenix.LiveReloader` and
  `Phoenix.CodeReloader`, so it answers without recompiling anything. In other
  environments the plug isn't part of the endpoint.~~ Retired: the plug is gone.
  RECOVER-10 brings it back before the router, without the recompile concern:
  no request reloads code any more (DEPLOY-8).
- ~~**RECOVER-2** `/recover` only serves local requests.~~ Removed: recovery
  has to work through a reverse proxy or tunnel too. The app has no login of
  its own, so anyone who can reach the chat UI can already approve commands.
  Forgery protection is RECOVER-9.
- ~~**RECOVER-3** `GET /recover` shows the 20 newest checkpoints (short sha,
  time, label), each with a roll-back button. The recommended checkpoint
  (CKPT-9) is marked as recommended and listed first. Other methods get a 405.~~
  Retired: there are no checkpoints to show (CKPT).
- ~~**RECOVER-4** `POST /recover` with a `checkpoint` field rolls the workspace
  back to that checkpoint (CKPT-5). The request needs a same-origin `Origin`
  header (RECOVER-9), otherwise it gets a 403. The
  checkpoint must be one of the 100 newest checkpoints, otherwise it gets a
  400 and nothing runs.~~ Retired: nothing rolls back.
- ~~**RECOVER-5** After a successful rollback, skills are reloaded and the page
  shows the sha restored, an undo button (a rollback to the snapshot taken
  just before, CKPT-5), and a link back to the app. The page says that the
  running app only changes after a deploy (DEPLOY-8).~~ Retired.
- ~~**RECOVER-6** If the rollback fails, the page shows the error with a 500
  and the workspace is left as git left it.~~ Retired.
- ~~**RECOVER-7** An HTML response with status 500 gets a banner at the top of
  `<body>`: a link to `/recover` and, if there is a recommended checkpoint
  (RECOVER-3), a button that rolls back to it. Other responses (other
  statuses, non-HTML, compressed) are left unchanged, and a failure while
  building the banner never changes the response.~~ Retired: the banner is
  gone. A crash page now just shows the error.
- ~~**RECOVER-8** The recovery plug uses only modules loaded before the code
  reloader (`Elia.Checkpoint`, `Elia.Skills`, `Elia.Workspace`), so its
  running version stays the boot-time one while the rest of the app is broken.~~
  Retired.
- ~~**RECOVER-9** A `POST` is same-origin when its `Origin` header is `http` or
  `https` and matches the request's public address:

  - scheme: the first `X-Forwarded-Proto` value if present, otherwise the
    scheme the server received;
  - host and port: any of the `Host` header, the first `X-Forwarded-Host`
    value, or the server's own view of the request. A missing port means the
    default port of the origin's scheme.

  Through a proxy that terminates TLS, `https://app.example.com` therefore
  matches `Host: app.example.com` with `X-Forwarded-Proto: https`. A missing,
  `null`, other-host, other-port or other-scheme origin is refused.~~ Retired:
  there is no POST to protect. RECOVER-13 states the same rule again for the
  POST this page has now.

## Implementation

`EliaWeb.Recovery` (the plug and its own template: plain HTML, no layout, no
bundle), the plug it adds to `lib/elia_web/endpoint.ex`, `Elia.Deploy`
(`loaded_revisions/1` and `last_deploy/1`, DEPLOY-23, DEPLOY-25; `rollback/3`,
DEPLOY-26), `Elia.Deploy.Runner` (the rollback as an operation it owns,
DEPLOY-16), `EliaWeb.SettingsLive` (the link and the address it names,
RECOVER-15).

## Tests

`test/elia_web/recovery_test.exs`: the page and its record (RECOVER-10,
RECOVER-11), starting a rollback (RECOVER-12), the origin rule and the
refusals (RECOVER-13, RECOVER-14). The rollback itself is
`test/elia/deployment_test.exs` (DEPLOY-26).
