# Notifications

Status: Implemented

Elia already tells the user's device that a chat needs them, over Web Push
(`specs/push-notifications.md`). That message is best-effort and gone once it is
shown: it needs a subscription, a secure origin and a server that can reach the
push service, and nothing is left behind once it has passed. This is the other
half — the notifications Elia keeps itself, in a list the app shows: every chat
that started to need the user is recorded, and the header's bell carries the
number of them the user has not seen, with the list itself in a menu behind it.
So a user who was away finds out what happened while they were, on any device
and without push being set up at all.

The events are exactly the ones push notifies on (PUSH-11, PUSH-12), because
they are the same thing said two ways: the push leaves the server, the entry
stays in it. Reading an entry is the user's own act — following it to the chat
it is about, or saying they have seen them all — and never something the store
decides on its own, with one exception: a chat that is in front of the user when
it needs them does not become unread mail (PUSH-13, PUSH-24).

## Requirements

- **NOTIF-1** A chat that starts to need the user is recorded in the
  notification list: its status becomes `awaiting_approval` (APPR-3, UI-58) or
  `awaiting_input` (ASK-3, UI-76), or a turn of it that was `running` ends, as
  `idle` (the model finished, LOOP) or `paused` (a limit, LIMIT-5) — the same
  events a push notification is sent for (PUSH-11, PUSH-12). Recording happens
  whether or not any device is subscribed and whether or not this browser can
  push, since the list is Elia's own.
- **NOTIF-2** An entry holds what the notification is about: the chat's id, the
  chat's title as it is at that moment (TITLE-1, and the same fallback push
  uses when it has none), the reason it needs the user — approval, input,
  finished or paused (NOTIF-1) — and the moment it was recorded.
- **NOTIF-3** The list holds the newest 50 entries: recording one when it is
  full drops the oldest, so the list stays a short record of what happened
  rather than growing without end.
- **NOTIF-4** An entry recorded while a page for that chat is in front of the
  user is recorded as read, and any other entry is recorded unread: the same
  rule that keeps a push from arriving for the chat the user is already reading
  (PUSH-13, PUSH-24) keeps the count at zero for a chat they are watching.
- **NOTIF-5** The header of every page carries a bell button
  (`#notifications-toggle`), after the page links at the right-hand end, with
  the number of unread entries (`#notifications-count`) and `aria-expanded` and
  `aria-controls` for the menu it opens (NOTIF-6); a list with nothing unread
  shows the bell without a count.
- **NOTIF-6** The bell opens a menu (`#notifications-menu`) listing the entries
  newest first, each with the chat's title, the reason it needs the user
  (NOTIF-2) and when it was recorded as a relative time (MSGAT), and marking
  the entries that are unread as unread. The bell opens and closes the menu and
  never navigates; a backdrop (`#notifications-backdrop`) or the Escape key
  closes it (UI-36).
- **NOTIF-7** An entry is a link to the page of the chat it is about
  (`/c/<id>`, UI-8); following it is arriving at that chat, which reads the
  entry (NOTIF-8).
- **NOTIF-8** Opening a chat's page marks every entry for that chat read, so
  arriving at a chat another way than through its entry — the chat list, the
  drawer, a pushed notification, a URL — clears it just the same.
- **NOTIF-9** The menu offers "Mark all as read" (`#notifications-mark-read`),
  which marks every entry read, and "Clear" (`#notifications-clear`), which
  empties the list.
- **NOTIF-10** The count and the menu follow the store without a reload: an
  entry recorded while a page is open raises the count on that page and appears
  at the top of the menu, and anything that marks entries read or clears them —
  this page's own controls, another page or another device — lowers it. A page
  that opens shows the list as it is stored.
- **NOTIF-11** A list with no entries says so in the menu
  (`#notifications-empty`) rather than showing an empty menu.
- **NOTIF-12** Entries are kept in the settings database (`Elia.Settings`)
  under one key, and every change to them — a recording, a marking read, a
  clear — is one update of that key (CONF-29), so changes that overlap all take
  effect in one order and none is lost. The list is there after a restart, and a
  store without the key reads as an empty list.
- **NOTIF-13** The list is one list for the whole app, not one per project,
  chat or browser, and an entry outlives the chat it is about: it keeps the
  title it recorded (NOTIF-2), and each event is an entry of its own, so a chat
  that needed the user twice has two.

## Out of scope

- Choosing what is recorded: one list, and every event of NOTIF-1.
- A notifications page of its own, grouping, filtering or searching the list,
  and any detail of an entry beyond NOTIF-2 — the chat's transcript is the
  record of what happened.
- Whether a push was sent for an event, and to how many devices (PUSH-16,
  PUSH-17): the list is what Elia knows, not what a push service did.
- The push test notification (PUSH-8), which is about push rather than about a
  chat needing the user, and anything other than a chat needing the user — a
  sub-task's progress, a deploy, a failed test run.
- Sound, vibration, a toast in the page or a browser notification drawn by the
  page itself: an entry is a line in the menu.
- Clearing an entry because the user dealt with the chat: only NOTIF-7 to
  NOTIF-9 read entries.

## Stored data

The list is a new key in the settings database (`Elia.Settings`), holding a list
of entry maps (NOTIF-2), newest first. Backward compatible: a database written
before this feature has no such key, which reads as an empty list (NOTIF-12), so
nothing has to be migrated. Nothing else that outlives the process changes.

## Implementation

- `Elia.Notifications` — the stored list and what can be done to it: read it and
  count the unread (NOTIF-5, NOTIF-10), record an entry (NOTIF-1, NOTIF-2, and
  the cap of NOTIF-3), mark one or a chat's or all of them read, and clear it
  (NOTIF-7 to NOTIF-9), each change one `Elia.Settings.update/3` of the key
  (NOTIF-12) with the entries newest first (NOTIF-13). It also announces a
  change on a PubSub topic, which is what a page listens to (NOTIF-10).
- `Elia.Notifications.Recorder` — follows the activity topic the way
  `Elia.Push.Notifier` does (`Elia.Agent.subscribe_activity/0`, the
  `{:chat_status, id, status}` of SESS-19), records on the transitions of
  NOTIF-1 and nothing else, and asks whether a page for that chat is in front of
  the user (`Elia.Push.Viewers`) for NOTIF-4.
- `EliaWeb.Notifications` — the bell's state and events on every page of the
  live session, as `EliaWeb.ChatList` holds the chat list's (`on_mount/4` with
  the state assigned and `attach_hook/4` for its events, registered beside it in
  `EliaWeb.Router`'s `live_session`), so a page gets the bell without wiring of
  its own.
- `EliaWeb.Layouts` — the bell and its menu in the header, drawn from that state
  (NOTIF-5, NOTIF-6, NOTIF-11), which is what keeps it on every page.
- `EliaWeb.ChatLive` — marks a chat's entries read as its page opens (NOTIF-8).
- `Elia.Push` — keeps the payload's wording for a reason (PUSH-11, PUSH-12); the
  list shows the same words rather than a second copy of them.
- `EliaWeb.SessionsLive`, `EliaWeb.LogsLive` and `EliaWeb.SystemLive` — gain the
  catch-all clause a page needs to ignore a message it has nothing to say about.
  Every page is subscribed to the activity topic (`EliaWeb.ChatList`, UI-47), so
  these three saw a chat's status too and crashed on it: a page that was open
  when any chat changed state died and reconnected. The bell's count could not
  follow on such a page (NOTIF-5, NOTIF-10), and the crash was there before this
  feature.

## Tests

- `test/elia/notifications_test.exs` — the events that record an entry and the
  ones that do not (NOTIF-1), the fields an entry carries (NOTIF-2), the list
  capped at its newest 50 (NOTIF-3), an entry recorded read while a page is in
  front of the user and unread otherwise (NOTIF-4), marking one, a chat's and
  all of them read and clearing the list (NOTIF-7 to NOTIF-9), recordings,
  markings and clears that overlap all taking effect in one order (NOTIF-12), a
  store without the key reading as an empty list (NOTIF-12), two entries for one
  chat and an entry that outlives its chat (NOTIF-13), and a change announced
  for a page to follow (NOTIF-10).
- `test/elia_web/live/notifications_test.exs` — the bell on a page that keeps
  no list of its own, with the count of unread and without one when nothing is
  unread (NOTIF-5), the menu's entries, their order and how it opens and closes
  (NOTIF-6), an entry following to its chat and being marked read (NOTIF-7),
  opening a chat's page marking its entries read (NOTIF-8), "Mark all as read"
  and "Clear" (NOTIF-9), the count and the menu following a recording that
  happens while the page is open (NOTIF-10), and the menu saying the list is
  empty (NOTIF-11).
