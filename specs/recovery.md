# Recovery

Status: Implemented

In development, a bad change can leave the app showing Phoenix's compilation
error page (or a crash page) on every request, including the chat UI, which is
the only way to ask the agent for a fix. The recovery page rolls the workspace
back to a checkpoint without depending on the app: it is served before the code
reloader, so it works even when the project doesn't compile.

## Requirements

- **RECOVER-1** When the endpoint's code reloader is on (the dev server), the
  endpoint serves `/recover` before `Phoenix.LiveReloader` and
  `Phoenix.CodeReloader`, so it answers without recompiling anything. In other
  environments the plug isn't part of the endpoint.
- **RECOVER-2** `/recover` only serves local requests: the peer address is
  loopback, the `Host` header names a loopback host (`localhost`, `127.0.0.1`
  or `::1`), and the request has no forwarding header (`Forwarded`,
  `X-Forwarded-For`, `X-Forwarded-Host`, `CF-Connecting-IP`). Any other
  request gets a 403 and nothing runs.
- **RECOVER-3** `GET /recover` shows the 20 newest checkpoints (short sha,
  time, label), each with a roll-back button. The newest checkpoint taken
  before an agent turn is marked as recommended and listed first. Other
  methods get a 405.
- **RECOVER-4** `POST /recover` with a `checkpoint` field rolls the workspace
  back to that checkpoint (CKPT-5). The request needs an `Origin` header with
  the same host and port as the request, otherwise it gets a 403. The
  checkpoint must be one of the 100 newest checkpoints, otherwise it gets a
  400 and nothing runs.
- **RECOVER-5** After a successful rollback, skills are reloaded and the page
  shows the sha restored, an undo button (a rollback to the snapshot taken
  just before, CKPT-5), a link back to the app, and the guarded files whose
  changes are still unloaded, if any (GUARD-3). Without pending guarded
  changes, automatic reloading resumes on the next request (GUARD-5).
- **RECOVER-6** If the rollback fails, the page shows the error with a 500
  and the workspace is left as git left it.
- **RECOVER-7** An HTML response with status 500 to a local request (RECOVER-2)
  gets a banner at the top of `<body>`: a link to `/recover` and, if there is
  a recommended checkpoint (RECOVER-3), a button that rolls back to it. Other
  responses (other statuses, non-HTML, compressed, non-local requests) are
  left unchanged, and a failure while building the banner never changes the
  response.
- **RECOVER-8** The recovery plug uses only modules that are themselves
  guarded (`Elia.Checkpoint`, `Elia.Guarded`, `Elia.Skills`,
  `Elia.Workspace`), and is itself guarded (GUARD-1), so its running version
  stays the boot-time one while the rest of the app is broken.

## Out of scope

- Reaching `/recover` through a reverse proxy or tunnel: forwarded requests are
  refused (RECOVER-2).
- Choosing individual files to restore.

## Implementation

`EliaWeb.Recovery`, wired into `EliaWeb.Endpoint`.

## Tests

`test/elia_web/recovery_test.exs`.
