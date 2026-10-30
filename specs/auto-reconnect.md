# Auto reconnect

Status: Implemented

A tab left open (laptop asleep, phone in the background, a proxy dropping an
idle WebSocket, the server restarting) can come back with a dead LiveView
socket, so the first click fails with "socket closed" until the user
refreshes. The page recovers from this by itself: it reconnects as soon as the
tab is usable again, and if that doesn't work it reloads the page, which is
what the manual refresh did.

This is client-side JavaScript (`assets/js/auto_reconnect.js`, started from
`assets/js/app.js`). The repository has no JS test runner, so the CONN
requirements are checked by hand (see Tests).

## Requirements

- **CONN-1** When the tab becomes visible, the page is restored from the
  back/forward cache, or the browser goes back online, and the LiveView socket
  is not connected, the page drops the socket and connects again at once,
  instead of waiting for the next backoff retry.
- **CONN-2** In the same situations, if the socket reports itself connected,
  the page sends a heartbeat. If no reply arrives within 5 seconds, the
  connection is treated as dead and CONN-1's reconnect happens.
- **CONN-3** When the socket closes or errors, a stall timer starts, unless
  one is already running. It is cleared when the socket opens.
- **CONN-4** If the stall timer reaches 10 seconds and the tab is visible and
  the socket is still not connected, the page reloads. A hidden tab doesn't
  reload; it recovers through CONN-1 when it becomes visible.
- **CONN-5** Reloads are limited to 3 per minute per tab (counted in
  `sessionStorage`). Past the limit the page stops reloading and leaves the
  standard "Attempting to reconnect" banner, so a server that is down can't
  cause a reload loop.

## Out of scope

- Keeping the composer draft across a reload.
- Replaying events sent while the socket was down. LiveView already rejoins
  and re-renders the page state after a successful reconnect.

## Implementation

- `assets/js/auto_reconnect.js`: `autoReconnect(liveSocket)`.
- `assets/js/app.js`: calls it after `liveSocket.connect()`.

## Tests

Manual (no JS runner): open a chat, stop the server for 15 seconds or use
DevTools "Offline" and switch back, and check the page reconnects (CONN-1,
CONN-3) or reloads (CONN-4). `test/elia_web/auto_reconnect_test.exs` checks the
module exists, is wired into `app.js`, and carries the constants the spec
states (CONN-2, CONN-4, CONN-5).
