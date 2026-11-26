# Chat UI

Status: Implemented

A single LiveView where the user chats with the agent, watches responses
stream in, approves or denies tool calls, and switches between saved chats.

## Requirements

### Routing

- ~~**UI-1** `GET /` navigates to `/c/<id>`: the most recently started chat that
  isn't a task chat (UI-71), or a freshly generated chat id when there is none
  (saved at once, STORE-22).~~ Retired: `/` is the dashboard now (DASH-1); what
  this described is the chat list's entry point `/chats` (UI-77).
- ~~**UI-71** Opening the chat list's entry point — `GET /`, which is the app's
  start URL (PWA-1) and the target of the header logo and of the Chats link on
  the pages that have no chat list of their own (UI-32) — resumes work rather
  than starting over: it opens the most recently
  started chat (STORE-12 order, the first one the sidebar lists) that isn't a
  task chat (STORE-17, UI-45), since a sub-task chat is reached from its
  parent's card (UI-44) and not where the user left off. Only when there is no
  such chat does `/` start a fresh one in the default project (PROJ-8). So
  browsing to `/` never leaves another empty "New chat" behind while a chat
  exists, and resuming writes nothing (STORE-22). Starting a chat stays
  explicit: the sidebar's "New chat" button (UI-31) and `/p/<id>/new`
  (PROJ-26) always start a fresh chat, and `/` does while no chat exists.~~
  Retired: `/` is the dashboard (DASH-1); the entry point that resumes work is
  `/chats` (UI-77), and the app's start URL (PWA-1) and the header logo open the
  dashboard.
- **UI-77** `/chats` is the chat list's entry point and resumes work rather than
  starting over: it opens the most recently started chat of the open project
  (PROJ-28, PROJ-31, STORE-52, in STORE-12 order, the first one the sidebar
  lists) that isn't a task chat (STORE-17, UI-45), since a sub-task chat is
  reached from its own row in the chat list (UI-45) and not
  where the user
  left off. Only when the open project has no such chat does it start a fresh
  one in it (PROJ-8), saved at once (STORE-22) — so browsing to it never
  leaves another empty "New chat" behind while a chat exists, and resuming
  writes nothing (STORE-22, STORE-29). It is where deleting the open chat lands
  (UI-65); the header's "Chats" control no longer leads here, since it opens the
  chat list's drawer instead (UI-32, UI-91). Starting a chat stays explicit: the
  sidebar's "New chat" button (UI-31), `/p/<id>/new` (PROJ-26) and the
  dashboard's (DASH-4) always start a fresh chat, and `/chats` does while no
  chat exists.
- **UI-2** `/c/<id>` opens that chat, starting its session if needed. An id
  that fails `Elia.Store.valid_id?/1` redirects to `/`, the dashboard
  (DASH-1).
- **UI-3** The page title is the chat's title (STORE-7, or the chat's own
  stored title when it has one, TITLE-1) and follows the chat when the user
  navigates between chats.

### Chat list

- **UI-4** On large screens a sidebar lists the 30 most recently started chats
  of the open project (PROJ-28, PROJ-31, STORE-12, STORE-52), newest first,
  each linking to `/c/<id>`. The open chat is highlighted. Small screens get
  the same list through a drawer (UI-36). Those 30 are the list's first page:
  while more chats of that project are saved than it lists, the list carries a
  "Load more chats" button (UI-84).
- **UI-84** The chat list shows a "Load more chats" button
  (`#load-more-chats`) below the list and outside the list's own scroll box
  (`#chat-list`), so it is visible without scrolling to the end, and it is
  shown on small screens with the drawer's list too (UI-36). It is there
  exactly while more chats of the open project are saved than the list shows
  (PROJ-28, PROJ-31) — so never with no chat saved in it (UI-5) and never once
  the list shows them all — and it never
  replaces the "No chats yet" empty state (UI-5). Clicking it lists the next
  30 chats of that project in the same order (STORE-12, STORE-52), without a
  reload, leaving the open chat, the drawer (UI-36) and the list's scroll
  position where they are; the button stays while further chats remain and is
  gone when the last page is shown. Pressing it a second time loads 30 more
  again, and so on until every chat of the project is listed.
- **UI-85** The list keeps the size the user loaded it to. The refreshes the
  sidebar does anyway — a turn starting or ending (UI-6), a task or title event
  (UI-49, UI-74), a chat marked done (UI-80), a deletion (UI-65) — leave the
  loaded pages listed, so an event never drops the user back to the first 30 and
  hides a chat they had loaded. Opening another chat does the same, although
  that mounts the page again (UI-2): the size a tab has loaded is kept in the
  browser's session storage (`elia:chat-page`, as the compact view is kept in
  local storage, UI-60) whenever UI-84's button is pressed, and the page asks
  for it when it mounts, so browsing between chats in a tab re-lists the same
  pages rather than starting over. It is an enhancement, not the working part:
  with nothing stored, or with the hook absent (a page whose assets were not
  rebuilt, HOT-8), the list is the first page (UI-4) as before, and a stored
  value that isn't a whole number of chats, or is smaller than that first page,
  is ignored, so the list never shrinks below it. A fresh browser session — a
  new tab, or storage cleared — starts at the first page again (UI-4).
- **UI-105** The chat list carries its filters at the top of the list, above the
  "New chat" button (UI-31) and the list's own scroll box (UI-92): one row
  (`#chat-filters`) of three toggle buttons, `#filter-running`, `#filter-idle`
  and `#filter-done`, one per group. Each is a button with an icon, an accessible
  name naming its group ("Running chats", "Idle chats", "Finished chats", read as
  its `title` and `aria-label`) and `aria-pressed` saying whether that group is
  shown, and all three start pressed, so a list nothing has filtered lists every
  chat it holds (UI-4) and nothing is hidden from a user who never touches them.
  The row is drawn with the list wherever the list is — the chat page's sidebar
  (UI-4) and the drawer the other pages open (UI-91, UI-92) — from the one state
  both draw (UI-92), so both have it; the drawer's copy prefixes its ids as the
  rest of its markup does (`#drawer-filter-running`).
- **UI-106** A toggle governs exactly the chats whose status indicator (UI-59)
  shows the status it names, as that status is at the moment: running hides the
  chats showing `working`, idle the ones showing `idle`, finished the ones
  showing `done`. A chat showing any other status is never hidden —
  `awaiting_approval` (UI-47), `awaiting_input` (UI-76), `paused` (UI-58) and
  `interrupted` (UI-72) — so a chat that needs the user, and one whose turn a
  restart cut short, stay listed however the filters are set. Pressing a pressed
  toggle unpresses it and the rows of that group leave the list at once, without
  a reload; pressing it again lists them again. A row is hidden and shown by its
  status at the moment, so a chat whose status changed while its group was off
  (UI-6) is listed again — under its new status — and not under the old one. What
  the list holds is untouched: a filter hides rows and never changes which chats
  are listed (UI-4) or how many, so "Load more chats" (UI-84) lists the next page
  of the store's order (STORE-12) exactly as it does with every filter pressed.
- **UI-107** The list's empty state follows the filters. With chats saved in the
  open project (PROJ-28, UI-5) but every chat the list holds hidden, the list
  says so in place of its rows — "No chats match the filters" — and "Load more
  chats" (UI-84) is unaffected: it is there while the project holds more chats
  than are listed, so a chat the filters hide can still be reached by loading
  more. With no chats saved in the project it is "No chats yet", whatever the
  filters are set to (UI-5), and with the filters hiding nothing the list is
  exactly what UI-4 to UI-6 and UI-84 describe.
- **UI-108** The filters a tab has set are remembered, as the size it has loaded
  the list to is (UI-85). They are kept in the browser's session storage
  (`elia:chat-filter`) and handed back to the page as it mounts, so opening
  another chat, or opening the drawer on a page that has one (UI-91), shows the
  list under the filters the tab last set rather than under all three pressed.
  The server is what decides them: what it reads there is three booleans, one for
  each toggle, and anything else — a missing key, a value that isn't a boolean,
  nothing stored at all — leaves all three pressed (UI-105); and it hands the
  state it decided to the browser to keep whenever a toggle is pressed, so what a
  later page reads is what the list showed. It is an enhancement, not the working
  part: with the hook absent (a page whose assets were not rebuilt, HOT-8), with
  nothing stored, or in a fresh browser session — a new tab, or storage cleared —
  the list starts with all three pressed (UI-105).
- **UI-34** Each sidebar chat shows when it was started in human-readable
  relative form ("just now", "10 minutes ago", "3 hours ago", "2 days ago",
  then a date after a week), in a `<time>` element whose `datetime` is the
  start time and whose `title` is the exact date and time. The relative text
  refreshes every minute.
- **UI-5** With no chats saved in the open project (PROJ-28, PROJ-31), the
  sidebar shows "No chats yet".
- **UI-6** When a turn starts (status becomes running) and when it ends (status
  becomes idle), the sidebar and page title refresh, so a chat that was just
  started shows its first message as its title without waiting for the turn to
  end.
- **UI-63** A chat started from `/chats` or from a "New chat" button (UI-77,
  UI-31, PROJ-26) is in the sidebar list as soon as it opens: newest first
  (STORE-12), highlighted as the open chat (UI-4), with
  the title "New chat" (STORE-7) and the start time "just now" (UI-34), before
  the user has sent anything. It stays listed when the user never writes to it
  (STORE-22).
- **UI-31** The sidebar shows a "New chat" button (`#new-chat`) above the chat
  list that starts a fresh chat in the open project (PROJ-28, PROJ-26), which
  is the project of the chat the page shows when it shows one (UI-2).
- **UI-33** Each sidebar chat link has a `title` attribute with the chat's
  description (STORE-10), so hovering shows the full text (up to 1000
  characters) rather than the truncated line.
- **UI-35** The sidebar is resizable: a drag handle (`#sidebar-resize`, an
  accessible `separator` with `aria-orientation="vertical"`) on its right edge
  changes its width by dragging or with the Left/Right arrow keys, and
  double-clicking it restores the default (16rem). The width is clamped between
  12rem and 40rem (and at most half the window), is kept in the browser's
  `localStorage`, and survives LiveView patches and navigation between chats.
- **UI-32** The header on every page carries a "Chats" control first, to the
  left of Files, Sessions, System and Settings, with the open project next to
  the logo (PROJ-29). It opens the chat
  list's drawer (`#chats-toggle`, UI-36, UI-91) rather than leaving the page: it
  is a button that opens the list and closes it again, and it never navigates —
  pressing it opens no other chat and loads no other page. Nothing in the header
  carries `#chats-link`: `/chats` (UI-77) is reached by deleting the open chat
  (UI-65) and by the dashboard's "All chats" link (DASH-7), not from the
  header. On the chat page, where the list is on the page anyway, there is no
  control at all from the `lg` breakpoint up (UI-4, UI-36).
- **UI-36** The chat list's drawer is closed until it is opened: the header's
  "Chats" button (`#chats-toggle`, UI-32) opens and closes it, its
  `aria-expanded` follows, and a backdrop (`#chats-backdrop`) or the Escape key
  closes it. On the chat page it is the small-screen shape of the list: from the
  `lg` breakpoint up the list (and the UI-35 drag handle) is on the page itself,
  the drawer is not rendered and the header has no "Chats" control, so nothing
  in the header leaves the open chat. A page that has no list of its own keeps
  the button at every width, and the drawer is that page's chat list (UI-91).
- **UI-91** The drawer is on every page that has no chat list of its own — the
  dashboard (DASH-2), files, sessions, system, logs, settings, and a
  chat's own settings (CSET) and terminal (TERM) pages. Nothing is inline on
  those pages, so the drawer opens at every width and the header's button is
  there at every width (UI-32, UI-36). It starts closed, and opening or closing
  it loads no other page and leaves the rest of that page as it is.
- **UI-92** The drawer holds the chat list: the "New chat" button (UI-31), the
  chats in the order and rows UI-4, UI-5, UI-33, UI-34, UI-45 to
  UI-47, UI-59, UI-63, UI-64, UI-72, UI-76 and UI-80 describe, and "Load more
  chats" (UI-84, UI-85). It draws the list's state, which is one state wherever
  the list is shown, so it cannot drift from the sidebar's: the list is read as
  the drawer opens, the statuses of the chats it lists follow the events that
  keep them live (UI-47, UI-58, UI-59, UI-72, UI-76), and a deletion made in it
  (UI-65) or a press of "Load more chats" updates it in place. On a page that
  belongs to a chat (`/c/<id>/settings`, `/c/<id>/terminal`) that chat is
  highlighted (UI-4) and "New chat" starts in its project (UI-31); elsewhere none
  is highlighted and it starts in the default project (PROJ-8).
- **UI-93** A chat row in the drawer opens that chat (UI-2), and the delete
  entry of its row menu (UI-103) deletes it as UI-64 and UI-65 describe: the row
  leaves the list with a "Chat deleted." flash, while the page the user is on
  stays where it is.
  Deleting the chat that page belongs to (`/c/<id>/settings`,
  `/c/<id>/terminal`) leaves for `/chats` instead (UI-65, UI-77), as deleting
  the open chat does.
- **UI-94** The drawer and its backdrop (UI-36, UI-91) are the page's lower
  layers: the menus the header opens — the project switcher's
  (`#project-menu`, PROJ-29) and the active chats control's
  (`#active-chats-menu`, ACTIVE-5) — are drawn above both, so with the drawer
  open a menu the user is choosing from is neither covered by the drawer nor
  dimmed by its backdrop, and its entries stay pressable.
- **UI-37** The header never overflows horizontally on narrow screens. Below
  the `sm` breakpoint the header buttons show only their icon (the label stays
  in the DOM for screen readers and as the control's `title`), with tighter
  spacing; from `sm` up they show icon and label.
- **UI-59** Every chat in the sidebar shows one status indicator
  (`#chat-status-<id>`, with `data-status` and a `title`). A chat that isn't a
  task chat (UI-46) shows `working` — an animated spinner — while its turn is
  running, that is while its session status is `:running` (SESS-4), `done` — a
  check, with the `title` "Done" — when the chat is marked done (DONE-2, UI-80),
  and `idle` — a dim dot — when it has no turn, unless a restart cut that turn
  short, which shows `interrupted` instead (UI-72). Waiting for approval
  (`awaiting_approval`),
  waiting for an answer (`awaiting_input`, UI-76) and paused come first (UI-47,
  UI-58, UI-76), so a chat that needs the user is never shown as idle. The
  indicator is right on first render, from
  `Elia.Agent.running/0` and the registry (SESS-19, SESS-28), and follows
  `{:chat_status, id, status}` (SESS-19) live. A task chat shows its task
  status under the same element (UI-46), with `done` in its place where the
  task is over once the chat is marked done and `working` while a turn of it
  runs (DONE-2).
- **UI-76** A chat whose session is waiting for an answer (SESS-4, ASK-3) shows
  it in its status indicator (`#chat-status-<id>`, with
  `data-status="awaiting_input"`, a speech-bubble icon and the `title` "Needs
  your answer"), so a question waiting in another chat — a parent, or any chat
  in the list — is not missed. It follows `{:chat_status, id, :awaiting_input}`
  (SESS-19) and is right on first render, from
  `Elia.Agent.awaiting_input/0`.

- **UI-111** A chat whose terminal is running shows a small terminal mark beside
  its status indicator (UI-59): `#chat-terminal-<id>`, scoped as the row's other
  ids are (UI-92), an icon (`hero-command-line`) with the `title` "Terminal
  running". The mark is on the row only while that chat's terminal is running: a
  chat with no terminal, one whose command has exited (TERM-1, TERM-4) and one
  that never started one show none, and the mark neither takes the status
  indicator's place nor changes what it shows. It is right on first render, from
  `Elia.Terminal.running_ids/0` (TERM-41), and follows the terminal's activity
  topic, so a terminal started or stopped while the list is on screen appears on
  that chat's row or leaves it without a reload. Every list that draws a chat's
  row draws the mark with it: the sidebar and the drawer (UI-4, UI-92), the
  header's active chats (ACTIVE-13), the dashboard's rows (DASH-15) and a
  project's chats (PROJ-59).

- **UI-112** A chat whose sub-tasks the list holds draws them behind a dropdown
  under its own row (`#chat-subtasks-<id>`), collapsed whenever the list is
  drawn: only the trigger shows — a chevron and the count of UI-113 — and the
  rows sit behind it in `#chat-children-<id>` (UI-45). A press on the trigger
  expands them and a second press collapses them again, without a round trip to
  the server, and what a collapsed trigger hides is in the page all the same,
  with the ids its rows have and their statuses live as they are expanded. The
  open state belongs to the browser: a re-render the user did not ask for — a
  status change (UI-47, UI-59), a chat opened, a list read again (UI-6) — leaves
  it as it is, the way the settings page's sections keep theirs (CONF-25,
  CONF-27). The sidebar and the drawer draw it alike (UI-4, UI-92).
- **UI-113** The dropdown's trigger names the sub-tasks listed under it: "1
  sub-task" for one and "<n> sub-tasks" for more, counting the rows the list
  would show there — the ones the filters leave listed (UI-106) — so a chat
  whose sub-tasks a filter hides counts none. It is drawn only while there is at
  least one. The count follows the list: a sub-task chat started while the list
  is on screen raises it (UI-49), and one deleted (UI-64) or hidden by a filter
  lowers it.

- **UI-64** Every chat row in the sidebar, task chats included (UI-45), has a
  delete entry in the row's own menu (`#delete-chat-<id>`, with the accessible
  label "Delete chat"), which asks for confirmation first, with `data-confirm`
  naming the chat, and only then deletes it. The menu is the list's one way to
  delete a chat: a row carries no delete control of its own. *Changed:* a row
  used to carry a trash button (`#delete-chat-<id>`) of its own beside its link
  (`#chat-link-<id>`).
- **UI-103** A chat row opens a menu of its own on a long press of it — a press
  held for about half a second — on a right-click on it with a pointer, and from
  the keyboard, the context-menu key or Shift+F10, while the row's link has
  focus. The menu (`#chat-row-menu-<id>`) is in the row's markup from the first
  render, hidden until the gesture opens it, so opening it costs no round trip
  and it opens at once however busy the chat is. It holds "Rename"
  (`#rename-chat-<id>`), the done entry (UI-109) and the delete entry (UI-64),
  in that order. The gesture
  is the page's, not the browser's: the menu the browser would open for a row —
  Chrome's own on Android, with its selection handles and "Open in new tab" —
  never appears for it, because the row's `contextmenu` is claimed rather than
  left to the browser. A press that becomes a scroll or a drag — the finger
  moving, or the pointer travelling, before the press is up — opens no menu and
  leaves the list scrolling as it did. One menu is open at a time: opening
  another row's closes the first. It closes on Escape, which puts focus back on
  the row's link, on a press outside it, and once an entry is chosen (UI-64,
  UI-104). It is drawn above the list rather than clipped by its scroll box, and
  within the screen's width (UI-78), so a row at the list's edge shows all of
  it. A chat row in the drawer (UI-92, UI-93) opens the same menu the same way.
  *Changed:* the menu held two entries — "Rename" and the delete entry — before
  the done entry (UI-109) was added.
- **UI-104** Choosing "Rename" (UI-103) renames the chat in its row: the input
  (`#chat-rename-<id>`) takes the link's place in the row — the row's link is
  not rendered while it is open, so no control is nested in another and a press
  on the row cannot navigate away mid-rename — holding the chat's title with all
  of it selected and focused, so it can be typed over at once. Enter saves it
  (TITLE-8) and the row shows the new title; Escape, a press outside the input
  and losing focus cancel it, leaving the row as it was and saving nothing. A
  title that is blank once trimmed (TITLE-2) is no title at all: it saves
  nothing either, exactly as cancelling does. The row's own `title` attribute
  remains the chat's description (UI-33) and is not what the input holds.

A chat's row is also where a chat that is finished is marked done, without the
chat being opened first: the composer's own control (DONE-4) is on the chat's
page, and a chat the user has stopped working in is one they are looking at in
the list.

- **UI-109** A chat row's menu (UI-103) holds a done entry, "Mark as done"
  (`#done-chat-<id>`), and the row offers it exactly while the status it shows
  (UI-59) is `idle`: a chat that is not done (DONE-2) and has no turn running, is
  not waiting for the user (UI-47, UI-76), is not paused (UI-58) and was not cut
  short by a restart (UI-72). Every other status is offered nothing — a working
  chat, one that needs the user, a paused one, an interrupted one and a done one.
  What it is offered by is the status the row shows now, not the one the row was
  drawn with: a chat that becomes idle while the page is open is offered it, and
  one that stops being idle is not, both without a reload. It is one menu
  (UI-103), so every row has it: the sidebar's, the drawer's (UI-92) and the
  header's (ACTIVE-9).
- **UI-110** Choosing "Mark as done" (UI-109) marks the chat done (DONE-1), as
  the composer's control does (DONE-4) and with no confirmation asked, and the
  row follows at once, without a reload: its indicator shows `done` (DONE-2) and
  the entry is no longer offered (UI-109). The chat need not be open and no
  session of it need be running — one is started for it, as naming it from its
  row does (TITLE-8) — and a task chat's row has the entry too, where marking the
  chat done is what ends the task (DONE-3).
- **UI-65** Confirming a delete removes the chat (SESS-29): its row leaves the
  sidebar and a "Chat deleted." flash appears. Deleting the chat that is open
  navigates to `/chats` (the most recent chat, or a fresh chat when there is
  none — UI-77); deleting any other chat leaves the open
  one in place. Deleting a chat whose turn is running stops that turn first
  (SESS-29), so a running chat can be deleted from any chat's sidebar.
- **UI-66** Deleting a parent chat leaves its task chats saved and listed on
  their own at the top level (UI-45); deleting a task chat leaves its parent.
- **UI-72** A chat whose turn a restart cut short (STORE-31, INTR-2) shows the
  `interrupted` status in the sidebar (`#chat-status-<id>`, UI-59): a warning
  triangle with `data-status="interrupted"` and a `title` saying the app
  restarted during the turn. It is right on first render, from the listed chats,
  for a chat whose page isn't open, so a turn that was cut short is visible
  before the chat is opened. It goes as soon as a session for the chat starts
  (INTR-3): this page through the open chat's own `{:status, …}` (which lists
  the chats again, UI-6) and every other page through `{:chat_status, id, :idle}`
  on the activity topic (SESS-19). A task chat still shows its task status
  (UI-46); `interrupted` is also the status STORE-17 gives a task chat whose
  session was lost, and the two read the same.

- **UI-74** A chat's own stored title (TITLE-1) is what its sidebar row
  (`#chat-link-<id>`) and its page title (UI-3) show, in place of the STORE-7
  derivation, and the open chat follows `{:title, title}` (SESS-33) as soon as
  it arrives — during the turn, without waiting for it to end (UI-6) — while
  other rows pick a title up at the next refresh (UI-6) or page load. The
  `set_title` call renders as a card whose summary is the new title, as UI-43
  does for `spawn_task` (UI-15), not as raw JSON, and the row's hover text
  (UI-33) stays the chat's description (STORE-10). A chat without a stored
  title is unchanged.

- **UI-80** A chat marked done (DONE-1) shows it in its sidebar row's status
  indicator (`#chat-status-<id>`, UI-59): `data-status="done"`, a check icon and
  the `title` "Done" in place of `idle`, so a finished chat reads at a glance
  next to one that was abandoned. It is right on first render, from the listed
  chats (STORE-35), and the chat this page has open follows `{:done, on?}`
  (SESS-35) as soon as it arrives, without a reload (UI-6), while other rows
  pick the flag up at the next refresh (UI-6) or page load, exactly as a title
  does (UI-74). Anything that needs the user or is running now still wins
  (UI-59), and a task chat shows its task status (UI-46) with `done` in its
  place once the task is over (DONE-2, DONE-3).

### Transcript

- **UI-7** An empty chat shows an empty state that tells the user Elia can run
  shell commands and that they approve each one.
- **UI-8** User messages render as right-aligned bubbles; assistant text as
  Markdown (UI-25); reasoning as a collapsed block (UI-29).
- **UI-9** Messages the harness wrote itself (`meta.harness`) render as
  notices, not as user bubbles.
- **UI-10** Text and reasoning deltas stream into draft blocks below the
  transcript. The drafts clear when the assistant message lands or the turn
  ends.
- **UI-11** While the agent is running and no text has streamed yet, a
  "Working" indicator is shown.
- **UI-12** Notices and errors from the session render inline as info and
  error rows.
- **UI-13** On a `{:reset, messages}` event the transcript is rebuilt from
  `messages`.
- **UI-14** The transcript stays scrolled to the bottom as content arrives,
  until the reader moves it up themselves: a move of theirs (UI-95) turns the
  following off for good — it comes back when they are within 8px of the end
  again or press the jump-to-the-end control (UI-87), and not merely because the
  position has drifted back inside a tolerance. Displacement that is not their
  own — the content growing, a rounding, a re-render — does not turn it off:
  while the following is on, content arriving keeps the list at its end as long
  as it is less than 80px away from it. *Changed:* the position alone decided
  before, so that 80px tolerance undid the reader's own scroll up — one that
  left them within it was pulled back to the end by the content arriving next,
  and staying up while output streamed came down to scrolling more than 80px at
  a time.
- **UI-87** The top of the chat page carries a jump-to-the-end control
  (`#jump-to-end`): a small button at the right of the context indicator
  (CTX-1), the transcript's own counterpart to it. Pressing it scrolls the
  transcript (`#transcript-scroll`) to its last message and puts the list back
  into the follow state UI-14 describes, so content arriving afterwards is
  followed again — the reader it is for is one who scrolled up and wants to come
  back. It is the browser's own action, not an event: no round trip, so it acts
  at once and needs no server state. It is there on first render, whatever the
  transcript holds — pressing it on a chat with nothing in it scrolls nothing —
  and without its hook (a page whose assets were not rebuilt, HOT-8) it does
  nothing rather than leaving the page broken.
- **UI-96** The chat page carries the chat's title in a row of its own
  (`#chat-title`) above the context indicator (CTX-1) and below the app header
  — in a sub-task chat, below its task header (UI-48). It is the title the page
  title shows (TITLE-1, UI-3): the chat's own stored title when it has one, else
  the STORE-7 derivation from its first user message. It is one line, truncated
  rather than wrapped, with the whole title in its `title` attribute, and it
  follows the chat being named mid-turn (`{:title, title}`, TITLE-4, UI-74)
  without a reload.
- **UI-95** The transcript stops following its end (UI-14) the moment the reader
  moves it up themselves — a wheel up, a finger on it, an upward key, or a press
  on its own scrollbar — rather than when the browser reports the position
  afterwards, so content arriving in the same frame is not followed. The press
  is what counts for the scrollbar, so a click on it that scrolls nothing does
  not leave the following off (UI-14).
- **UI-73** The notice a session writes after a restart cut the turn short
  (INTR-3) renders as an error row (UI-12), not as a plain harness notice
  (UI-9), so a turn the app killed is not mistaken for one that ended normally.
  The message marks it (`meta.interrupted`, INTR-3) and its row carries
  `data-kind="error"`, so the two are told apart in a test as well.
- **UI-81** The harness message a pause at a limit writes (LIMIT-10, SESS-37)
  renders as an error row (UI-12) too, like the notice a restart leaves (UI-73):
  the message marks it (`meta.limit`, SESS-37) and its row carries
  `data-kind="error"`, so a turn waiting on the user is not mistaken for one
  that ended quietly as a plain harness notice (UI-9). It is there on first
  render, from the saved messages (LIMIT-10), and stays when the turn is
  resumed or ends at the limit (STOP-1).
- **UI-82** Every harness message that reports why a turn isn't running renders
  as an error row (UI-12), told apart by the marker in its meta: a pause at a
  limit (`meta.limit`, UI-81), a stop (`meta.stopped`, STOP-1, SESS-38) and the
  notice a restart leaves (`meta.interrupted`, UI-73). A stop's row carries
  `data-kind="error"` and is there on first render, from the saved messages, as
  well as while the page is watching the turn. The session's `{:error, text}`
  event (SESS-6, SESS-38) is not a row of its own — the message is the row — so
  a stop reads once, whichever of the two arrives first (STOP-4).
- **UI-86** A retry of a failed model call (RETRY-3) clears the drafts (UI-10) —
  the attempt that failed is dropped and the answer starts over — and shows the
  retry's sentence as a notice row (UI-12), e.g. "Anthropic API request failed:
  timeout. Retrying in 15 seconds (attempt 2 of 4)." The turn keeps running, so
  the composer and the stop control stay disabled as they are, and the row is
  not part of the transcript: it is there while the page is watching the turn
  and gone when the chat is loaded again. A tool call the failed attempt had
  started is dropped with the drafts, never shown as one that ran (RETRY-2).

### Tool calls

- **UI-15** Each tool call renders as a card with an icon, the tool name, a
  status badge and a summary of its input: `$ <command>` for `shell`, the path
  for tools with a `path` input, "(no input)" for empty input, pretty JSON
  otherwise.
- **UI-98** A `shell` call whose command runs over more than one line shows
  only that command's first line in its card (UI-15), followed by an ellipsis
  and how many lines the command has, and a control (`#command-<call_id>`)
  that opens the whole command in a block (`#command-full-<call_id>`): the
  card is there collapsed on first render, and a press opens it where a later
  press closes it. A command of one line is unchanged and carries no such
  control.
- **UI-99** While a `shell` call awaits approval (APPR-3, UI-18) its whole
  command is open (UI-98), so what is being approved can be read above the
  buttons.
- **UI-16** Status badges: Needs approval, Needs your answer (a call awaiting
  an answer, ASK-3), Answered, Approved, Running, Done, Failed (done with an
  error), Pending (anything else).
- ~~**UI-17** `write_file` and `edit_file` cards have a collapsible "Changes"
  section (new content, or removed/added strings). It is expanded while the
  call awaits approval.~~ Retired: there are no file-tool cards (FILE); a file is
  changed by a `shell` call, whose card shows the command (UI-15).
- **UI-18** A call awaiting approval shows Approve and Deny buttons
  (`#approve-<call_id>`, `#deny-<call_id>`).
- ~~**UI-19** When a call awaiting approval writes a guarded file, or is a
  `hot_reload` while code files have unloaded changes, the card shows a
  warning naming the effect (see GUARD-1, GUARD-6). The `hot_reload` warning
  lists the pending files.~~ Retired: no guarded-file list and no pending
  tracking (DEPLOY-11).
- **UI-20** Once a result arrives, the card has a collapsible "Output"
  section, styled as an error when the result is an error.

- **UI-75** An `ask_user` call (ASK-1) renders as a question card: the card's
  summary is its `question` (as UI-43 does for a task's title), and while the
  call awaits an answer (`:awaiting_input`, ASK-3) the card shows each option as
  a button (`#answer-<call_id>-<n>`, in the order given, skipping an empty one)
  and, always, a text field with its button (`#answer-form-<call_id>`,
  `#answer-text-<call_id>`), so the user can answer with one click or in their
  own words (ASK-4). Its badge reads "Needs your answer" (UI-16) and the card is
  highlighted like one awaiting approval (UI-18). Clicking a button or
  submitting the text answers the call with that text (`Elia.Agent.answer/3`,
  ASK-6); a blank text is not sent. Once answered the buttons and the field are
  gone and the badge reads "Answered"; the answer the model got is the call's
  result, shown in the card's Output section (UI-20), which for this card is
  open rather than collapsed so the answer stays visible. A question answered in
  an earlier turn renders the same way from the saved history, without the
  buttons. The card is shown in the compact view too (UI-61, ASK-10).

- **UI-83** A question card reads as prose rather than as a command line: the
  question (UI-75) and the answer it got (UI-20's Output section, ASK-5) wrap
  onto as many lines as they need instead of running off one line, and a word
  too long for the line (a path, a URL) is broken rather than pushing the card
  wider. A line the user wrote is kept as written: only the wrapping separates
  this card from the others, whose summary and output scroll sideways when they
  are wide (UI-15, UI-20) — a shell command or a diff is read by its columns.

### Composer

- **UI-21** Enter sends the message; Shift+Enter inserts a newline. The input
  grows with its content.
- **UI-22** Messages that are blank after trimming are not sent, unless they
  carry attachments (UPLOAD-5).
- **UI-23** After a successful send the input clears.
- **UI-24** While the agent isn't idle, the input is disabled and the send
  button is replaced by a Stop button that stops the turn (SESS-8).
- **UI-89** Text typed into the message box is kept per chat in the browser's
  `localStorage` (`elia:draft:<chat id>`), so leaving the chat — for another
  page, another chat, a reload, or closing the tab — and coming back to it puts
  the text back in the box, each chat with its own. The draft is dropped once
  the message is sent (UI-23) and when the box is left empty.

- **UI-38** The chat settings page (CSET-5) has an "Auto-approve" button
  (`#auto-approve-button`) in its Auto-approve section (the composer only links
  to that page, CSET-8). It shows how many tools the chat auto-approves
  (`#auto-approve-count`, hidden at zero) and opens a popover
  (`#auto-approve`) that Escape or a click outside closes.
- **UI-39** The popover lists each tool that can need approval (APPR-13) with a
  switch (`#auto-approve-<tool name>`) that reflects and toggles APPR-8 for
  this chat, and a note that auto-approved tools run without review. A new chat
  starts with every switch on (APPR-14). Tools
  from folder skills appear after a skill
  reload. The switch state follows `{:settings, settings}` events (SESS-41),
  so every view of the chat stays in sync.
- **UI-40** A call awaiting approval has an "Always allow" button
  (`#always-allow-<call_id>`) that turns auto-approval on for its tool
  (APPR-11, which also approves this call).
- ~~**UI-41** The tools a chat auto-approves are visible without opening the
  popover: each one shows as a chip.~~ Removed: the per-tool state is only shown
  in the popover (UI-42); the count badge (UI-38) is enough outside it.
- **UI-42** In the popover each switch row says "On" or "Off" in text next to
  the switch, so the state doesn't rely on colour or hover and is clear on
  touch screens.
- **UI-67** The chat settings page (CSET-5) has a "Jail" switch
  (`#jail-toggle`) in its Jail section, with its state written out as text
  (`#jail-state`): "Jailed" when on, "Not jailed" when off. It reflects and
  toggles ISOL-16 for this chat, is saved with the chat, and follows
  `{:settings, settings}` events (SESS-41) so every view of the chat stays in sync.
  Turning it off shows that commands can then read the settings database and
  the user's credentials (ISOL-16, ISOL-17), and while it is off the chat page
  says so beside the chat menu's trigger (CSET-9).
- **UI-68** When the host has no jail (ISOL-12, ISOL-20) the switch is disabled
  and says so, rather than showing a chat as protected where it isn't.
- **UI-69** An approval prompt in a chat whose jail is off says the command
  runs unjailed (ISOL-17).
- **UI-101** An approval prompt for a call that asked for no jail says the
  command runs unjailed (`#unjailed-<call id>`, ISOL-31) — the label UI-69 puts
  on a prompt while the chat's jail is off, on that call's own request instead.
- ~~**UI-100** The chat page's composer toolbar says when the chat's network is
  limited (`#network-warning`) — beside the chat menu's trigger and its jail
  warning (CSET-9) — naming the mode in words, "Allowlisted hosts" or "No
  network", and shows nothing there when the chat is unrestricted (NET-26).~~
  Removed: the composer's network notice is gone; the mode and its entries are
  set and read on the chat settings page (NET-22 to NET-25).
- ~~**UI-70** The chat shows a worktree's dependency sync in progress (ISOL-7,
  ISOL-23) as text next to the composer (`#deps-sync`, "Preparing shared
  dependencies…"), following an event like `{:deps_sync, on?}`, gone when the
  sync ends whether it succeeded or failed. It covers both a sync the chat
  started in the background and one a command is waiting for, and it never
  blocks the composer or the transcript.~~ Removed: nothing runs ahead of a
  command any more (ISOL-7, ISOL-23), so there is no sync for the chat to show.
  A command that compiles its worktree's dependencies is a tool call, and the
  transcript already shows it as running (FEED).

- **UI-79** The composer toolbar has a done control (`#done-toggle`) for every
  chat, one entry of its chat menu (UI-97): a button whose
  `aria-pressed` is `true` while the chat is done (DONE-1) and whose label says
  what clicking it does — "Mark done" while the chat isn't done, "Reopen" while
  it is — with a matching `title`. Clicking it marks the chat done or reopens it
  (`Elia.Agent.set_done/2`, SESS-35) right away, with no confirmation, and the
  control's state follows `{:done, on?}` (SESS-35), so every view of the chat
  agrees; the sidebar's icon for the chat (UI-80) changes with it. It is there
  while a turn runs too (DONE-5). A task chat's page has the same control
  (DONE-4): its task header (UI-48) keeps saying the task's own status, and the
  control is the chat's own bookkeeping (DONE-3), so it reads the same and
  behaves the same there.

- **UI-97** The composer toolbar carries one chat menu: an icon-only trigger
  (`#chat-menu-button`, with `aria-haspopup`, `aria-expanded` and a `title`
  saying what it opens) that opens a panel (`#chat-menu`) **above** itself — a
  drop-up, since that toolbar sits at the bottom of the screen, and no wider
  than the phone's screen (UI-78) — and shuts it again on a second press, on a
  click outside it, on Escape, and once a page it leads to is open. The panel
  holds, in this order, the model in use as text (`#chat-settings-model`, its
  provider badge and name, and no control of its own), the "Chat settings"
  link (`#chat-settings-link` to `/c/<id>/settings`, CSET-8), the terminal
  link (`#chat-terminal-link` to `/c/<id>/terminal`, TERM-19) and the done
  control (`#done-toggle`, UI-79). The Focus view toggle (UI-60) and the jail
  warning (CSET-9, `#jail-warning`, `#jail-unavailable`) stay outside it, in
  the toolbar: one acts on what the user is reading, the other is a warning,
  and neither is a setting — a warning inside a shut menu is not one.
  *Changed:* the toolbar used to show the settings link, the terminal link and
  the done control side by side, in every chat and at every width.

### Fitting the screen

The chat is read on a phone as much as on a desktop, where the browser's own
toolbars and the on-screen keyboard cover part of the window. Only the
conversation should ever scroll: the controls the user needs must sit inside
what the screen actually shows.

- **UI-78** The chat page fits the visible screen on any device: the header, the
  chat list, a task header, the banners and the composer are all visible without
  scrolling, and the document itself never scrolls — the only scroll areas are
  the message list (`#transcript-scroll`), and the sidebar's own chat list
  (`#chat-list`) inside the sidebar, which scroll within their own boxes. This
  holds with an empty transcript too, and stays true as the transcript grows.
  What makes it hold is explicit rather than implied by the engine: the app
  shell (`#app-shell`, `EliaWeb.Layouts`) is one *small* viewport tall — the
  visible area with a mobile browser's toolbars shown — rather than the dynamic
  one, which a phone's URL bar may still overlap; and the message list and the
  column holding it may shrink to nothing (`min-h-0`), so the composer stays
  where it is even in an engine that would otherwise keep a flex child at its
  content height and push it off the screen. The shell's height is its own
  markup's (`style`, `100svh` with a `100vh` fallback) rather than a class: a
  page that kept the stylesheet it loaded, and a deploy that never rebuilds the
  built assets, would otherwise give the shell no height rule at all and leave
  the composer at the end of the message list (HOT-8). The keyboard is
  PWA-7.

### Markdown

- **UI-25** Assistant text, both saved and streaming (UI-10), renders as
  GitHub-flavoured Markdown: headings, emphasis, strikethrough, lists, task
  lists, tables, block quotes, inline code, fenced code blocks, links and bare
  URLs.
- **UI-26** Single newlines render as line breaks, so a plain-text response
  looks the same as it would as plain text.
- **UI-27** Raw HTML in assistant text is not rendered, and links or images
  with unsafe URLs (such as `javascript:`) lose their URL.
- **UI-28** Long code blocks and wide tables scroll horizontally inside the
  message instead of widening the transcript.

### Reasoning

- **UI-29** Reasoning, both saved and streaming (UI-10), is collapsed by
  default: only a "Reasoning" header with a light-bulb icon and its length in
  words is shown. Clicking the header reveals the text as small italic text;
  clicking again hides it.
- **UI-30** While reasoning streams, its header pulses and reads
  "Reasoning…". Expanding the streaming block keeps it expanded as more text
  arrives.

### Compaction

The session keeps and shows the full history; the model is sent a smaller
**request view** (COMPACT-2). The transcript is honest about which parts of it
the model did or did not see, the user can compact the chat by hand, and can pin
an item compaction hid so it stays in the model's context.

- **UI-51** The transcript always shows the whole conversation, including what
  compaction elided (COMPACT-1), and annotates each item with its request-view
  status (COMPACT-25): "Not sent to the model" for an item the model was not
  sent, "Truncated for the model" for one it got only part of, and "Summarized
  for the model" for one a summary stands in for. The note (`#status-<item>`,
  where the item is `m<index>`, `m<index>-<block>` or `call-<call_id>`) is dim
  and names the elided amount when there is one. An item the model was sent in
  full carries no note.
- ~~**UI-52** Every transcript item has a pin toggle (`#pin-<item>`) that pins or
  unpins its message and shows the state.~~ Removed: the transcript has no pin
  control; the user no longer pins messages (COMPACT-21).
- **UI-53** A folded summary renders as a collapsible notice
  (`#compaction-summary`, open by default) at the boundary of the region it
  covers, with its text (`#compaction-summary-text`) and its length in words, so
  the user sees the compression in place rather than a gap (COMPACT-19).
- **UI-54** The "Compact" button (`#compact-button`) that compacts the chat now
  (COMPACT-10), and flashes an error while a turn is running, is on the chat
  settings page, in its Context section (CSET-5). The composer no longer holds
  it (CSET-10).
- **UI-56** An item the model was **not sent at all** — the "Not sent to the
  model" and "Summarized for the model" cases of UI-51 — is de-emphasised, not
  merely annotated: its content is dimmed (faded, and back to full opacity on
  hover) and its note (UI-51) becomes a chip, so a pruned region reads at a
  glance. Each transcript row carries its status in
  `data-request-status` (`sent`, `elided`, `summarized` or `truncated`) and its
  dimmed content in `[data-pruned]`. An item the model was sent in full, and
  one it got only part of (truncated), are not dimmed.
- **UI-88** An item the model was **not sent in full** — the elided, summarized
  and truncated cases of UI-51, the ones that carry a note — has a pin button
  (`#pin-<item>`, the item name of UI-51) beside its note, and a pinned item has
  it too, so a pin can be taken back; an item the model was sent in full that is
  not pinned has none. Pressing it pins or unpins the **message that item
  belongs to**, through `Elia.Agent.set_pin/4` (SESS-25, COMPACT-21) — for a tool
  card, the tool message carrying its result, since a call and its result are
  two messages (COMPACT-4), and a tool card's own note is its result's status,
  so pinning a card's result clears its note — so from then on no compaction
  rule elides it and it is back in the request view. The button says which it
  does
  (`aria-pressed="true"`, a filled bookmark and the label "Pinned" while the
  message is pinned, "Pin" while it isn't), and the state the session saves and
  broadcasts (COMPACT-24, SESS-25) re-derives the transcript, so the item's note
  and its dimming (UI-56) go and the estimate (COMPACT-26) grows with it.

### Sub-tasks

A child is an ordinary saved chat (SUBTASK-5) with task metadata (STORE-16),
so it opens at `/c/<child id>` like any chat and carries the status any chat
does (UI-59, UI-72). What a task finished with is in the chat's own transcript,
as the `mark_done` call at the end of it and the message before it that says
what it did — that message is the summary the parent gets (SUBTASK-9) — so the
header does not repeat it. A `spawn_task` call is a tool call like any other
(UI-43), and nothing on the parent's page draws a child's status a second time:
its own row in the chat list shows it (UI-46), and the parent lists it there or
with `list_chats` (HIST-2).

- ~~**UI-55** A `{:subtask, …}` agent event is accepted and ignored by the chat
  page.~~ Removed: replaced by UI-43 and UI-44. Renumbered from UI-31, which
  the active "New chat" button requirement also used (the phase 1 spec reused
  the ID), so `UI-31` now names one thing only.
- **UI-43** A `spawn_task` call renders as a tool call (UI-15): its summary is the
  task `title` from the call's input, since a spawn's input is mostly the
  `brief`, and its input is shown under it as a collapsible "Brief"
  (`#task-brief-<call_id>`, expanded while the call awaits approval). It carries
  the usual badge (UI-16) and approval buttons (UI-18) while it awaits approval.
  Nothing else is drawn on it: the child's status and a link to the child chat
  are the retired UI-44, so the call never shows a status the child's own row
  doesn't (UI-46, UI-59). *Changed:* the card's status row, its "waiting for
  approval" line and its link to the child went with UI-44; the brief section
  stays, and the brief is also the child's first message (SUBTASK-5).
- ~~**UI-44** Once the child exists, the card shows its status
  (`#task-status-<call_id>`) and a link to the child chat
  (`#task-link-<call_id>`). The status is the child chat's own — the same
  `data-status` its sidebar row carries (UI-46, UI-59, UI-72): `working` while
  a turn of it runs, `awaiting_approval` or `awaiting_input` while it needs the
  user, `paused` at a limit, `interrupted` after a restart, `done` once its
  chat is marked done and `idle` otherwise — so the card and the child chat
  never disagree. It follows the child's own events (SESS-19, SESS-35), and the
  link and status also appear when the chat is opened later, from the
  children's saved metadata (`parent_call_id`, STORE-18). While the child waits
  for the user to approve a tool call in its own chat (SESS-19), the card says
  so (`#task-awaiting-<call_id>`), and so does a child waiting for an answer to
  a question (ASK-9, `#task-input-<call_id>`). *Changed:* the status used to be
  the task's own, from a `{:subtask, …}` event (the retired SUBTASK-7), and the
  card no longer shows a status the child's own chat doesn't have (SUBTASK-33).~~
  Retired: there is no task card (UI-43). A child's status is the status its own
  chat has and is drawn in its own row (UI-46, UI-59), a parent that wants it in
  text lists its children with `list_chats` (HIST-2, HIST-3), and its chat is
  opened from the sidebar like any chat (UI-45). The events the card followed
  (SESS-19, SESS-35) still refresh the sidebar (UI-49).
- **UI-45** The sidebar nests a sub-task chat under the chat that spawned it
  (STORE-17), indented and ordered by start time (oldest first), inside the
  collapsed dropdown its parent's row draws (UI-112). A sub-task whose parent
  isn't in the list is shown on its own at the top level. The row
  (`#chat-link-<id>`) uses the chat's own title (STORE-33, TITLE-3) and carries
  the status indicator any chat's row has (UI-46). *Changed:* the task's own
  title was what the row showed (STORE-17); a sub-task is named by its own title
  now (TITLE-3). *Changed:* the nested rows were always listed; they are behind
  a collapsed dropdown now (UI-112).
- **UI-46** A sub-task chat in the sidebar shows its status the way any chat's row
  does (UI-59, UI-72): the same indicator (`#chat-status-<id>`), the same
  `data-status` values and the same `title`, derived by the same code, so a
  child chat is never shown a status its own page doesn't have. *Changed:* a
  task chat used to show its task's status (`running`, `done`, `blocked`,
  `failed`, `unfinished`, `cancelled`), with the chat's own flag and turn
  standing in for some of them (DONE-2); that vocabulary went with the task
  status itself (SUBTASK-33), so a child whose chat isn't marked done and has
  no turn running reads `idle`, and one whose chat is marked done reads `done`.
- **UI-47** Any chat in the sidebar that has a tool call awaiting approval
  (SESS-4) shows it in its status indicator (`#chat-status-<id>`, with
  `data-status="awaiting_approval"`, a hand icon and the `title` "Needs
  approval"), so a pending prompt in a child chat is not missed from the parent
  or any other chat. It follows status changes of every chat live (SESS-19) and
  is right on first render.
- **UI-48** A sub-task chat shows a header (`#task-header`) above the transcript
  with "Task of" and a link to the chat that spawned it (`#task-parent-link`,
  labelled with that chat's title, STORE-17) and the chat's own status (UI-59,
  UI-72, on `#task-header-status`, with UI-46's `data-status` values). It shows
  neither the brief — that is the child's first message, in the transcript
  (SUBTASK-5, UI-9) — nor the result the task finished with (SUBTASK-9). The
  header follows the chat's own status events (SESS-19). *Changed:* the
  collapsible "Brief" (`#task-header-brief`) and the `{:task, metadata}` event
  it followed (SESS-20) went with the second copy of the brief.
- **UI-49** The sidebar refreshes when a chat's status changes (SESS-19) or its
  done flag does (SESS-35), so a new task chat and its status show without
  waiting for the turn to end (UI-6). *Changed:* it used to follow a
  `{:subtask, …}` event (the retired SUBTASK-7), which is now the same status
  every chat broadcasts.

- ~~**UI-50** The status `cancelled` — one a task saved before SUBTASK-16
  changed may still have — has its own icon, wherever a task status is shown
  (UI-44, UI-46, UI-48), with `data-status="cancelled"`.~~ Retired: a chat has
  no task status to draw (UI-46), so there is no `cancelled` to show; a saved
  `cancelled` is ignored when its chat is read (SUBTASK-34).

- **UI-57** A chat whose turn is paused at a limit (SESS-27) shows a banner
  (`#pause-banner`) above the transcript with the pause message
  (`#pause-message`) and two buttons: Continue (`#resume-button`, SESS-27) and
  Fail (`#fail-button`, SESS-27). It follows `{:paused, message}` and the
  status, and is shown on first render from the snapshot's `pause`.

- **UI-58** The parent's task card says the child is paused
  (`#task-paused-<call_id>`) while it waits for the user, and the sidebar shows
  a paused chat in its status indicator (`#chat-status-<id>`, with
  `data-status="paused"`, a pause icon and the `title` "Paused"), both
  following `{:chat_status, id, :paused}` (SESS-19) and right on first render.

### Compact view

The default transcript is honest about everything the agent did (tool calls,
reasoning, request-view notes). A reader who only wants the conversation can
switch to a compact view that keeps just the messages, and that fills the gap
the hidden tool calls leave with a one-line summary of the current step.

- **UI-60** The composer toolbar has a "Focus" view toggle (`#view-toggle`, a
  button carrying `aria-pressed` and a `title`) that switches the transcript
  between the full view and the compact view. The choice is kept in the
  browser's `localStorage` (`elia:compact-view`), so a chat opened later in the
  same browser starts in the chosen view.
- **UI-61** In the compact view the transcript shows only the direct messages:
  user messages, assistant text (saved and streaming) and notices (including
  the folded summary, UI-53). Tool calls, reasoning (saved and streaming, UI-8,
  UI-29) and the per-item request-view notes (UI-51) are not rendered. A
  question card is the exception: it is addressed to the user, not a detail of
  the agent's work, so it stays visible (UI-75, ASK-10). A task chat's header
  (UI-48) and the pause banner (UI-57) stay
  visible.
- **UI-62** While the compact view is on and the turn is working (`:running`,
  `:awaiting_approval` or `:awaiting_input`, SESS-4), a one-sentence "working
  on" summary
  (`#work-summary`) names the current step: the tool that is running or awaiting
  approval ("Running `mix test`.", "Waiting for your approval to run
  `git commit`."), a question waiting for an answer ("Waiting for your answer.",
  ASK-10), writing a reply, or thinking, and "Working." before the step
  is known. It is set when the turn's status changes and, while the turn runs,
  refreshed about once a second, so it lags the step by no more than a second
  (the one-second timer only runs while a turn is running, so an idle chat is
  left alone). It is cleared when the turn ends. While it waits for approval or
  for an answer it offers a "Review" button (`#work-summary-review`) that
  switches to the full view.
- **UI-90** In the compact view an item that would render nothing is not shown
  at all: a message with no text of its own — a blank text part, or a message
  whose only content is the tool calls or reasoning the compact view hides
  (UI-61) — leaves no empty row, so its time (MSGAT-5) never sits alone where
  the work was. The full view is unchanged (MSGAT-7).

## Implementation

`EliaWeb.ChatLive`, `EliaWeb.Markdown`, `EliaWeb.Router`, `EliaWeb.Layouts`
(the app shell the chat fills, `#app-shell`, UI-78),
`EliaWeb.ChatStatus` (a chat's status and its icon, including a done chat's,
UI-59, UI-80),
`Elia.Agent` and `Elia.Agent.Session` (the chat's done flag: `set_done/2`, the
`{:done, on?}` event, and clearing it when a message continues the chat, UI-79,
DONE-9),
`Elia.Terminal` (which chats have a terminal running, `running_ids/0`, and the
activity topic the list follows, TERM-41, UI-111),
`Elia.Store` (the chat `/chats` resumes, STORE-29, UI-77; the title a row and the
page show, STORE-33, UI-74; the done flag a row shows, STORE-35, UI-80),
`EliaWeb.ChatSettingsLive` (the per-chat settings page the composer links to,
CSET; the model picker, the auto-approve switches and the jail switch,
UI-38, UI-39, UI-67, UI-68).

The chat page's own title row (`#chat-title`, UI-96) is `EliaWeb.ChatLive`'s
too: it draws the title the page title carries (TITLE-1), so the two cannot
disagree.

The chat list lives in one place: `EliaWeb.ChatList` draws it (the "New chat"
button, the rows with their status indicators, the menu a row opens and the
rename input it shows (UI-103, UI-104), the empty state and "Load more chats"),
and its hook in the session's
`on_mount` list gives every page the list's state — the listed chats of the
open project and whether more are saved in it, the page size (UI-84, UI-85),
the projects and the open one (PROJ-28, PROJ-31), the statuses a row
is marked with (UI-47, UI-58, UI-59, UI-72, UI-76) and whether the drawer is
open — and handles the events that drive it (`toggle_chats`, `close_chats`,
`more_chats`, `chat_page`, `delete_chat`, `rename_chat`, `mark_chat_done` and
`open_project`, which makes a project the open one, PROJ-29). A page that draws
the drawer therefore needs no wiring of its own, and one page's sidebar and another page's
drawer are
one list with one state, kept in step by construction. `EliaWeb.Layouts` renders
the header's "Chats" button on every page, the open project's switcher beside
the logo (PROJ-29), and the drawer (`#chats-drawer`, with
its backdrop, UI-36) on every page that is not `chats_sidebar` — which
`EliaWeb.ChatLive` is, since it lays the list out as its own page's sidebar
(UI-4, UI-35, UI-36).

The menu a row opens is `EliaWeb.ChatRowMenu`'s markup, drawn by the chat list's
rows and by the header's active chats (ACTIVE-8), one module because a colocated
hook's name is resolved against the module its markup is compiled in. Whether its
done entry (UI-109) is offered is the row's own status: the markup draws it
hidden for a chat that isn't idle, and the hook that owns the menu keeps it in
step with the status the row shows, since the menu itself is never patched
(UI-103).

The composer's draft (UI-89) is the browser's own: `EliaWeb.ChatLive`'s
colocated hook keeps it in `localStorage` and puts it back on mount, and nothing
of it reaches the server or a saved chat.

The chat list's page size is `EliaWeb.ChatLive`'s (`@chat_page`, 30, UI-4). It
lists the page's chats — the open project's (PROJ-28, PROJ-31), asking
`Elia.Store.list/2` with a `where:` for them (STORE-52) — and asks for one chat
more than it
shows, so whether more are saved is known without reading the chats twice
(UI-84), and it keeps the page size in its state, so every refresh re-lists the
same pages (UI-85). The store itself is unchanged: a page is a prefix of
(STORE-12) order, so listing the next page is listing a longer prefix.

## Tests

- `test/elia_web/live/chat_live_test.exs` (the page and its empty state, the
  harness messages, the streaming drafts and the reasoning, the tool cards and
  their badges, a multi-line command's collapsed card — UI-98, UI-99 — the
  sidebar and its rows, its row menu and renaming a chat in a row, a delete,
  the Markdown in a reply, and what `/chats`
  opens, and the terminal mark a row shows while that chat's terminal is
  running — UI-2, UI-6 to UI-10, UI-18, UI-25, UI-29 to UI-37, UI-45, UI-59,
  UI-63 to UI-66, UI-77, UI-103, UI-104, UI-111).
- No test: UI-5, UI-11, UI-13, UI-22 to UI-24, UI-49 — no test in the
  tree asserts them: the sidebar's "No chats yet" state, the "Working" indicator
  while a turn runs with nothing streamed yet, a `{:reset, messages}` rebuilding
  the transcript, a message blank after trimming being dropped, the input
  clearing after a send, the Stop button replacing the send button, and the
  sidebar refreshing on a `{:task, …}` event and on a chat's done flag changing.
- No test: UI-12 — that a session's notice and its error render inline as an info
  and an error row is asserted nowhere; the rows of the other kinds are (UI-9,
  UI-73, UI-81, UI-82).
- `test/elia_web/live/chat_title_test.exs` (UI-3, UI-6, UI-33, UI-74, UI-96, and the
  stored title and `{:title, title}`), with
  `test/elia_web/live/page_title_test.exs` for the page title a chat gives the
  browser (UI-3).
- `test/elia_web/live/auto_approve_test.exs` (UI-38 to UI-40, UI-42).
- `test/elia_web/live/jail_test.exs` (the jail switch, and the prompts that say
  a call runs unjailed — UI-67 to UI-69, UI-101).
- `test/elia_web/live/chat_settings_test.exs` (the settings page, CSET; the
  controls it took over, UI-2, UI-3, UI-38).
- `test/elia_web/live/compaction_test.exs` (the transcript's annotations,
  UI-20, UI-51, UI-53, UI-56, UI-88), and
  `test/elia_web/live/compact_view_test.exs` (the Focus view, UI-60 to UI-62,
  UI-90).
- `test/elia_web/live/task_ui_test.exs` (the task card and its statuses, the
  nested rows and the collapsed dropdown they sit behind, with its count, the
  header, the pause banner — UI-43 to UI-49, UI-57 to UI-59, UI-64, UI-112 to
  UI-113).
- `test/elia_web/live/user_input_test.exs` (the question card and the
  indicators, the collapsible output, the card in the Focus view — UI-15, UI-16,
  UI-44, UI-61, UI-62, UI-75, UI-76, UI-83).
- `test/elia_web/live/chat_done_test.exs` (the toolbar control, the sidebar icon,
  UI-46, UI-79, UI-80).
- `test/elia_web/live/chat_menu_test.exs` (the composer's chat menu: its
  trigger, what it holds, and what stays outside it — UI-97), and
  `test/elia_web/browser/chat_menu_test.exs` (the same menu's own bindings in a
  real browser: the drop-up, a second press on the trigger, a click outside it
  and Escape — UI-97; a browser test, so it runs with `ELIA_BROWSER_TESTS=1` —
  BROWSER-5).
- `test/elia_web/live/chat_list_test.exs` (the list's pages: the "Load more chats"
  button, the pages that stay loaded, and a list that had no more to begin with —
  UI-2, UI-4, UI-65, UI-84, UI-85; the filters at the top of the list, the chats
  they hide and the empty state they leave — UI-105 to UI-107; the list holding
  one project's chats, PROJ-31; the done entry in a row's menu — offered for an
  idle chat alone and marking the chat done when it is chosen — UI-109, UI-110).
- `test/elia_web/live/project_switcher_test.exs` (the project the header names,
  its menu, choosing a project, and the new-project modal its entry opens —
  PROJ-28 to PROJ-30, PROJ-55).
- `test/elia_web/live/chat_drawer_test.exs` (the drawer on the pages that have
  no chat list of their own — the dashboard, files, settings and a chat's
  terminal: the button at every width, the backdrop and Escape, the list it
  holds, "Load more chats" and the pages that stay loaded, a delete, the
  highlighted chat, the project "New chat" starts in, and that pressing the
  button never navigates — UI-32, UI-36, UI-91 to UI-93).
- `test/elia_web/live/dashboard_test.exs` (the rows and indicators it shows,
  UI-32, UI-34, UI-45 to UI-47, UI-59).
- `test/elia_web/browser/chat_list_test.exs` (the size a tab remembers when
  another chat is opened, the button outside the list's scroll box, the filters
  a tab remembers, and a sub-task dropdown opening on a press and closing on a
  second one, kept open through a re-render — UI-84, UI-85, UI-108, UI-112 — a
  browser test, so it runs with `ELIA_BROWSER_TESTS=1` — BROWSER-5).
- `test/elia_web/browser/chat_layout_test.exs` (the page fits the screen, UI-78;
  a browser test, so it runs with `ELIA_BROWSER_TESTS=1` — BROWSER-5).
- `test/elia_web/browser/chat_row_menu_test.exs` (a row's menu in a real
  browser: the long press and the right-click that open it, that the browser's
  own menu does not follow them, a press that becomes a scroll opening none, and
  Escape and a press outside closing it — UI-103, UI-104; the done entry, offered
  for an idle chat and gone for any other as the row's status changes — UI-109; a
  browser test, so it runs with `ELIA_BROWSER_TESTS=1` — BROWSER-5).
- `test/elia_web/browser/chat_browser_test.exs` (the chat page's hooks in a real
  browser: Enter sending a message, the transcript at its end, the reader's own
  move up stopping the following and their return to the end starting it again,
  and the jump-to-the-end button — UI-14, UI-21, UI-87, UI-95; a multi-line
  shell command's card opening on a press — UI-98; the message box's draft,
  stored and restored per chat — UI-89; a browser test, so it runs with
  `ELIA_BROWSER_TESTS=1` — BROWSER-5).
- `test/elia_web/browser/small_screen_layout_test.exs` and
  `test/elia_web/browser/interaction_feedback_test.exs` (a tool card and the
  pressed state at a phone width, UI-15, UI-20, UI-32; the header's project
  menu above the chat list's drawer at a phone width, UI-94 — both browser
  tests, so they run with `ELIA_BROWSER_TESTS=1` — BROWSER-5).
- `test/elia_web/markdown_test.exs` (UI-25 to UI-27), and
  `test/elia_web/time_ago_test.exs` (UI-34).
- No test: UI-28 — the scroll box inside a long code block or a wide table is
  CSS, checked by eye rather than asserted.
