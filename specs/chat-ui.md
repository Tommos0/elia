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

- **UI-4** On large screens a sidebar lists the 30 most recently started
  chats (STORE-12), newest first, each linking to `/c/<id>`. The open chat is
  highlighted. Small screens get the same list through a drawer (UI-36).
- **UI-34** Each sidebar chat shows when it was started in human-readable
  relative form ("just now", "10 minutes ago", "3 hours ago", "2 days ago",
  then a date after a week), in a `<time>` element whose `datetime` is the
  start time and whose `title` is the exact date and time. The relative text
  refreshes every minute.
- **UI-5** With no saved chats, the sidebar shows "No chats yet".
- **UI-6** When a turn ends (status becomes idle), the sidebar and page title
  refresh.
- **UI-31** The sidebar shows a "New chat" button (`#new-chat`) above the chat
  list that starts a fresh chat.
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
- **UI-37** The header never overflows horizontally on narrow screens. Below
  the `sm` breakpoint the header buttons show only their icon (the label stays
  in the DOM for screen readers and as the link's `title`), with tighter
  spacing; from `sm` up they show icon and label.

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
- **UI-19** When a call awaiting approval writes a guarded file, or is a
  `hot_reload` while guarded files have unloaded changes, the card shows a
  warning naming the effect (see GUARD-1).
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
  this chat, and a note that auto-approved tools run without review,
  including on guarded files. Tools from folder skills appear after a skill
  reload. The switch state follows `{:auto_approve, names}` events (SESS-16),
  so every tab on the chat stays in sync.
- **UI-40** A call awaiting approval has an "Always allow" button
  (`#always-allow-<call_id>`) that turns auto-approval on for its tool
  (APPR-11, which also approves this call).

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

## Implementation

`EliaWeb.ChatLive`, `EliaWeb.Markdown`, `EliaWeb.Router`, `EliaWeb.Layouts`.

## Tests

`test/elia_web/live/chat_live_test.exs`, `test/elia_web/live/auto_approve_test.exs`,
`test/elia_web/live/page_title_test.exs`,
`test/elia_web/markdown_test.exs`, `test/elia_web/time_ago_test.exs`.
