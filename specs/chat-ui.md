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

- **UI-4** On large screens a sidebar lists the 30 most recently updated
  chats, newest first, each linking to `/c/<id>`. The open chat is
  highlighted.
- **UI-5** With no saved chats, the sidebar shows "No chats yet".
- **UI-6** When a turn ends (status becomes idle), the sidebar and page title
  refresh.

### Transcript

- **UI-7** An empty chat shows an empty state that tells the user Elia can run
  shell commands and that they approve each one.
- **UI-8** User messages render as right-aligned bubbles; assistant text as
  plain text; reasoning as small italic text with a light-bulb icon.
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

## Implementation

`EliaWeb.ChatLive`, `EliaWeb.Router`, `EliaWeb.Layouts`.

## Tests

`test/elia_web/live/chat_live_test.exs`, `test/elia_web/live/page_title_test.exs`.
