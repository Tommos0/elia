# Notifications

Status: Retired

Retired: the app no longer keeps a record of what happened. The header's bell
and the list behind it — an entry per chat that needed the user, unread until
they looked — are replaced by the live list of the chats that are still open
(`specs/active-chats.md`, ACTIVE), which counts the ones waiting for the user
from the chats themselves rather than from a record of events. What the list
answered is answered by the chats' own statuses, so nothing is recorded and
nothing has to be read: the entry, its reason, its unread flag and the 50-entry
history are gone with it.

Web Push is untouched: a chat that needs the user still notifies the device
(`specs/push-notifications.md`, PUSH), on the same events (PUSH-11, PUSH-12),
and the rule that a chat in front of the user is not pushed to is still
`Elia.Push.Viewers`'s (PUSH-13, PUSH-24). The settings key the list was stored
under is no longer read or written.

## Requirements

- ~~**NOTIF-1** A chat that starts to need the user is recorded in the
  notification list: its status becomes `awaiting_approval` (APPR-3, UI-58) or
  `awaiting_input` (ASK-3, UI-76), or a turn of it that was `running` ends, as
  `idle` (the model finished, LOOP) or `paused` (a limit, LIMIT-5) — the same
  events a push notification is sent for (PUSH-11, PUSH-12). Recording happens
  whether or not any device is subscribed and whether or not this browser can
  push, since the list is Elia's own.~~ Retired: the header counts the chats
  that are waiting now (ACTIVE-3, ACTIVE-7) rather than recording the moment
  they started to wait.
- ~~**NOTIF-2** An entry holds what the notification is about: the chat's id,
  the chat's title as it is at that moment (TITLE-1, and the same fallback push
  uses when it has none), the reason it needs the user — approval, input,
  finished or paused (NOTIF-1) — and the moment it was recorded.~~ Retired:
  there are no entries; a row names the chat and the project it belongs to
  (ACTIVE-5).
- ~~**NOTIF-3** The list holds the newest 50 entries: recording one when it is
  full drops the oldest, so the list stays a short record of what happened
  rather than growing without end.~~ Retired: nothing accumulates, so nothing
  has to be capped; the menu lists the newest 50 active chats and names the
  rest (ACTIVE-4).
- ~~**NOTIF-4** An entry recorded while a page for that chat is in front of the
  user is recorded as read, and any other entry is recorded unread: the same
  rule that keeps a push from arriving for the chat the user is already reading
  (PUSH-13, PUSH-24) keeps the count at zero for a chat they are watching.~~
  Retired: nothing is recorded and nothing is read; a chat in front of the user
  is counted like any other, and the count falls when its turn runs or it is
  marked done (ACTIVE-3).
- ~~**NOTIF-5** The header of every page carries a bell button
  (`#notifications-toggle`), after the page links at the right-hand end, with
  the number of unread entries (`#notifications-count`) and `aria-expanded` and
  `aria-controls` for the menu it opens (NOTIF-6); a list with nothing unread
  shows the bell without a count.~~ Retired: the header's control is the active
  chats one (ACTIVE-1).
- ~~**NOTIF-6** The bell opens a menu (`#notifications-menu`) listing the entries
  newest first, each with the chat's title, the reason it needs the user
  (NOTIF-2) and when it was recorded as a relative time (MSGAT), and marking
  the entries that are unread as unread. The bell opens and closes the menu and
  never navigates; a backdrop (`#notifications-backdrop`) or the Escape key
  closes it (UI-36).~~ Retired: the menu lists the active chats and what each
  one is doing now (ACTIVE-5).
- ~~**NOTIF-7** An entry is a link to the page of the chat it is about
  (`/c/<id>`, UI-8); following it is arriving at that chat, which reads the
  entry (NOTIF-8).~~ Retired: a row links to its chat (ACTIVE-5) and there is
  nothing to read on arrival.
- ~~**NOTIF-8** Opening a chat's page marks every entry for that chat read, so
  arriving at a chat another way than through its entry — the chat list, the
  drawer, a pushed notification, a URL — clears it just the same.~~ Retired:
  no entry is kept, so arriving at a chat has nothing to clear.
- ~~**NOTIF-9** The menu offers "Mark all as read" (`#notifications-mark-read`),
  which marks every entry read, and "Clear" (`#notifications-clear`), which
  empties the list.~~ Retired: the list is what is open now, so there is nothing
  to mark read or to clear.
- ~~**NOTIF-10** The count and the menu follow the store without a reload: an
  entry recorded while a page is open raises the count on that page and appears
  at the top of the menu, and anything that marks entries read or clears them —
  this page's own controls, another page or another device — lowers it. A page
  that opens shows the list as it is stored.~~ Retired: the count and the menu
  follow the chats themselves without a reload (ACTIVE-7).
- ~~**NOTIF-11** A list with no entries says so in the menu
  (`#notifications-empty`) rather than showing an empty menu.~~ Retired: a menu
  with no active chat says so (ACTIVE-6).
- ~~**NOTIF-12** Entries are kept in the settings database (`Elia.Settings`)
  under one key, and every change to them — a recording, a marking read, a
  clear — is one update of that key (CONF-29), so changes that overlap all take
  effect in one order and none is lost. The list is there after a restart, and a
  store without the key reads as an empty list.~~ Retired: nothing is stored;
  the active chats are read from the chats and the running sessions when they
  are drawn (ACTIVE-2, ACTIVE-3).
- ~~**NOTIF-13** The list is one list for the whole app, not one per project,
  chat or browser, and an entry outlives the chat it is about: it keeps the
  title it recorded (NOTIF-2), and each event is an entry of its own, so a chat
  that needed the user twice has two.~~ Retired: the list is one list for the
  whole app still (ACTIVE-2), but it holds the chats that are open rather than
  what happened to them, so it does not outlive the chat it names.

## Stored data

The list's settings key (NOTIF-12) is no longer read or written: a database
that still holds it keeps it, nothing reads it, and no migration is needed. The
key can be left where it is; it is dead data rather than a shape that has to
change.

## Implementation

Removed: `Elia.Notifications` and `Elia.Notifications.Recorder` (and its child
in `Elia.Application`), `EliaWeb.Notifications` and the marking of a chat's
entries read in `EliaWeb.ChatLive`. The header's control and its menu are
`EliaWeb.ActiveChats` and `EliaWeb.Layouts` (ACTIVE).

## Tests

Removed: the two test files that covered the list and the header's bell. The
control that replaced them is covered by
`test/elia_web/live/active_chats_test.exs` (ACTIVE).
