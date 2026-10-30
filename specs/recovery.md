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
- ~~**RECOVER-2** `/recover` only serves local requests.~~ Removed: recovery
  has to work through a reverse proxy or tunnel too. The app has no login of
  its own, so anyone who can reach the chat UI can already approve commands.
  Forgery protection is RECOVER-9.
- **RECOVER-3** `GET /recover` shows the 20 newest checkpoints (short sha,
  time, label), each with a roll-back button. The newest checkpoint taken
  before an agent turn is marked as recommended and listed first. Other
  methods get a 405.
- **RECOVER-4** `POST /recover` with a `checkpoint` field rolls the workspace
  back to that checkpoint (CKPT-5). The request needs a same-origin `Origin`
  header (RECOVER-9), otherwise it gets a 403. The
  checkpoint must be one of the 100 newest checkpoints, otherwise it gets a
  400 and nothing runs.
- **RECOVER-5** After a successful rollback, skills are reloaded and the page
  shows the sha restored, an undo button (a rollback to the snapshot taken
  just before, CKPT-5), a link back to the app, and the guarded files whose
  changes are still unloaded, if any (GUARD-3). Without pending guarded
  changes, automatic reloading resumes on the next request (GUARD-5).
- **RECOVER-6** If the rollback fails, the page shows the error with a 500
  and the workspace is left as git left it.
- **RECOVER-7** An HTML response with status 500 gets a banner at the top of
  `<body>`: a link to `/recover` and, if there is a recommended checkpoint
  (RECOVER-3), a button that rolls back to it. Other responses (other
  statuses, non-HTML, compressed) are left unchanged, and a failure while
  building the banner never changes the response.
- **RECOVER-8** The recovery plug uses only modules that are themselves
  guarded (`Elia.Checkpoint`, `Elia.Guarded`, `Elia.Skills`,
  `Elia.Workspace`), and is itself guarded (GUARD-1), so its running version
  stays the boot-time one while the rest of the app is broken.
- **RECOVER-9** A `POST` is same-origin when its `Origin` header is `http` or
  `https` and matches the request's public address:
  - scheme: the first `X-Forwarded-Proto` value if present, otherwise the
    scheme the server received;
  - host and port: any of the `Host` header, the first `X-Forwarded-Host`
    value, or the server's own view of the request. A missing port means the
    default port of the origin's scheme.

  Through a proxy that terminates TLS, `https://app.example.com` therefore
  matches `Host: app.example.com` with `X-Forwarded-Proto: https`. A missing,
  `null`, other-host, other-port or other-scheme origin is refused.

## Out of scope

- Authenticating users: like the rest of the dev app, `/recover` trusts
  whoever can reach it. Put access control in front of the proxy.
- Choosing individual files to restore.

## Implementation

`EliaWeb.Recovery`, wired into `EliaWeb.Endpoint`.

## Tests

`test/elia_web/recovery_test.exs`.
