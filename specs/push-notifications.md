# Push notifications

Status: Implemented

Elia can tell the user's device that a chat needs them, so they can put the
phone down instead of watching a long turn. It uses Web Push: the browser makes
a subscription for the app's VAPID key, the server keeps that subscription, and
when a chat's status changes the server encrypts a small payload for the
subscription and POSTs it to the subscription's push service endpoint
(RFC 8030, RFC 8291, RFC 8292). A notification names the chat and why it needs
you; a new one for the same chat replaces the previous one instead of stacking.

Two things are prerequisites rather than features: the page must be on a secure
origin — HTTPS or `localhost` (PWA-3), so push is not available on a plain HTTP
LAN address — and the server must be able to reach the push service. Delivery
itself is best-effort: the notification travels through a push service the user
does not control, and shows up when the browser (or the installed app, PWA-1)
next receives it. Registration rides on the existing service worker (PWA-4).

## Requirements

- **PUSH-1** A VAPID key pair (P-256) is generated on first use and kept in the
  settings database (`Elia.Settings`); every later subscription uses the same
  pair, so subscriptions made before a restart keep working.
- **PUSH-2** The Settings page has a push section (`#push-section`) — the
  section of CONF-25, collapsed by default — that carries the app's VAPID public
  key, URL-safe base64 without padding, for the page's JavaScript, and it is the
  only place a subscription is made. The section's hook runs from the page's
  load whether or not the section is expanded, so what it finds is there when
  the section is opened.
- **PUSH-3** Turning the push section's switch (`#push-toggle`) on asks the
  browser for notification permission, subscribes with the app's key, and stores
  the subscription's `endpoint`, `p256dh` and `auth` on the server, keyed by
  endpoint: subscribing an endpoint that is already stored replaces that entry
  rather than adding a second one.
- **PUSH-4** The switch reads as on exactly when the browser holds a
  subscription (it is off again after the page subscribes and reloads), and
  turning it off unsubscribes in the browser and removes that endpoint from the
  store.
- **PUSH-5** A browser that cannot push — no service worker, no `PushManager`,
  or notification permission denied — shows why in the section
  (`#push-reason`) instead of the switch, and asks for nothing.
- **PUSH-6** A page on an insecure origin (`window.isSecureContext` false, e.g.
  plain HTTP on a LAN address) shows that notifications need HTTPS or
  `localhost` (PWA-3) instead of the switch.
- **PUSH-7** The section says how many subscriptions are stored
  (`#push-count`) and offers "Remove all" (`#push-remove-all`), which deletes
  them: a subscription that belongs to a device that is gone can't be removed
  from that device any more.
- **PUSH-8** The section offers "Send a test notification"
  (`#push-send-test`), which sends the same kind of message as a chat's
  notification does (title "Elia", a body that says it is a test, the
  dashboard's URL), and the page then reports what happened
  (`#push-status`): accepted by the push service, or that subscription is gone
  and was removed (PUSH-16).
- **PUSH-9** The payload of a notification is a JSON object with `title`,
  `body`, `url`, `tag` and `icon`; `tag` identifies what the notification is
  about — a chat's own notification is tagged for that chat — so a new one for
  the same chat replaces the previous one instead of piling up.
- **PUSH-10** The service worker (PWA-4) answers a `push` event by showing a
  notification with the payload's `title`, `body`, `icon` and `tag`, and a
  `notificationclick` event by focusing an open tab on the payload's `url` — or
  opening a window there, for an app that is closed — and closing the
  notification.
- **PUSH-11** A notification is sent when a chat's status becomes
  `awaiting_approval` (APPR-3, UI-58) or `awaiting_input` (ASK-3, UI-76): the
  title is the chat's own title (TITLE-1), the body says what it waits for, and
  the URL is that chat's page.
- **PUSH-12** A notification is sent when a chat's turn ends: the status goes
  from `running` to `idle` (the model finished, LOOP) or to `paused` (a limit,
  LIMIT-5), with the chat's title and how it ended in the body.
- **PUSH-13** No notification is sent for a chat while a connected page for that
  chat is visible: a page that is hidden or in a background tab counts as not
  looking at it.
- **PUSH-14** A chat page tells the server whether it is visible when it mounts
  and whenever that changes, and a page that goes away stops counting, so a
  closed or reloaded page leaves nothing behind.
- **PUSH-15** A push request carries the VAPID authorization header of
  RFC 8292 — an ES256 JWT whose `aud` is the endpoint's origin, `sub` the
  configured contact (PUSH-18) and `exp` no more than 24 hours away — and a body
  that is the payload encrypted for that subscription (RFC 8291, `aes128gcm`
  content coding), so the push service itself cannot read it.
- **PUSH-16** A push service that answers 404 or 410 deletes that subscription
  from the store; any other failure is logged and changes nothing.
- **PUSH-17** Sending is best-effort and never blocks or fails its caller: a
  turn that ends, a page that renders and a settings change each do the same
  whether the send worked, failed or there is nothing to send to.
- **PUSH-18** The VAPID contact (`sub`) is configurable (`PUSH_SUBJECT`) and
  defaults to a `mailto:` URL, which push services accept.
- **PUSH-19** The section never sits at "Checking this browser…": where a
  service worker has not become active — the app's own registration failed, as
  when an auth proxy answers `/sw.js` with its login page (PWA-5), or nothing
  registered in a few seconds — it says so in `#push-reason`, naming the
  worker, and offers no switch. If the worker does become active later, the
  section reads the browser again by itself, so the switch appears without a
  reload.
- **PUSH-20** The section settles whatever happens: within a few seconds of its
  script running it either offers the switch or shows a reason, and a failure
  of its own reading of the browser — an exception from the browser's own API,
  say — is reported in `#push-reason` rather than swallowed, so "Checking this
  browser…" is never the last word. A section whose markup the server has
  replaced or patched goes back to saying what it found (PUSH-21), since the
  replacement takes the section's own answer with it.
- **PUSH-21** The section reads the browser again by itself when the page
  becomes visible again, and while it has not settled, so a section left stale
  by a page that sat in the background is corrected without a reload.
- **PUSH-22** A page whose LiveView has not connected yet says so in
  `#push-reason` — this page has not reached the server, so nothing has been
  read — instead of claiming to check the browser. A phone has no console, so
  the section saying which of the two it is doing is how a stack that stalls
  before any of its JavaScript runs can be told apart from one that fails in
  the reading.
- **PUSH-23** A reason takes the switch's place only: how many subscriptions
  are stored (PUSH-7), "Send a test notification" (PUSH-8) and "Remove all"
  (PUSH-7) stay reachable beside it, because they are about the server rather
  than about this browser. A phone whose section cannot read the browser can
  still send a test notification and clear a device that is gone.

- **PUSH-24** A page is in front of the user only while it says so, and it says
  so on the events that mean that changed — `visibilitychange` (another tab, the
  app backgrounded, the screen locked), `focus` and `blur` (another window) and
  `pagehide` — with no heartbeat and no grace period: a page that is hidden or
  unfocused stops counting at once (PUSH-13), and a page that goes away leaves
  nothing behind (PUSH-14). Walking away from a page that keeps its focus has no
  event, so it is not detected — and a page left focused on one device keeps the
  chat suppressed on every device, as PUSH-13 says.

## Configuration

- `PUSH_SUBJECT` — the contact put in the VAPID JWT (PUSH-18), e.g.
  `mailto:me@example.com`. Read at runtime (`config/runtime.exs`), like the API
  keys (CONF).

## Out of scope

- Choosing *what* notifies (per chat, per event, quiet hours): one setting, and
  every event of PUSH-11 and PUSH-12.
- Delivery receipts, a history of what was sent, and retrying a failed send.
- Managing a single subscription from the UI (only "remove all", PUSH-7).
- Notifications for a sub-task chat's own progress (SUBTASK), and for anything
  other than a chat needing the user.
- Notifications shown by the page itself rather than the service worker: every
  notification is the worker's (PUSH-10), so it also arrives with the app
  closed.
- Offline queueing: a push is sent when the event happens, from a server that
  must be able to reach the push service.

## Implementation

- `Elia.Push` — the VAPID key pair (PUSH-1, generated with `:crypto` and kept in
  `Elia.Settings`), sending a payload to a subscription (PUSH-15, PUSH-16,
  PUSH-17), and the test notification (PUSH-8). Encryption and the VAPID JWT
  come from the `web_push` hex package (RFC 8291/8292); its Finch pool is the
  one `Req` already brings.
- `Elia.Push.Subscriptions` — the stored subscriptions: add/replace-by-endpoint
  (PUSH-3), remove (PUSH-4, PUSH-7), remove-gone (PUSH-16), count (PUSH-7).
- `Elia.Push.Notifier` — subscribes to the activity topic
  (`Elia.Agent.subscribe_activity/0`, the `{:chat_status, id, status}` of
  SESS-19) and sends on the transitions of PUSH-11 and PUSH-12, unless a page
  that is in front of the user is on that chat (PUSH-13, PUSH-24).
- `Elia.Push.Viewers` — which chats have a page in front of the user, kept from
  the chat LiveView's mount, its visibility reports and its exit (PUSH-13,
  PUSH-14, PUSH-24).
- `EliaWeb.SettingsLive` — the push section (PUSH-2, PUSH-5–PUSH-8, PUSH-19)
  and a colocated hook (`.PushSettings`) for permission, subscribing, the test
  button and reporting, since this project keeps client code in colocated hooks
  rather than in `assets/js/`. The hook settles by itself and reports its own
  failures (PUSH-20), re-reads as the page comes and goes (PUSH-21), and the
  server controls sit beside a reason rather than under it (PUSH-23); the page
  before it has connected says so (PUSH-22), as only the server can tell.
- `assets/js/app.js` — the service worker registration (PWA-5) and the failure
  it leaves behind for the section to report (PUSH-19).
- `EliaWeb.ChatLive` — reports visibility (PUSH-14) on the events of PUSH-24.
- `priv/static/sw.js` — `push` and `notificationclick` handlers (PUSH-10).

## Tests

- `test/elia/push_crypto_test.exs` — the key pair (PUSH-1), the RFC 8291
  section 5 vector for the encrypted body, the VAPID JWT verified through its
  own signature, and a subscription that is not usable (PUSH-15).
- `test/elia/push_test.exs` — the key pair generated once and kept (PUSH-1),
  the payload a chat's notification carries (PUSH-9), the request's headers and
  the payload a browser decrypts out of the body (PUSH-15), 404/410 removing a
  subscription (PUSH-16), a failure being counted and logged rather than raised
  (PUSH-17), `notify/1` sending off the caller's process (PUSH-17) and the test
  notification (PUSH-8), with the VAPID contact it sends (PUSH-18).
- `test/elia/push_subscriptions_test.exs` — storing a subscription, replacing
  one by endpoint, refusing an unusable one (PUSH-3), removing one (PUSH-4,
  PUSH-16), counting and clearing them (PUSH-7).
- `test/elia/push_notifier_test.exs` — the status changes that notify and the
  ones that don't (PUSH-11, PUSH-12), suppression by a page in front of the user
  (PUSH-13), and a send from a status broadcast all the way to the decrypted
  payload.
- `test/elia_web/live/settings_live_test.exs` — the section's key (PUSH-2), a
  subscription the page reports being stored and counted, one that is refused
  (PUSH-3), unsubscribing one device (PUSH-4), "remove all" (PUSH-7), what
  the test notification reports (PUSH-8), and the page before it has connected
  saying so, with a reason still leaving the server's own controls in place
  (PUSH-22, PUSH-23).
- `test/elia_web/live/push_visibility_test.exs` — a chat page reporting its
  visibility, a page that goes away stopping, a page that reports itself
  unfocused stopping (PUSH-24), and no notification for the chat a page is in
  front of (PUSH-13, PUSH-14).
- `test/elia_web/browser/push_test.exs` — the hook in a real browser: the
  switch where the browser can notify and the reason where it cannot (PUSH-2,
  PUSH-5), the section settling again once the server has rendered it again and
  reporting a reading that failed (PUSH-20, PUSH-21), what a reason leaves in
  place (PUSH-23), the events the chat page reports on (PUSH-14, PUSH-24) and the
  reason a service worker that never activates leaves behind (PUSH-19). Run
  explicitly, like the other browser tests (BROWSER).
- Not covered by an automated test, and checked by hand as PWA-5 is: making a
  real subscription and receiving a notification end to end, which needs a
  browser with notifications on and its own push service on the internet
  (PUSH-3, PUSH-4, PUSH-10), and the insecure-origin reason of PUSH-6, which
  needs an origin that is not `localhost`.
