# Socket origin

Status: Implemented

Elia has no authentication, and this spec is not one: anyone who can reach the
app can fetch its pages and use it. What it bounds is a *page*. A socket
handshake is the one request a browser sends to another origin without asking
to be allowed to read the answer, so a page on any other site — any page the
user's browser visits — could open a WebSocket to Elia, and the app answered it
as it answers its own page. An ordinary `GET` is not exposed the same way: the
browser withholds the response from a foreign page, and the app's own pages are
behind nothing else. So the sockets, and only the sockets, need a binding, and
it is a binding rather than a login: what a connection proves is that the page
came from this server, never who is using it.

The socket transport is Phoenix's, at `/live` and `/terminal`
([TERM-12](terminal.md)), and it is configured once, on the endpoint, for both
of them.

## Requirements

- **SOCK-1** A socket handshake is accepted only from a page this server served:
  the request's `Origin` header must name the host, scheme and port the request
  itself arrived at. Both of the app's sockets — the LiveView's `/live` and the
  terminal's `/terminal` — are bound by it, in every environment the server runs
  in, and a request whose `Origin` names anything else is refused before the
  socket's own `connect/3` runs.
- **SOCK-2** A handshake that carries no `Origin` header at all is not refused
  for that reason: it is not a page, and what bounds it is SOCK-3 where a proof
  is required.
- **SOCK-3** The terminal socket requires a session proof: the handshake must
  present the CSRF token of a session this server issued, and
  `EliaWeb.TerminalSocket`'s `connect/3` refuses a connection whose
  `connect_info.session` is nil — a proof that is missing, stale, or issued to a
  session whose token does not match. Where SOCK-1 judges a browser, this is
  what refuses a client that never fetched a page from this server.
- **SOCK-4** An install served under an origin the request does not carry — a
  proxy that terminates TLS, or one that rewrites the hostname — names its
  origins in `ELIA_ALLOWED_ORIGINS`, a comma-separated list of origins, and a
  handshake whose `Origin` is one of them is accepted in place of SOCK-1's host
  binding. With none named, SOCK-1's host binding is the whole policy.
- **SOCK-5** The app's own pages are unaffected: a browser that loaded a page
  from this server, at the address it loaded it from, connects to both sockets
  with nothing to configure, and the terminal page's hook sends the proof of
  SOCK-3 with its handshake.

## Configuration

```elixir
# config/runtime.exs — the origin a socket handshake is judged by. The policy
# (EliaWeb.SocketOrigin.check_origin/0) is SOCK-1's host binding unless
# ELIA_ALLOWED_ORIGINS names origins (SOCK-4).
config :elia, EliaWeb.Endpoint, check_origin: EliaWeb.SocketOrigin.check_origin()
```

`ELIA_ALLOWED_ORIGINS` is a comma-separated list —
`https://elia.example.com,//elia.example.com` — and each entry is an origin, a
host, or a host with wildcards (`//*.example.com`), as the endpoint's
`check_origin` option reads them.

## Out of scope

- **Authentication, accounts or per-chat permissions.** The binding says a page
  came from this server; it says nothing about who is using it. Anyone who can
  reach the app can fetch a page, take the proof it carries and open a terminal
  in any chat's workspace — [TERM](terminal.md)'s `Out of scope` stands.
- **Trusting a proxy's forwarded headers.** `X-Forwarded-Proto` is not read to
  reconstruct the client's own scheme, which is what would make SOCK-1's binding
  see through a TLS-terminating proxy. Such an install names its origins instead
  (SOCK-4).
- **A proof on the LiveView socket** beyond SOCK-1's origin binding: what a
  LiveView does with its session is Phoenix LiveView's own, and the terminal is
  the socket that runs a process tree.

## Stored data

Nothing. The policy is configuration, read at boot, and the proof is what the
app already issued before this change — the session cookie the browser pipeline
sets and the `csrf-token` meta tag the root layout renders
(`lib/elia_web/components/layouts/root.html.heex`), which the socket clients
already send as `_csrf_token`. No setting, saved chat, session field or file
changes shape, so nothing is written differently and no migration is needed.

## Implementation

- `EliaWeb.SocketOrigin` — the policy a handshake is judged by, and the origin
  list `ELIA_ALLOWED_ORIGINS` is read into (SOCK-1, SOCK-4).
- `config/runtime.exs` — the endpoint's `check_origin`, in every environment;
  `config/dev.exs` no longer turns it off.
- `lib/elia_web/endpoint.ex` — the two sockets and what they know about the
  connection (the session, SOCK-3).
- `lib/elia_web/terminal_socket.ex` — the proof of SOCK-3, refused in
  `connect/3`.
- `assets/js/terminal.js` — the `_csrf_token` the page sends with its handshake
  (SOCK-5).

## Tests

`test/elia_web/socket_origin_test.exs` covers SOCK-1 to SOCK-5 at the transport:
a handshake from a foreign origin is refused, one from the app's own origin
without a proof is refused, one with a token that does not match its session is
refused, one from the app's own page — the CSRF token and the session cookie the
page it rendered carries — is upgraded, and `ELIA_ALLOWED_ORIGINS` is read into
the policy it claims to (SOCK-4). `test/elia_web/terminal_channel_test.exs`
covers the join path a connected socket takes (TERM-12..TERM-18) and
`test/elia_web/browser/terminal_test.exs` the whole handshake in a real browser
(BROWSER-1).
