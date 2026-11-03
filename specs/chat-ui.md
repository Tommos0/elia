# Chat UI

Status: Implemented

A single LiveView where the user chats with the agent, watches responses
stream in, approves or denies tool calls, and switches between saved chats.

## Requirements

### Routing

- **UI-1** `GET /` redirects to `/c/<id>` with a freshly generated chat id.
- **UI-2** `/c/<id>` opens that chat, starting its session if needed. An id
  that fails `Elia.Store.valid_id?/1` redirects to `/`.
- **UI-3** The page title is the chat's title (see STORE-7) and follows the
  chat when the user navigates between chats.

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
- **UI-63** A chat started from `/` or from a "New chat" button (UI-1, UI-31,
  PROJ-26) is in the sidebar list as soon as it opens: under its project
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
- **UI-32** The header on every page has a "Chats" button (`#chats-link`) to
  the left of "Sessions". It goes where the logo at the top left goes: `/`,
  which opens a fresh chat (UI-1).
- **UI-36** On small screens the chat list is a drawer: the header toggle
  button (`#chats-toggle`) opens and closes it, its `aria-expanded` follows,
  the drawer starts closed, and a backdrop (`#chats-backdrop`) or the Escape
  key closes it. Neither the toggle nor the backdrop exists from the `lg`
  breakpoint up, where the list (and the UI-35 drag handle) is always visible.
- **UI-37** The header never overflows horizontally on narrow screens. Below
  the `sm` breakpoint the header buttons show only their icon (the label stays
  in the DOM for screen readers and as the link's `title`), with tighter
  spacing; from `sm` up they show icon and label.
- **UI-59** Every chat in the sidebar shows one status indicator
  (`#chat-status-<id>`, with `data-status` and a `title`). A chat that isn't a
  task chat (UI-46) shows `working` — an animated spinner — while its turn is
  running, that is while its session status is `:running` (SESS-4), and `idle`
  — a dim dot — when it has no turn. Waiting for approval (`awaiting_approval`)
  and paused come first (UI-47, UI-58), so a chat that needs the user is never
  shown as idle. The indicator is right on first render, from
  `Elia.Agent.running/0` and the registry (SESS-19, SESS-28), and follows
  `{:chat_status, id, status}` (SESS-19) live. A task chat shows its task
  status under the same element (UI-46).

- **UI-64** Every chat row in the sidebar, task chats included (UI-45), has a
  delete button (`#delete-chat-<id>`, a trash icon with the accessible label
  "Delete chat") beside its link (`#chat-link-<id>`) as a sibling of it, not
  nested inside the link. Clicking it asks for confirmation first, with
  `data-confirm` naming the chat, and only then deletes it.
- **UI-65** Confirming a delete removes the chat (SESS-29): its row leaves the
  sidebar and a "Chat deleted." flash appears. Deleting the chat that is open
  navigates to `/` (a fresh chat, UI-1); deleting any other chat leaves the open
  one in place. Deleting a chat whose turn is running stops that turn first
  (SESS-29), so a running chat can be deleted from any chat's sidebar.
- **UI-66** Deleting a parent chat leaves its task chats saved and listed on
  their own at the top level (UI-45); deleting a task chat leaves its parent.

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

### Tool calls

- **UI-15** Each tool call renders as a card with an icon, the tool name, a
  status badge and a summary of its input: `$ <command>` for `shell`, the path
  for tools with a `path` input, "(no input)" for empty input, pretty JSON
  otherwise.
- **UI-16** Status badges: Needs approval, Approved, Running, Done, Failed (done
  with an error), Pending (anything else).
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

### Composer

- **UI-21** Enter sends the message; Shift+Enter inserts a newline. The input
  grows with its content.
- **UI-22** Messages that are blank after trimming are not sent.
- **UI-23** After a successful send the input clears.
- **UI-24** While the agent isn't idle, the input is disabled and the send
  button is replaced by a Stop button that stops the turn (SESS-8).

- **UI-38** The composer has an "Auto-approve" button (`#auto-approve-button`)
  next to the model picker. It shows how many tools the chat auto-approves
  (`#auto-approve-count`, hidden at zero) and opens a popover
  (`#auto-approve`) that Escape or a click outside closes.
- **UI-39** The popover lists each tool that can need approval (APPR-13) with a
  switch (`#auto-approve-<tool name>`) that reflects and toggles APPR-8 for
  this chat, and a note that auto-approved tools run without review. Tools
  from folder skills appear after a skill
  reload. The switch state follows `{:auto_approve, names}` events (SESS-16),
  so every tab on the chat stays in sync.
- **UI-40** A call awaiting approval has an "Always allow" button
  (`#always-allow-<call_id>`) that turns auto-approval on for its tool
  (APPR-11, which also approves this call).
- ~~**UI-41** The tools a chat auto-approves are visible without opening the
  popover: each one shows as a chip.~~ Removed: the per-tool state is only shown
  in the popover (UI-42); the count badge (UI-38) is enough outside it.
- **UI-42** In the popover each switch row says "On" or "Off" in text next to
  the switch, so the state doesn't rely on colour or hover and is clear on
  touch screens.

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
- **UI-54** The composer has a "Compact" button (`#compact-button`) that
  compacts the chat now (COMPACT-10), and flashes an error while a turn is
  running.
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
  (`#task-awaiting-<call_id>`).
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
  UI-29) and the per-item request-view notes (UI-51) are not rendered. A task chat's header (UI-48) and the pause banner (UI-57) stay
  visible.
- **UI-62** While the compact view is on and the turn is working (`:running` or
  `:awaiting_approval`, SESS-4), a one-sentence "working on" summary
  (`#work-summary`) names the current step: the tool that is running or awaiting
  approval ("Running `mix test`.", "Waiting for your approval to run
  `git commit`."), writing a reply, or thinking, and "Working." before the step
  is known. It is set when the turn's status changes and, while the turn runs,
  refreshed about once a second, so it lags the step by no more than a second
  (the one-second timer only runs while a turn is running, so an idle chat is
  left alone). It is cleared when the turn ends. While it waits for approval it
  offers a "Review" button (`#work-summary-review`) that switches to the full
  view.

## Implementation

`EliaWeb.ChatLive`, `EliaWeb.Markdown`, `EliaWeb.Router`, `EliaWeb.Layouts`.

## Tests

`test/elia_web/live/chat_live_test.exs`, `test/elia_web/live/auto_approve_test.exs`,
`test/elia_web/live/compaction_test.exs`, `test/elia_web/live/compact_view_test.exs`,
`test/elia_web/live/page_title_test.exs`, `test/elia_web/live/task_ui_test.exs`,
`test/elia_web/markdown_test.exs`, `test/elia_web/time_ago_test.exs`.
