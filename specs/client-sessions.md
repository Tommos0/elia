# Client sessions

Status: Implemented

A Sessions page lists every browser tab that currently has Elia open, with
details about each one: IP address, browser, operating system, the page it's
on and how long it has been connected. It answers the question "who has
Elia open right now?"

"Client session" here means one connected tab. It is unrelated to agent
sessions ([Agent sessions](agent-sessions.md)), which are conversations.

## Requirements

### Tracking

- **CLIENT-1** Every connected LiveView page is tracked as a client session
  for as long as its connection is open. When the tab closes or disconnects,
  the session disappears. Requests that don't connect (the static first
  render) aren't tracked.
- **CLIENT-2** Each client session records:
  - a random id;
  - the IP address of the socket peer, formatted as IPv4 or IPv6;
  - the raw `User-Agent` header (empty if missing);
  - when it connected (UTC);
  - the path it's on.
- **CLIENT-3** When a tab changes URL inside the same LiveView (a live
  patch), its path is updated. Navigating to another LiveView ends the old
  session and starts a new one.
- **CLIENT-4** Tracking works across nodes (Phoenix Presence over
  `Elia.PubSub`).

### Sessions page

- **CLIENT-5** `/sessions` lists all client sessions, newest first, with
  a count. The page's own tab is included and marked "This tab".
- **CLIENT-6** Each row shows the browser and OS summary, the full user
  agent, the IP address, the page (a link to it; chats show their title,
  see STORE-7) and how long ago it connected.
- **CLIENT-7** The list updates live as tabs connect, disconnect or change
  page, without a reload.
- **CLIENT-8** The browser and OS summary is derived from the user agent:
  - browsers, checked in this order: Edge (`Edg/`), Opera (`OPR/`), Firefox,
    Chrome, Safari;
  - operating systems, checked in this order: Windows, iOS (`iPhone`/`iPad`),
    Android, macOS, Linux.

  Browsers show their major version when the user agent includes one. OS
  versions aren't shown: browsers freeze them (macOS always reports 10.15.7,
  Windows 11 reports 10). iOS and Android count as mobile. Unrecognised
  values show as "Unknown browser" and "Unknown OS".
- **CLIENT-9** The app header has a "Sessions" link to `/sessions`.

## Out of scope

- A history of closed sessions.
- Grouping tabs by browser or cookie session.
- Disconnecting or blocking a session.
- Access control. Elia has no authentication, so anyone who can reach the
  app can see this page and the IP addresses on it.
- `X-Forwarded-For` and other proxy headers. Behind a reverse proxy, the IP
  shown is the proxy's.

## Implementation

`EliaWeb.Presence`, `EliaWeb.ClientTracker` (an `on_mount` hook on all
LiveViews), `EliaWeb.UserAgent`, `EliaWeb.SessionsLive`.

## Tests

`test/elia_web/live/sessions_live_test.exs`, `test/elia_web/user_agent_test.exs`.
