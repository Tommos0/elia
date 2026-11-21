# Active chats

Status: Draft

The header's bell was a record of what had already happened: an entry per chat
that had needed the user, kept in a list of its own (`specs/notifications.md`,
retired). This is the live form of the same question — which chats are still
open, and which of them are waiting for me — answered from the chats themselves
rather than from a record of events. Every page's header carries a control that
counts the chats needing the user and opens a list of the active chats across
every project, each row a link to the chat. A chat is active while it is saved
and not marked done, so the list is what is still going on rather than what
happened; a chat is counted while no turn of it is running — its turn finished,
or it is asking for approval, an answer, or a decision about a limit or a
restart that cut its turn short — so a chat the agent is working on is listed
without being counted.

## Requirements

- **ACTIVE-1** The header of every page carries an active chats control
  (`#active-chats-toggle`), after the page links at the right-hand end, with the
  number of chats needing the user (`#active-chats-count`) and `aria-expanded`
  and `aria-controls` for the menu it opens (ACTIVE-5); with no chat needing the
  user the control shows no count.
- **ACTIVE-2** A chat is active while it is saved (STORE-1) and not marked done
  (DONE-1, STORE-35), whatever project it belongs to (PROJ-9) and whether or not
  it is a task chat (STORE-17). The list holds the active chats of every
  project, newest first (STORE-12).
- **ACTIVE-3** A chat needs the user while it is active (ACTIVE-2) and no turn
  of it is running: its status (UI-46, UI-59) is `idle`, `awaiting_approval`,
  `awaiting_input`, `paused` or `interrupted`. A chat whose turn is running
  (`working`) does not need the user, and a chat marked done (DONE-2) is not
  active at all. The count (ACTIVE-1) is the number of chats needing the user,
  over every active chat rather than only the ones the menu lists (ACTIVE-4).
- **ACTIVE-4** The menu lists the newest 50 active chats (ACTIVE-2), newest
  first, and names how many more there are (`#active-chats-more`) when more
  chats are active than it lists.
- **ACTIVE-5** The control opens a menu (`#active-chats-menu`) listing the
  active chats (ACTIVE-4), each one a row with the chat's title (STORE-33), the
  name of the project it belongs to (PROJ-9, Elia's own project for a chat with
  none) and its status (UI-46, UI-59, the same indicator the chat list draws),
  and each row a link to that chat's page (`/c/<id>`, UI-2). The control opens
  and closes the menu and never navigates; a backdrop (`#active-chats-backdrop`)
  or the Escape key closes it (UI-36).
- **ACTIVE-6** A list with no active chats says so (`#active-chats-empty`)
  rather than showing an empty menu.
- **ACTIVE-7** The count and the menu follow the chats while a page is open,
  without a reload: a chat whose status changes (SESS-19) enters the list,
  leaves it or changes what it shows as it happens — a turn starting (`working`)
  lowers the count, a turn ending, a tool call awaiting approval (APPR-3) or a
  question awaiting an answer (ASK-3) raises it, and a turn paused at a limit
  (LIMIT-5) or cut short by a restart (STORE-31) is counted — a chat marked done
  (SESS-35, DONE-1) or reopened leaves or enters the list, and a chat that is
  deleted (SESS-48) leaves it. A page that opens shows the chats as they are
  saved.

## Out of scope

- A page of its own for the active chats, filtering, searching, paging beyond
  the 50 of ACTIVE-4, nesting a task chat under its parent (UI-45), and any
  order but the STORE-12 one.
- Acting on a chat from the menu — stopping it, approving a tool call,
  answering a question or resuming a paused turn (SESS-27, ASK-3): a row is a
  link to the chat, and the dashboard's attention card is where the user is told
  what a chat wants (DASH-5).
- What a chat's status means and how it is derived (UI-46, UI-59, UI-72): the
  menu draws the one indicator the chat list draws.
- Push notifications (PUSH), the settings page's controls for them and the
  notification list this replaces (NOTIF, retired): whether a device is notified
  is not this feature.
- A user-set rule for what counts as needing the user, or a per-project or
  per-chat switch for it.

## Stored data

Nothing new is stored: the list and the count are derived from the saved chats
(STORE-1), the running sessions (SESS-19) and the projects file (PROJ), and
nothing about them is written. The settings key the retired notification list
used (NOTIF-12) is no longer read or written — a database that still holds it
keeps it, nothing reads it, and nothing has to be migrated.

## Implementation

- `EliaWeb.ActiveChats` — the control's state and events on every page of the
  live session, as `EliaWeb.ChatList` holds the chat list's (`on_mount/4` with
  the state assigned and `attach_hook/4` for its events, registered beside it in
  `EliaWeb.Router`'s `live_session`), so a page gets the control without wiring
  of its own. It reads the chats from `Elia.Store.list/2` (STORE-12, STORE-52),
  the statuses from the registry (`Elia.Agent.awaiting_approval/0`,
  `awaiting_input/0`, `paused/0`, `running/0`) and the record a restart left
  behind (STORE-31), and follows the activity topic
  (`Elia.Agent.subscribe_activity/0`) for ACTIVE-7.
- `EliaWeb.Layouts` — the control and its menu in the header, drawn from that
  state (ACTIVE-1, ACTIVE-5, ACTIVE-6), which is what keeps it on every page.
- `Elia.Agent` — announces a chat's deletion on the activity topic as
  `{:chat_deleted, id}` (SESS-48), which is how a chat deleted on one page
  leaves the list on another; `EliaWeb.ChatLive` and `EliaWeb.DashboardLive`
  ignore or follow that event.
- Removed: `Elia.Notifications`, `Elia.Notifications.Recorder` and its child in
  `Elia.Application`, `EliaWeb.Notifications`, the marking of a chat's entries
  read in `EliaWeb.ChatLive`, and the notification list's tests.

## Tests

- `test/elia_web/live/active_chats_test.exs` — the control on a page that keeps
  no chat list of its own, with the count of the chats needing the user and
  without one when none does (ACTIVE-1, ACTIVE-3); the menu's rows, their order
  across projects and what each names (ACTIVE-2, ACTIVE-4, ACTIVE-5); a working
  chat listed and not counted, and a done chat in neither (ACTIVE-2, ACTIVE-3);
  a row following to its chat (ACTIVE-5); the menu saying no chat is active
  (ACTIVE-6); the cap and "and N more" (ACTIVE-4); and the count and the menu
  following a status change, a chat marked done and a chat deleted while the
  page is open (ACTIVE-7).
- `test/elia/agent_test.exs` — deleting a chat announces it on the activity
  topic (SESS-48).
