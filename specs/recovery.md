# Recovery

Status: Retired

Retired: `/recover` existed for a world where the agent edited the tree the
server ran from, so a bad change could leave the app showing Phoenix's
compilation error page on every request — including the chat UI, the only way to
ask the agent for a fix — with no branch to hide behind. A chat in Elia's own
project now edits its own worktree (DEPLOY-1), and the only thing that loads
code into the running app is a deploy, which runs the full suite and a compile
first and refuses to load a tree that fails either (DEPLOY-5, HOT-4, HOT-6). So
the app cannot be left uncompilable by an agent's change, and the page's own
work had already become hollow: it rolled *files* back, and said so on its own
page, the running app only changes after a deploy (RECOVER-5) — while a deploy
refuses a live tree with uncommitted changes (DEPLOY-5), which is exactly what a
rollback leaves behind. The residual case — a live tree not yet *set up for
deployment* (DEPLOY-14), where a chat still works in the live tree itself — is a
one-time setup step (`git checkout -b live`, `git branch master`) rather than
something to keep a whole page for.

## Requirements

- ~~**RECOVER-1** When the endpoint's code reloader is on (the dev server), the
  endpoint serves `/recover` before `Phoenix.LiveReloader` and
  `Phoenix.CodeReloader`, so it answers without recompiling anything. In other
  environments the plug isn't part of the endpoint.~~ Retired: the plug is gone.
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
  there is no POST to protect.

## Out of scope

(Retired with the feature: authenticating users, and choosing individual files
to restore.)

## Implementation

Removed: `EliaWeb.Recovery`, its plug wiring in `lib/elia_web/endpoint.ex` and
its `:checkpoints` option. `Elia.Skills.reload/0` is unaffected.

## Tests

`test/elia_web/recovery_test.exs` is removed.
