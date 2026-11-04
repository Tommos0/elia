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
  starting over: it opens the most recently started chat (STORE-12 order, the
  first one the sidebar lists) that isn't a task chat (STORE-17, UI-45), since a
  sub-task chat is reached from its parent's card (UI-44) and not where the user
  left off. Only when there is no such chat does it start a fresh one in the
  default project (PROJ-8), saved at once (STORE-22) — so browsing to it never
  leaves another empty "New chat" behind while a chat exists, and resuming
  writes nothing (STORE-22, STORE-29). It is what the header's "Chats" control
  opens on the pages that have no chat list of their own (UI-32) and where
  deleting the open chat lands (UI-65). Starting a chat stays explicit: the
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
  (STORE-12), newest first, grouped by project (PROJ-24), each linking to
  `/c/<id>`. The open chat is highlighted. Small screens get the same list
  through a drawer (UI-36).
- **UI-34** Each sidebar chat shows when it was started in human-readable
  relative form ("just now", "10 minutes ago", "3 hours ago", "2 days ago",
  then a date after a week), in a `<time>` element whose `datetime` is the
  start time and whose `title` is the exact date and time. The relative text
  refreshes every minute.
- **UI-5** With no saved chats, the sidebar shows "No chats yet".
- **UI-6** When a turn starts (status becomes running) and when it ends (status
  becomes idle), the sidebar and page title refresh, so a chat that was just
  started shows its first message as its title without waiting for the turn to
  end.
- **UI-63** A chat started from `/chats` or from a "New chat" button (UI-77,
  UI-31, PROJ-26) is in the sidebar list as soon as it opens: under its project
  (PROJ-24), newest first (STORE-12), highlighted as the open chat (UI-4), with
  the title "New chat" (STORE-7) and the start time "just now" (UI-34), before
  the user has sent anything. It stays listed when the user never writes to it
  (STORE-22).
- **UI-31** The sidebar shows a "New chat" button (`#new-chat`) above the chat
  list that starts a fresh chat in the open chat's project (PROJ-26), which is
  the default project when there is none (PROJ-8).
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
  left of Projects, Files, Sessions, System and Settings. On the chat page it
  shows the chat list rather than leaving the chat: it is the chat list's
  drawer toggle (`#chats-toggle`, UI-36), which opens and closes the list below
  the `lg` breakpoint, and it never navigates — pressing it never opens another
  chat. On the other pages, which have no chat list to show, it is a link
  (`#chats-link`) to `/chats`, the chat list's entry point, which resumes the
  chat the user left off in (UI-77; the dashboard shows it there too, DASH-2),
  so it never navigates to the dashboard and never opens another chat than that
  one.
- **UI-36** On small screens the chat list is a drawer: the header's "Chats"
  button (`#chats-toggle`, UI-32) opens and closes it, its `aria-expanded`
  follows, the drawer starts closed, and a backdrop (`#chats-backdrop`) or the
  Escape key closes it. Neither the toggle nor the backdrop exists from the
  `lg` breakpoint up, where the list (and the UI-35 drag handle) is always
  visible — so the chat page's header shows no "Chats" control there, and
  nothing in the header leaves the open chat.
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
  status under the same element (UI-46).
- **UI-76** A chat whose session is waiting for an answer (SESS-4, ASK-3) shows
  it in its status indicator (`#chat-status-<id>`, with
  `data-status="awaiting_input"`, a speech-bubble icon and the `title` "Needs
  your answer"), so a question waiting in another chat — a parent, or any chat
  in the list — is not missed. It follows `{:chat_status, id, :awaiting_input}`
  (SESS-19) and is right on first render, from
  `Elia.Agent.awaiting_input/0`.

- **UI-64** Every chat row in the sidebar, task chats included (UI-45), has a
  delete button (`#delete-chat-<id>`, a trash icon with the accessible label
  "Delete chat") beside its link (`#chat-link-<id>`) as a sibling of it, not
  nested inside the link. Clicking it asks for confirmation first, with
  `data-confirm` naming the chat, and only then deletes it.
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
  (UI-59), and a task chat still shows its task status (UI-46, DONE-3).

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
  unless the user has scrolled more than 80px up.
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
  resumed or failed (LIMIT-11).

### Tool calls

- **UI-15** Each tool call renders as a card with an icon, the tool name, a
  status badge and a summary of its input: `$ <command>` for `shell`, the path
  for tools with a `path` input, "(no input)" for empty input, pretty JSON
  otherwise.
- **UI-16** Status badges: Needs approval, Needs your answer (a call awaiting
  an answer, ASK-3), Answered, Approved, Running, Done, Failed (done with an
  error), Pending (anything else).
- **UI-17** `write_file` and `edit_file` cards have a collapsible "Changes"
  section (new content, or removed/added strings). It is expanded while the
  call awaits approval.
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

### Composer

- **UI-21** Enter sends the message; Shift+Enter inserts a newline. The input
  grows with its content.
- **UI-22** Messages that are blank after trimming are not sent.
- **UI-23** After a successful send the input clears.
- **UI-24** While the agent isn't idle, the input is disabled and the send
  button is replaced by a Stop button that stops the turn (SESS-8).

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
  reload. The switch state follows `{:auto_approve, names}` events (SESS-16),
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
  `{:jail, on?}` events (SESS-30) so every view of the chat stays in sync.
  Turning it off shows that commands can then read the settings database and
  the user's credentials (ISOL-16, ISOL-17), and while it is off the chat page
  says so next to its settings link (CSET-9).
- **UI-68** When the host has no jail (ISOL-12, ISOL-20) the switch is disabled
  and says so, rather than showing a chat as protected where it isn't.
- **UI-69** An approval prompt in a chat whose jail is off says the command
  runs unjailed (ISOL-17).
- **UI-70** The chat shows a worktree's dependency sync in progress (ISOL-7,
  ISOL-23) as text next to the composer (`#deps-sync`, "Preparing shared
  dependencies…"), following an event like `{:deps_sync, on?}`, gone when the
  sync ends whether it succeeded or failed. It covers both a sync the chat
  started in the background and one a command is waiting for, and it never
  blocks the composer or the transcript.

- **UI-79** The composer toolbar (UI-60's "Focus" toggle, the settings link) has
  a done control (`#done-toggle`) for an ordinary chat: a button whose
  `aria-pressed` is `true` while the chat is done (DONE-1) and whose label says
  what clicking it does — "Mark done" while the chat isn't done, "Reopen" while
  it is — with a matching `title`. Clicking it marks the chat done or reopens it
  (`Elia.Agent.set_done/2`, SESS-35) right away, with no confirmation, and the
  control's state follows `{:done, on?}` (SESS-35), so every view of the chat
  agrees; the sidebar's icon for the chat (UI-80) changes with it. It is there
  while a turn runs too (DONE-5). A task chat has no such control: its status is
  its task's (UI-46, DONE-3), so the button is not rendered, with nothing in its
  place.

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
the model did or did not see, and the user can compact the chat by hand.

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

### Sub-tasks

A child is an ordinary saved chat (SUBTASK-5) with task metadata (STORE-16),
so it opens at `/c/<child id>` like any chat.

- ~~**UI-55** A `{:subtask, …}` agent event is accepted and ignored by the chat
  page.~~ Removed: replaced by UI-43 and UI-44. Renumbered from UI-31, which
  the active "New chat" button requirement also used (the phase 1 spec reused
  the ID), so `UI-31` now names one thing only.
- **UI-43** A `spawn_task` call renders as a task card: the tool card's summary
  is the task `title` instead of the raw JSON input (UI-15), and a "Brief"
  section (`#task-brief-<call_id>`) shows the `brief`, expanded while the call
  awaits approval. The usual badge (UI-16) and approval buttons (UI-18) stay.
- **UI-44** Once the child exists, the card shows its status
  (`#task-status-<call_id>`, with `data-status` set to `running`, `done`,
  `blocked`, `failed`, `unfinished`, `cancelled` or `interrupted`) and a link to the child
  chat (`#task-link-<call_id>`). The status follows `{:subtask, call_id,
  child_id, status}` events (SUBTASK-7), and the link and status also appear
  when the chat is opened later, from the children's saved metadata
  (`parent_call_id`, STORE-18). While the child waits for the user to approve a
  tool call in its own chat (SESS-19), the card says so
  (`#task-awaiting-<call_id>`), and so does a child waiting for an answer to a
  question (ASK-9, `#task-input-<call_id>`).
- **UI-45** The sidebar nests a task chat under its parent chat, indented and
  ordered by start time (oldest first). A task chat whose parent isn't in the
  list is shown on its own at the top level. The row (`#chat-link-<id>`) uses
  the task's title (STORE-17).
- **UI-46** Each task chat in the sidebar shows its status as an icon
  (`#chat-status-<id>`, with `data-status` as in UI-44, and a `title` naming
  the status): a spinner while running, and a distinct icon for each other
  status. While it waits for approval or is paused the same icon shows that
  instead (UI-47, UI-58).
- **UI-47** Any chat in the sidebar that has a tool call awaiting approval
  (SESS-4) shows it in its status indicator (`#chat-status-<id>`, with
  `data-status="awaiting_approval"`, a hand icon and the `title` "Needs
  approval"), so a pending prompt in a child chat is not missed from the parent
  or any other chat. It follows status changes of every chat live (SESS-19) and
  is right on first render.
- **UI-48** A task chat shows a header (`#task-header`) above the transcript
  with "Task of" and a link to the parent chat (`#task-parent-link`, labelled
  with the parent's title), the task's status (UI-44's `data-status`, on
  `#task-header-status`), and a collapsible "Brief" (`#task-header-brief`).
  Once the task has finished, it also shows the result (`#task-result`): the
  summary, the commit (first 8 characters), the changed files and the open
  questions. The header follows `{:task, metadata}` events (SESS-20).
- **UI-49** The sidebar refreshes when a `{:subtask, …}` or `{:task, …}` event
  arrives, so a new task chat and its final status show without waiting for the
  turn to end (UI-6).

- **UI-50** The status `cancelled` (SUBTASK-16) has its own icon, wherever a
  task status is shown (UI-44, UI-46, UI-48), with `data-status="cancelled"`.

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

## Implementation

`EliaWeb.ChatLive`, `EliaWeb.Markdown`, `EliaWeb.Router`, `EliaWeb.Layouts`
(the app shell the chat fills, `#app-shell`, UI-78),
`EliaWeb.ChatStatus` (a chat's status and its icon, including a done chat's,
UI-59, UI-80),
`Elia.Agent` and `Elia.Agent.Session` (the chat's done flag: `set_done/2`, the
`{:done, on?}` event, and clearing it when a message continues the chat, UI-79,
DONE-9),
`Elia.Store` (the chat `/chats` resumes, STORE-29, UI-77; the title a row and the
page show, STORE-33, UI-74; the done flag a row shows, STORE-35, UI-80),
`EliaWeb.ChatSettingsLive` (the per-chat settings page the composer links to,
CSET; the model picker, the auto-approve switches and the jail switch,
UI-38, UI-39, UI-67, UI-68).

## Tests

`test/elia_web/live/chat_live_test.exs` (including what `/chats` opens, UI-77),
`test/elia_web/live/auto_approve_test.exs`,
`test/elia_web/live/jail_test.exs` (the jail switch, UI-67 to UI-69),
`test/elia_web/live/chat_settings_test.exs` (the settings page, CSET),
`test/elia_web/live/deps_sync_test.exs` (the sync indicator, UI-70),
`test/elia_web/live/compaction_test.exs`, `test/elia_web/live/compact_view_test.exs`,
`test/elia_web/live/page_title_test.exs`, `test/elia_web/live/chat_title_test.exs`
(UI-74, the stored title and `{:title, title}`),
`test/elia_web/live/task_ui_test.exs`,
`test/elia_web/live/user_input_test.exs` (the question card and the indicators,
UI-75, UI-76),
`test/elia_web/live/chat_done_test.exs` (the toolbar control, the sidebar icon,
UI-79, UI-80),
`test/elia_web/browser/chat_layout_test.exs` (the page fits the screen, UI-78;
a browser test, so it runs with `ELIA_BROWSER_TESTS=1` — BROWSER-5),
`test/elia_web/markdown_test.exs`, `test/elia_web/time_ago_test.exs`.
